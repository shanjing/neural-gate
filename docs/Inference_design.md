# neural-gate Inference Design

**Scope:** A production-grade inference stack that runs locally on a Mac Mini and deploys to GKE/AWS with minimal changes. This is a **separate project** (`neural-gate` repo) that serves all agentic apps (Draft, MarginCall, etc.) via an OpenAI-compatible API.

For how a consumer app (e.g. Draft) uses the inference endpoint, see that app’s docs (e.g. intelligence layer / RAG design). [Infrastructure_design.md](Infrastructure_design.md) describes the Kubernetes layout, Helm chart, and deployment workflow.

---

## End-Goals

1. **Simulate a production inference stack** — same control plane (KServe), scheduling (llm-d), and engine patterns used by enterprises on GKE/EKS.
2. **Provide local LLM to all agentic apps** — one shared service, every app points `LLM_ENDPOINT` at the same K8s Service.
3. **Minimum changes for cloud deployment** — Helm value overrides (e.g. `values-gke.yaml`) swap the engine image, GPU resource type, and PV backend. App code changes zero lines.

---

## Three-Tier Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Control Plane — KServe                                     │
│  Model lifecycle, InferenceService CRDs, canary rollouts,   │
│  autoscaling (scale-to-zero), traffic splitting, Gateway    │
├─────────────────────────────────────────────────────────────┤
│  Scheduling Layer — llm-d                                   │
│  KV-cache-aware routing, prefill/decode separation,         │
│  session affinity, Envoy + EPP (External Processing Plugin) │
├─────────────────────────────────────────────────────────────┤
│  Execution Engine — per-pod                                 │
│  Local: llama-server (Vulkan GPU via krunkit)               │
│  GKE:  vLLM (CUDA) or TensorRT-LLM                         │
│  API:  /v1/chat/completions, /v1/models, /health            │
└─────────────────────────────────────────────────────────────┘
```

**Control plane (KServe)** manages model deployments as Kubernetes CRDs (`InferenceService`, `LLMInferenceService`). Handles canary rollouts, A/B testing, autoscaling, model versioning, and multi-model serving. KServe is a CNCF incubating project (Nov 2025), standalone — no Kubeflow required.

**Scheduling layer (llm-d)** sits between the Gateway and engine pods. Routes each request to the pod with the warmest KV cache (57× faster response, 2× throughput vs naive distribution in benchmarks). Supports prefill/decode disaggregation across separate worker pods. Built on Kubernetes Gateway API with Envoy data plane.

**Execution engine** runs inside each pod, owns the GPU, loads the model, manages KV cache memory, batches requests. Exposes the OpenAI-compatible API. The engine is the only component that changes between environments.

---

## Why a Separate Repo

In production, the inference cluster is a separate concern from any application:

- Different node pools, IAM scopes, scaling policies, on-call teams
- Model updates ≠ app updates (independent release cycles)
- Multiple consumers share one inference stack

If inference lives inside Draft, every other app (MarginCall, aimee, future agents) depends on Draft to get an LLM endpoint. A separate repo makes the OpenAI API the only contract:

```
neural-gate (separate repo)              Draft / MarginCall / aimee
─────────────────────────────────        ────────────────────────────
Owns: GPU, models, KServe,              Owns: app logic, RAG, UI
      scheduling, scaling               Consumes: LLM_ENDPOINT
Exposes: /v1/chat/completions           (one env var, same for all apps)
         /v1/models, /health
```

### Repo Layout

```
neural-gate/
├── k8s/
│   └── neural-gate/                 # Helm chart (single chart, all envs)
│       ├── Chart.yaml
│       ├── values.yaml             # Defaults: local-krunkit (llama-server, squat.ai/dri)
│       ├── values-gke.yaml          # GKE overrides (vLLM, nvidia.com/gpu, PVC)
│       └── templates/              # Namespace, device-plugin, InferenceService,
│                                   # Gateway, HTTPRoute, llm-d, monitoring
├── scripts/                         # setup.sh (cluster, KServe, Helm deploy), smoke-test, benchmark
├── docs/                            # This doc, Infrastructure_design.md, mac_runbook.md
└── requirements.txt                 # Python deps (e.g. huggingface-hub for model download)
```

Deployment is driven by `scripts/setup.sh`: option 4 installs the cluster and KServe stack (cert-manager, Gateway API, Envoy Gateway, KServe CRDs and controller, MetalLB); option 5 runs `helm upgrade --install neural-gate` with `--set` for the selected models. See [Infrastructure_design.md](Infrastructure_design.md) for the full Helm chart structure and values.

---

## GPU Passthrough: Minikube krunkit Driver

Kubernetes requires Linux. Every "K8s on Mac" solution runs Linux in a VM. The critical question is whether that VM can access the Mac's GPU.


| Minikube driver | VM technology                  | GPU passthrough?            |
| --------------- | ------------------------------ | --------------------------- |
| docker          | Docker Desktop Linux VM        | No — no Metal in VM         |
| krunkit         | Apple Virtualization.framework | **Yes** — virtio-gpu device |


The **krunkit driver** uses Apple's native Virtualization.framework and exposes the host GPU as `/dev/dri` (virtio-gpu) inside the VM. A `generic-device-plugin` DaemonSet makes it schedulable as a K8s resource (`squat.ai/dri`). Pods request GPU access via standard resource limits.

Requirements: Apple Silicon, macOS 14+, minikube v1.37.0+, krunkit v1.0.0+, vmnet-helper.

```bash
brew tap slp/krunkit && brew install krunkit
curl -fsSL https://github.com/minikube-machine/vmnet-helper/releases/latest/download/install.sh | bash

minikube start --driver krunkit --mount-string ~/.models:/mnt/models
```

The virtio-gpu device provides Vulkan-level GPU compute. llama-server (llama.cpp) uses this via its Vulkan backend with `-ngl 999` (offload all layers to GPU). This enables model inference **inside K8s pods with GPU acceleration** — the same Deployment/Service/Ingress pattern as GKE.

### Metal GPU Limitation

Apple's Metal framework has no container GPU passthrough. Docker's own vllm-metal documentation states: *"Metal GPU access requires direct hardware access and there is no GPU passthrough for Metal in containers."* This means:

- vLLM-Metal and vLLM-MLX require native macOS — they cannot run inside K8s pods
- The krunkit virtio-gpu path uses Vulkan, not Metal
- llama-server (GGUF + Vulkan) is the engine for the in-cluster local path (Helm default values)

---

## Inference Engines

### Engine Options by Environment


| Engine                   | Hardware                | GPU API               | Format      | In K8s pod? | Use case                              |
| ------------------------ | ----------------------- | --------------------- | ----------- | ----------- | ------------------------------------- |
| llama-server (llama.cpp) | Apple Silicon (krunkit) | Vulkan via virtio-gpu | GGUF        | **Yes**     | Local: production-like K8s simulation |
| vLLM                     | NVIDIA GPU              | CUDA                  | Safetensors | **Yes**     | GKE/EKS production                    |
| TensorRT-LLM             | NVIDIA GPU              | CUDA                  | TRT engine  | **Yes**     | GKE/EKS max throughput                |
| TGI                      | NVIDIA GPU              | CUDA                  | Safetensors | **Yes**     | GKE/EKS simple ops                    |


### Native-Only Engines (fallback / daily use)

These run as macOS processes, not inside K8s. Use with ExternalName Service when full-stack simulation is not needed.


| Engine     | Status          | Notes                                                                                                                                  |
| ---------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| mlx-lm     | Stable          | Current setup. Native Metal, 20 GPU cores. Simple.                                                                                     |
| vLLM-MLX   | Sub-v1.0 (2025) | vLLM-like scheduling (paged KV, batching) + MLX. Multimodal. `pip install vllm-mlx`. Benchmarks: 525 tok/s Qwen3-0.6B 4-bit on M4 Max. |
| vLLM-Metal | Sub-v1.0 (2026) | Official vLLM plugin, co-developed with Docker. Text-only, no published benchmarks yet. Docker Model Runner integration.               |
| Ollama     | Stable          | Wraps llama.cpp. Easiest setup, slightly lower throughput.                                                                             |


All native engines use Metal GPU directly. Switching between them is a process swap on port 8000 (stop one launchd service, start another). The K8s ExternalName Service, Ingress, and app config don't change.

The server must bind to `0.0.0.0`, not `127.0.0.1`. Cluster nodes reach the host via a non-loopback IP.

### Process Management (native engines)

- **macOS:** launchd (`~/Library/LaunchAgents/`)
- **Linux:** systemd unit
- **GKE:** Kubernetes Deployment with `restartPolicy: Always`

---

## Multi-Model Local Setup

### Model Selection (krunkit in-cluster path)

Running multiple models inside K8s pods exercises KServe multi-model serving, canary rollouts, and llm-d routing — the patterns that matter in production. Current lineup: Qwen3 1.7B and 8B (GGUF), plus Qwen2.5 32B for high-quality or native single-model use.

| Model                | Disk     | Active memory | Role                              |
| -------------------- | -------- | ------------- | --------------------------------- |
| Qwen3-8B (GGUF Q4)   | ~5 GB    | ~6 GB         | Primary — quality, chat           |
| Qwen3-1.7B (GGUF Q4) | ~1.3 GB  | ~2 GB         | Secondary — fast, canary / A/B    |
| Qwen2.5-32B (GGUF Q4)| ~18 GB   | ~23 GB        | Primary (single-model) or flagship|


### Memory Budget (64 GB unified, krunkit full-stack)

```
macOS + system daemons                          ~6 GB
─────────────────────────────────────────────────────
krunkit VM (Kubernetes full stack)
  K8s system (etcd, API server, scheduler)      ~3 GB
  Gateway API / Envoy Gateway                   ~2 GB
  KServe controller + cert-manager              ~1 GB
  llm-d (Envoy + EPP scheduler)                ~0.5 GB
  generic-device-plugin                        ~0.1 GB
  ──── Model pods (GGUF 4-bit, GPU) ────
  Pod 1: Qwen3-8B   (llama-server)              ~6 GB
  Pod 2: Qwen3-1.7B (llama-server)               ~2 GB
  Pod 3: Qwen2.5-32B (llama-server)              ~23 GB
  Pod overhead (containers, networking)          ~2 GB
                                     VM total: ~40 GB
─────────────────────────────────────────────────────
Monitoring (Prometheus + Grafana)               ~1.5 GB
Headroom                                       ~17 GB
                                               ──────
                                                64 GB
```

With all three models (Qwen3-8B, Qwen3-1.7B, Qwen2.5-32B) the VM uses ~40 GB; ~17 GB headroom allows KV caches to grow under load. For more headroom, run only 8B + 1.7B in-cluster and use 32B natively (see Single-Model Native Setup).

### Single-Model Native Setup (fallback)

For daily use where full-stack simulation is not needed, run one large model natively (e.g. mlx-lm or Ollama):


| Model                     | Disk    | Active memory | Decode speed   |
| ------------------------- | ------- | ------------- | -------------- |
| Qwen2.5-32B (GGUF Q4)     | ~18 GB  | ~23 GB        | ~25–40 tok/s   |
| Qwen3-8B (GGUF Q4)        | ~5 GB   | ~6 GB         | ~50–80 tok/s   |
| Qwen3-1.7B (GGUF Q4)      | ~1.3 GB | ~2 GB         | ~100–150 tok/s |


---

## K8s Components (Full-Stack Path)

### KServe InferenceService

Each model is a KServe `InferenceService` CRD. KServe manages the Deployment, Service, and autoscaler for each model. In neural-gate, one InferenceService per model is generated from the Helm template `templates/model-inferenceservice.yaml` using the `models` list in values (set by `setup.sh` option 5).

Conceptually, each entry looks like this (local-krunkit defaults):

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: qwen-8b
  namespace: inference
spec:
  predictor:
    containers:
    - name: kserve-container
      image: quay.io/ramalama/ramalama:latest
      command: [llama-server, --host, "0.0.0.0", --port, "8080",
                --model, /mnt/models/qwen3-8b.gguf,
                -ngl, "999", --ctx-size, "4096"]
      resources:
        limits:
          squat.ai/dri: 1
      volumeMounts:
      - name: models
        mountPath: /mnt/models
    volumes:
    - name: models
      hostPath:
        path: /mnt/models
```

### llm-d Scheduler (optional)

When enabled, llm-d sits between the Gateway and model pods and routes requests to the pod with the best KV cache hit. Pluggable scorers: KV-cache-aware, prefix-aware, session-aware, load-aware.

On GKE with vLLM, llm-d can use vLLM's KV-Events API for precise cache introspection. On the local krunkit path with llama-server, llm-d falls back to load-aware and session-aware routing. In the neural-gate Helm chart, llm-d is **disabled by default** (`llmd.enabled: false` in `values.yaml`); set to `true` when a working EPP image is available.

### Gateway API

Gateway API is the Kubernetes-standard successor to Ingress. neural-gate uses **Envoy Gateway** as the implementation: one Gateway (`inference-gateway`) with `gatewayClassName: envoy`, and one HTTPRoute per model for host-based routing (e.g. `qwen3-1-7b.inference.local` → predictor Service). MetalLB provides a LoadBalancer IP for the Envoy proxy; on macOS the MetalLB IP is often not routable from the host, so use `kubectl port-forward` to a predictor Service or to the Envoy proxy for local access.

For LLM workloads, ensure:

- **proxy-buffering: off** — required for streaming completions (SSE)
- **proxy-read-timeout: 300** — 5-minute timeout for long generations

### PersistentVolume + PVC

Model weights persist independently of pod lifecycle. Backed by hostPath (krunkit mount) locally, GCE pd-ssd on GKE. Reclaim policy: `Retain`.

Models are downloaded once to the host, mounted into krunkit via `minikube mount`, and consumed by pods as hostPath volumes.

### Monitoring

Prometheus scrapes engine metrics (tokens/s, batch size, queue depth, GPU utilization). Grafana dashboards for SLO tracking. Same dashboards work locally and in production — only the data source endpoint changes.

---

## Storage Sizing

### Local (multi-model, krunkit)


| Component              | Size      | Notes                    |
| ---------------------- | --------- | ------------------------- |
| Qwen3-8B (GGUF Q4)     | ~5 GB     | Primary                   |
| Qwen3-1.7B (GGUF Q4)    | ~1.3 GB   | Secondary / canary        |
| Qwen2.5-32B (GGUF Q4)   | ~18 GB    | Flagship / single-model   |
| HF cache overhead      | ~1 GB     | Tokenizer configs         |
| PV total               | **26 Gi** | Rounded up                |


### GKE Production


| Component               | Size       | Notes                     |
| ----------------------- | ---------- | ------------------------- |
| Primary model (70B FP8) | ~70 GB     | Multi-GPU tensor parallel |
| Secondary model slot    | ~70 GB     | A/B testing               |
| HF cache overhead       | ~5 GB      |                           |
| PV total                | **300 Gi** | pd-ssd                    |


Weights live on the fastest available persistent storage (NVMe SSD locally, pd-ssd on GKE).

---

## Environment Mapping (Helm Values)

The same Helm chart (`k8s/neural-gate/`) is used everywhere. Environment differences are expressed via `values.yaml` (defaults) and overrides such as `values-gke.yaml`:

| Component        | `values.yaml` (local-krunkit)    | `values-gke.yaml` (GKE)                 |
| ---------------- | --------------------------------- | --------------------------------------- |
| Engine image     | `ramalama:latest` (llama-server)  | `vllm/vllm-openai:latest`               |
| GPU resource     | `squat.ai/dri: 1`                 | `nvidia.com/gpu: 1`                     |
| Model format     | GGUF (Q4_K_M)                     | Safetensors (FP8/FP16)                  |
| PV backend       | hostPath via krunkit mount        | GCE pd-ssd (PVC)                        |
| Gateway          | Envoy Gateway (MetalLB)           | GKE Gateway or Istio                    |
| Autoscaler       | HPA (batch size metric)           | HPA + KServe built-in (scale-to-zero)   |
| llm-d            | Optional (disabled by default)    | Optional; precise KV-cache (vLLM)        |
| DNS              | `/etc/hosts` → `*.inference.local`| Cloud DNS A record                      |

A future `local-native` option could run mlx-lm on the host with an ExternalName Service to `host.minikube.internal`; that would use the Docker driver (no krunkit) and not simulate the full production deployment pattern.

---

## Mac Mini M4 Pro — Hardware

- Chip: Apple M4 Pro (12-core CPU: 8P + 4E, 20-core GPU)
- Memory: 64 GB unified (CPU + GPU share the same pool)
- Storage: External NVMe, 1.7 TB free

### krunkit Cluster Start

```bash
minikube start \
  --driver=krunkit \
  --mount-string ~/.models:/mnt/models \
  --profile=inference
```

### Verify GPU in VM

```bash
minikube ssh --profile=inference -- tree /dev/dri
# Expected: /dev/dri/card0, /dev/dri/renderD128
```

### Deploy via setup.sh

The device plugin, KServe stack, and model deployments are all managed by the interactive setup script:

1. **Option 4 — Start cluster**  
   Starts minikube (krunkit, 3 nodes, mount `~/.models:/mnt/models`) and installs KServe infrastructure: cert-manager, Gateway API CRDs, Envoy Gateway, KServe CRDs and controller, MetalLB, and the `envoy` GatewayClass.

2. **Option 5 — Deploy inference stack**  
   Runs `helm upgrade --install neural-gate ./k8s/neural-gate/` with `--set` for the models you select from the models directory. This creates the namespace, device-plugin DaemonSet, InferenceServices, Gateway, HTTPRoutes, and monitoring ConfigMaps.

3. **Option 6 — Configure ingress**  
   Ensures the Gateway has a LoadBalancer IP (MetalLB) and adds `*.inference.local` to `/etc/hosts`. On macOS, the MetalLB IP is often not routable from the host; use port-forward to reach predictors (see below).

4. **Reach a model from the host**  
   Port-forward to a predictor Service, then call the OpenAI-compatible API on localhost:

```bash
kubectl port-forward -n inference svc/qwen3-1-7b-predictor 8081:80
curl -s http://127.0.0.1:8081/v1/models
curl -s http://127.0.0.1:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-1-7b","messages":[{"role":"user","content":"hello"}]}'
```

See [mac_runbook.md](mac_runbook.md) for full setup and smoke-test steps.

---

## What This Stack Validates Locally

- **KServe CRDs**: Deploy/update models declaratively — same YAML as GKE
- **Autoscaling**: Scale model pods 0→N based on queue depth / batch size
- **Canary rollouts**: Route 90% to 8B, 10% to 4B, promote if latency meets SLO
- **llm-d routing**: Requests hit the least-loaded pod with best cache affinity
- **Prefill/decode split**: 0.5B as prefill worker, 8B as decode (tests disaggregation)
- **Multi-model serving**: KServe manages all three model lifecycles independently
- **Rolling updates**: Swap 8B-4bit for 8B-8bit with zero downtime
- **Monitoring**: Same Prometheus rules and Grafana dashboards as production

### What Differs from Production


| Aspect             | Local                                       | GKE/EKS                       |
| ------------------ | ------------------------------------------- | ----------------------------- |
| GPU type           | virtio-gpu (Vulkan via krunkit)             | NVIDIA A100/H100 (CUDA)       |
| Engine             | llama-server (llama.cpp)                    | vLLM or TensorRT-LLM          |
| Model format       | GGUF                                        | Safetensors / TRT engine      |
| Throughput         | ~25–70 tok/s per model                      | ~3,000+ tok/s per node        |
| Tensor parallelism | No (single GPU)                             | Yes (multi-GPU NVLink)        |
| Node count         | 1                                           | N GPU nodes                   |
| llm-d precision    | Load-aware (no KV-Events from llama-server) | Precise KV-cache-aware (vLLM) |


The throughput differs, but every K8s manifest, every CRD, every routing rule, every autoscaling policy, every canary configuration is identical.

---

## Deployment Files (in neural-gate repo)

All Kubernetes resources are defined in the Helm chart. Model InferenceServices and HTTPRoutes are generated from the `models` list in values (populated by `setup.sh` via `--set`).

```
neural-gate/
├── k8s/neural-gate/
│   ├── Chart.yaml
│   ├── values.yaml                   # Local-krunkit defaults (llama-server, squat.ai/dri)
│   ├── values-gke.yaml               # GKE overrides (vLLM, nvidia.com/gpu, PVC)
│   └── templates/
│       ├── _helpers.tpl
│       ├── namespace.yaml
│       ├── device-plugin.yaml        # generic-device-plugin DaemonSet
│       ├── model-inferenceservice.yaml   # InferenceService per model
│       ├── gateway.yaml
│       ├── httproute.yaml            # HTTPRoute per model
│       ├── llm-d/
│       │   ├── envoy-config.yaml
│       │   └── epp-deployment.yaml
│       └── monitoring/
│           ├── prometheus-rules.yaml
│           └── grafana-dashboard.yaml
├── scripts/
│   ├── setup.sh                      # Cluster, KServe infra, Helm deploy, ingress
│   ├── smoke-test.sh
│   └── benchmark.sh
├── docs/
│   ├── Inference_design.md           # This document
│   ├── Infrastructure_design.md      # Helm chart, KServe, Gateway API
│   └── mac_runbook.md                # macOS setup and smoke test
└── requirements.txt                  # e.g. huggingface-hub for model download
```

Workflow: run `./scripts/setup.sh`, use options 4 (start cluster + KServe), 5 (Helm deploy with selected models), 6 (ingress /etc/hosts). See [Infrastructure_design.md](Infrastructure_design.md) for chart values and deployment details.

