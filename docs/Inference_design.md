# Inference Stack Design

**Scope:** A production-grade inference stack that runs locally on a Mac Mini and deploys to GKE/AWS with minimal changes. This is a **separate project** (`inference-stack` repo) that serves all agentic apps (Draft, MarginCall, etc.) via an OpenAI-compatible API.

The [intelligence layer design](intelligence-layer-design.md) describes how the Draft app consumes the inference endpoint for RAG and Ask.

---

## End-Goals

1. **Simulate a production inference stack** — same control plane (KServe), scheduling (llm-d), and engine patterns used by enterprises on GKE/EKS.
2. **Provide local LLM to all agentic apps** — one shared service, every app points `LLM_ENDPOINT` at the same K8s Service.
3. **Minimum changes for cloud deployment** — Kustomize overlays swap the engine image, GPU resource type, and PV backend. App code changes zero lines.

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
inference-stack (separate repo)          Draft / MarginCall / aimee
─────────────────────────────────        ────────────────────────────
Owns: GPU, models, KServe,              Owns: app logic, RAG, UI
      scheduling, scaling               Consumes: LLM_ENDPOINT
Exposes: /v1/chat/completions           (one env var, same for all apps)
         /v1/models, /health
```

### Repo Layout

```
inference-stack/
├── k8s/
│   ├── base/                        # Kustomize base (engine-agnostic)
│   │   ├── namespace.yaml
│   │   ├── kserve/                  # InferenceService CRDs
│   │   ├── llm-d/                   # Scheduler config (Envoy + EPP)
│   │   ├── gateway/                 # Gateway API routes
│   │   ├── device-plugin/           # generic-device-plugin DaemonSet
│   │   └── monitoring/              # Prometheus rules, Grafana dashboards
│   ├── overlays/
│   │   ├── local-krunkit/           # llama-server + krunkit GPU + GGUF models
│   │   ├── local-native/            # mlx-lm on host + ExternalName (fallback)
│   │   └── gke-production/          # vLLM + A100/H100 + real autoscaling
│   └── models/                      # Model configs (name, quant, PV size)
├── native/                          # launchd plists, start scripts (macOS)
├── scripts/                         # Setup, smoke tests, benchmark
├── docs/                            # This design doc lives here
└── Makefile                         # make local-up, make gke-deploy, make smoke-test
```

---

## GPU Passthrough: Minikube krunkit Driver

Kubernetes requires Linux. Every "K8s on Mac" solution runs Linux in a VM. The critical question is whether that VM can access the Mac's GPU.

| Minikube driver | VM technology | GPU passthrough? |
| --------------- | ------------- | ---------------- |
| docker          | Docker Desktop Linux VM | No — no Metal in VM |
| krunkit         | Apple Virtualization.framework | **Yes** — virtio-gpu device |

The **krunkit driver** uses Apple's native Virtualization.framework and exposes the host GPU as `/dev/dri` (virtio-gpu) inside the VM. A `generic-device-plugin` DaemonSet makes it schedulable as a K8s resource (`squat.ai/dri`). Pods request GPU access via standard resource limits.

Requirements: Apple Silicon, macOS 14+, minikube v1.37.0+, krunkit v1.0.0+, vmnet-helper.

```bash
brew tap slp/krunkit && brew install krunkit
curl -fsSL https://github.com/minikube-machine/vmnet-helper/releases/latest/download/install.sh | bash

minikube start --driver krunkit --mount-string ~/models:/mnt/models
```

The virtio-gpu device provides Vulkan-level GPU compute. llama-server (llama.cpp) uses this via its Vulkan backend with `-ngl 999` (offload all layers to GPU). This enables model inference **inside K8s pods with GPU acceleration** — the same Deployment/Service/Ingress pattern as GKE.

### Metal GPU Limitation

Apple's Metal framework has no container GPU passthrough. Docker's own vllm-metal documentation states: *"Metal GPU access requires direct hardware access and there is no GPU passthrough for Metal in containers."* This means:

- vLLM-Metal and vLLM-MLX require native macOS — they cannot run inside K8s pods
- The krunkit virtio-gpu path uses Vulkan, not Metal
- llama-server (GGUF + Vulkan) is the engine for the in-cluster local overlay

---

## Inference Engines

### Engine Options by Environment

| Engine | Hardware | GPU API | Format | In K8s pod? | Use case |
| ------ | -------- | ------- | ------ | ----------- | -------- |
| llama-server (llama.cpp) | Apple Silicon (krunkit) | Vulkan via virtio-gpu | GGUF | **Yes** | Local: production-like K8s simulation |
| vLLM | NVIDIA GPU | CUDA | Safetensors | **Yes** | GKE/EKS production |
| TensorRT-LLM | NVIDIA GPU | CUDA | TRT engine | **Yes** | GKE/EKS max throughput |
| TGI | NVIDIA GPU | CUDA | Safetensors | **Yes** | GKE/EKS simple ops |

### Native-Only Engines (fallback / daily use)

These run as macOS processes, not inside K8s. Use with ExternalName Service when full-stack simulation is not needed.

| Engine | Status | Notes |
| ------ | ------ | ----- |
| mlx-lm | Stable | Current setup. Native Metal, 20 GPU cores. Simple. |
| vLLM-MLX | Sub-v1.0 (2025) | vLLM-like scheduling (paged KV, batching) + MLX. Multimodal. `pip install vllm-mlx`. Benchmarks: 525 tok/s Qwen3-0.6B 4-bit on M4 Max. |
| vLLM-Metal | Sub-v1.0 (2026) | Official vLLM plugin, co-developed with Docker. Text-only, no published benchmarks yet. Docker Model Runner integration. |
| Ollama | Stable | Wraps llama.cpp. Easiest setup, slightly lower throughput. |

All native engines use Metal GPU directly. Switching between them is a process swap on port 8000 (stop one launchd service, start another). The K8s ExternalName Service, Ingress, and app config don't change.

The server must bind to `0.0.0.0`, not `127.0.0.1`. Cluster nodes reach the host via a non-loopback IP.

### Process Management (native engines)

- **macOS:** launchd (`~/Library/LaunchAgents/`)
- **Linux:** systemd unit
- **GKE:** Kubernetes Deployment with `restartPolicy: Always`

---

## Multi-Model Local Setup

### Model Selection (krunkit in-cluster path)

Running multiple models inside K8s pods exercises KServe multi-model serving, canary rollouts, and llm-d routing — the patterns that matter in production.

| Model | Disk | Active memory | Role |
| ----- | ---- | ------------- | ---- |
| 8B-4bit (e.g. Qwen2.5-8B-Instruct) | ~5 GB | ~6 GB | Primary — quality |
| 4B-4bit (e.g. Qwen2.5-4B-Instruct) | ~2.5 GB | ~3 GB | Secondary — A/B testing, canary |
| 0.5B-4bit (e.g. Qwen2.5-0.5B) | ~0.5 GB | ~1 GB | Router / prefill worker / fallback |

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
  Pod 1: 8B model  (llama-server)               ~6 GB
  Pod 2: 4B model  (llama-server)               ~3 GB
  Pod 3: 0.5B model (llama-server)              ~1 GB
  Pod overhead (containers, networking)          ~2 GB
                                      VM total: ~18.5 GB
─────────────────────────────────────────────────────
Monitoring (Prometheus + Grafana)               ~1.5 GB
Headroom                                       ~38 GB
                                               ──────
                                                64 GB
```

~38 GB of headroom means KV caches can grow under concurrent load without pressure.

### Single-Model Native Setup (fallback)

For daily use where full-stack simulation is not needed, run one large model natively with the original ExternalName architecture:

| Model | Disk | Active memory | Decode speed |
| ----- | ---- | ------------- | ------------ |
| Qwen2.5-32B-Instruct-4bit | ~18 GB | ~23 GB | ~25–40 tok/s |
| Qwen2.5-14B-Instruct-4bit | ~8 GB | ~12 GB | ~50–70 tok/s |

---

## K8s Components (Full-Stack Path)

### KServe InferenceService

Each model is a KServe `InferenceService` CRD. KServe manages the Deployment, Service, and autoscaler for each model.

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: qwen-8b
  namespace: inference
spec:
  predictor:
    containers:
    - name: llama-server
      image: quay.io/ramalama/ramalama:latest
      command: [llama-server, --host, "0.0.0.0", --port, "8080",
                --model, /mnt/models/qwen2.5-8b-instruct-q4_k_m.gguf,
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

### llm-d Scheduler

Deployed between the Gateway and model pods. Routes requests to the pod with the best KV cache hit. Pluggable scorers: KV-cache-aware, prefix-aware, session-aware, load-aware.

On GKE with vLLM, llm-d uses vLLM's KV-Events API for precise cache introspection. On the local krunkit path with llama-server, llm-d falls back to load-aware and session-aware routing (still valuable for multi-model serving).

### Gateway API

Replaces the nginx Ingress from the original design. Gateway API is the Kubernetes-standard successor to Ingress and is what KServe and llm-d build on.

Two annotations remain critical for LLM workloads:
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

| Component | Size | Notes |
| --------- | ---- | ----- |
| 8B model (GGUF Q4) | ~5 GB | Primary |
| 4B model (GGUF Q4) | ~2.5 GB | Canary / A/B |
| 0.5B model (GGUF Q4) | ~0.5 GB | Router / prefill |
| HF cache overhead | ~1 GB | Tokenizer configs |
| PV total | **20 Gi** | Rounded up |

### GKE Production

| Component | Size | Notes |
| --------- | ---- | ----- |
| Primary model (70B FP8) | ~70 GB | Multi-GPU tensor parallel |
| Secondary model slot | ~70 GB | A/B testing |
| HF cache overhead | ~5 GB | |
| PV total | **300 Gi** | pd-ssd |

Weights live on the fastest available persistent storage (NVMe SSD locally, pd-ssd on GKE).

---

## Environment Mapping (Kustomize Overlays)

The base manifests (KServe CRDs, Gateway routes, llm-d config, monitoring) are identical across environments. Overlays change only what must differ:

| Component | `local-krunkit` overlay | `gke-production` overlay |
| --------- | ----------------------- | ------------------------ |
| Engine image | `ramalama:latest` (llama-server) | `vllm/vllm-openai:latest` |
| GPU resource | `squat.ai/dri: 1` | `nvidia.com/gpu: 1` |
| Model format | GGUF (Q4_K_M) | Safetensors (FP8/FP16) |
| PV backend | hostPath via krunkit mount | GCE pd-ssd |
| Gateway | Envoy Gateway (local) | GKE Gateway or Istio |
| Autoscaler | HPA (batch size metric) | HPA + KServe built-in (scale-to-zero) |
| llm-d cache mode | Load-aware + session-aware | Precise KV-cache-aware (vLLM KV-Events) |
| DNS | `/etc/hosts` → `inference.local` | Cloud DNS A record |

A `local-native` overlay is also available as a lightweight fallback: mlx-lm runs on the host as a launchd service, and an ExternalName Service routes cluster traffic to `host.minikube.internal:8000`. This uses the Docker driver (no krunkit) and is simpler but does not simulate the production deployment pattern.

---

## Mac Mini M4 Pro — Hardware

- Chip: Apple M4 Pro (12-core CPU: 8P + 4E, 20-core GPU)
- Memory: 64 GB unified (CPU + GPU share the same pool)
- Storage: External NVMe, 1.7 TB free

### krunkit Cluster Start

```bash
minikube start \
  --driver=krunkit \
  --mount-string ~/models:/mnt/models \
  --profile=inference
```

### Verify GPU in VM

```bash
minikube ssh --profile=inference -- tree /dev/dri
# Expected: /dev/dri/card0, /dev/dri/renderD128
```

### Deploy generic-device-plugin

Makes `/dev/dri` schedulable as `squat.ai/dri`. Configurable `count` controls how many pods share the GPU (set to match the number of model pods).

### Install KServe + llm-d

```bash
# KServe standalone (no Kubeflow)
kubectl apply -f k8s/base/kserve/

# llm-d scheduler
kubectl apply -f k8s/base/llm-d/

# Gateway API
kubectl apply -f k8s/base/gateway/
```

### Apply local overlay

```bash
kubectl apply -k k8s/overlays/local-krunkit/
```

### Smoke test

```bash
curl -s http://inference.local/v1/models
curl -s http://inference.local/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen-8b","messages":[{"role":"user","content":"hello"}]}'
```

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

| Aspect | Local | GKE/EKS |
| ------ | ----- | ------- |
| GPU type | virtio-gpu (Vulkan via krunkit) | NVIDIA A100/H100 (CUDA) |
| Engine | llama-server (llama.cpp) | vLLM or TensorRT-LLM |
| Model format | GGUF | Safetensors / TRT engine |
| Throughput | ~25–70 tok/s per model | ~3,000+ tok/s per node |
| Tensor parallelism | No (single GPU) | Yes (multi-GPU NVLink) |
| Node count | 1 | N GPU nodes |
| llm-d precision | Load-aware (no KV-Events from llama-server) | Precise KV-cache-aware (vLLM) |

The throughput differs, but every K8s manifest, every CRD, every routing rule, every autoscaling policy, every canary configuration is identical.

---

## Deployment Files (in inference-stack repo)

```
inference-stack/
├── k8s/
│   ├── base/
│   │   ├── namespace.yaml
│   │   ├── kserve/
│   │   │   ├── qwen-8b.yaml          # InferenceService CRD
│   │   │   ├── qwen-4b.yaml
│   │   │   └── qwen-05b.yaml
│   │   ├── llm-d/
│   │   │   ├── envoy-config.yaml
│   │   │   └── epp-deployment.yaml
│   │   ├── gateway/
│   │   │   ├── gateway.yaml
│   │   │   └── httproute.yaml
│   │   ├── device-plugin/
│   │   │   └── daemonset.yaml
│   │   └── monitoring/
│   │       ├── prometheus-rules.yaml
│   │       └── grafana-dashboard.json
│   ├── overlays/
│   │   ├── local-krunkit/
│   │   │   └── kustomization.yaml     # llama-server image, squat.ai/dri, hostPath
│   │   ├── local-native/
│   │   │   └── kustomization.yaml     # ExternalName to host.minikube.internal
│   │   └── gke-production/
│   │       └── kustomization.yaml     # vLLM image, nvidia.com/gpu, pd-ssd
│   └── models/
│       ├── qwen2.5-8b-q4.yaml
│       ├── qwen2.5-4b-q4.yaml
│       └── qwen2.5-05b-q4.yaml
├── native/
│   ├── start-inference.sh
│   └── com.inference.mlx-server.plist
├── scripts/
│   ├── setup.sh                       # Install krunkit, vmnet-helper, KServe, llm-d
│   ├── smoke-test.sh                  # Health + completions + model list
│   └── benchmark.sh                   # Throughput measurement
├── docs/
│   └── design.md                      # This document
└── Makefile
    # make local-up       → krunkit start + deploy base + local overlay
    # make local-native   → docker driver + deploy base + native overlay
    # make gke-deploy     → deploy base + gke overlay
    # make smoke-test     → health + completions
    # make benchmark      → throughput test
```
