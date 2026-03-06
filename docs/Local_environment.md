# The "Digital Twin" of the production Inference stack

This local environment aims to be an ideal "high-fidelity sandbox" running on a MacBook Pro for SREs and Cloud Architects. It can be used for the validation of the production environment's logical control plane without incurring cloud costs or requiring access to restricted production

This document describes how the high-tier productin grade Inference is implemented **locally** on **an Apple Silicon Mac Mini(or a Macbook Pro)** using **minikube with the krunkit driver** and **llama-server**. It has exact the same architecture as production (KServe, Gateway API, Helm chart) with the exception of using llama-server instead of vLLM on GKE/EKS for Inference Engine. 

Enterprise implementation with GKE/EKS that supports large LLMs is in [Infrastructure_implementation.md](Infrastructure_implementation.md). For inference design, see [Inference_design.md](Inference_design.md).

**Apple Silicon / krunkit:** All references to local GPU passthrough, Metal limitations, virtio-gpu, and the generic-device-plugin (`squat.ai/dri`) in this repo are documented here for clarity. The Helm chart’s `values.yaml` defaults target this environment.

**Hardware recommendations:** Apple Silicon M3 Ultra + 512GB RAM for large LLMs; M4 Pro + 64GB RAM for SLMs.

---
## Kubernetes Architect

```
       DATA PLANE (Request Flow)                      MANAGEMENT PLANE (Ownership)
────────────────────────────────────────       ────────────────────────────────────────
   External Request (qwen3-8b.local)
               ↓
┌──────────────────────────────────────┐       ┌──────────────────────────────────────┐
│  Gateway (inference-gateway)         │       │ PLATFORM OPS (Manual/Helm)           │
│  - Entry point for traffic           │ <──── │ - Installs Envoy Gateway Class       │
│  - Managed by Platform Team          │       │ - Deploys Gateway Resource           │
└──────────────────────────────────────┘       └──────────────────────────────────────┘
               ↓                                                  │
┌──────────────────────────────────────┐       ┌──────────────────┴───────────────────┐
│  HTTPRoute (qwen3-8b)                │       │ KSERVE OPERATOR (InferenceService)   │
│  - Hostname/Path Matching            │ <──── │ - Watches ISVC CRD                   │
└──────────────────────────────────────┘       │ - Creates Routes, Services, Pods     │
               ↓                               └──────────────────┬───────────────────┘
┌──────────────────────────────────────┐                          │
│  Service (qwen3-8b-predictor)        │ <────────────────────────┤
│  - Load Balances internal traffic    │                          │
└──────────────────────────────────────┘                          │
               ↓                                                  │
┌──────────────────────────────────────┐                          │
│  Pod (qwen3-8b-predictor-xxxxx)      │ <────────────────────────┘
│  - llama-server (8080)               │
│  - Hardware: Apple Metal             │
└──────────────────────────────────────┘
               ↓
        [ Token Response ]
```

## Repo layout (local macOS focus)

```
neural-gate/
├── k8s/neural-gate/
│   ├── Chart.yaml
│   ├── values.yaml             # Defaults: local-krunkit (llama-server, squat.ai/dri)
│   ├── values-gke.yaml         # GKE overrides (vLLM, nvidia.com/gpu, PVC)
│   └── templates/
├── scripts/
│   ├── setup.sh                # Cluster, KServe infra, Helm deploy, ingress
│   ├── smoke-test.sh
│   ├── benchmark.sh
│   └── competitions.sh
├── docs/
│   ├── Inference_design.md     # Production inference design
│   ├── Local_environment.md    # This document
│   ├── mac_runbook.md          # macOS setup and smoke test
│   └── ...
└── requirements.txt
```

Deployment is driven by `scripts/setup.sh`: option 4 installs the cluster and KServe stack (cert-manager, Gateway API CRDs, Envoy Gateway, KServe CRDs and controller, MetalLB); option 5 runs `helm upgrade --install neural-gate` with `--set` for the selected models. See [Infrastructure_implementation.md](Infrastructure_implementation.md) for the enterprise Helm chart structure (GKE/EKS).

---

## Helm values and model parameterization (SLMs / local)

The chart’s **default** `values.yaml` targets local Apple Silicon: llama-server (ramalama), GGUF models, and the generic-device-plugin (`squat.ai/dri`). These values are used when you run `setup.sh` option 5 without a platform override.

### Key Helm values (local / SLM)

```yaml
# values.yaml (abbreviated — local krunkit / SLM defaults)

namespace: inference

engine:
  image: quay.io/ramalama/ramalama:latest
  command: [llama-server, --host, "0.0.0.0", --port, "8080"]
  contextSize: 4096              # max prompt + completion tokens; increase (e.g. 8192, 16384) for longer prompts
  extraArgs: [-ngl, "999"]       # offload all layers to GPU (Vulkan)
  gpu:
    resource: squat.ai/dri       # generic-device-plugin on krunkit; 1 GPU per pod
    count: 1

models: []                       # populated by setup.sh option 5 via --set

gateway:
  enabled: true
  className: envoy
  hostname: inference.local

monitoring:
  enabled: true

llmd:
  enabled: false                  # optional; set true when EPP image is available

devicePlugin:
  enabled: true                  # DaemonSet: exposes /dev/dri as squat.ai/dri

volumes:
  type: hostPath
  modelsPath: /mnt/models        # mounted from host via minikube mount (~/.models)
```

### Model parameterization (SLMs)

Each model is an entry in the `models[]` array. For **SLMs** (e.g. Qwen3-1.7B, Qwen3-8B, Qwen2.5-32B), the chart expects a **GGUF filename** and optional per-model `contextSize`, plus CPU/memory. `setup.sh` option 5 builds the `--set` flags from the user’s selection in the models directory.

**Example: Helm invocations for SLMs (local)**

```bash
helm upgrade --install neural-gate ./k8s/neural-gate/ \
  --namespace inference --create-namespace \
  --set models[0].name=qwen3-8b \
  --set models[0].ggufFile=qwen3-8b.gguf \
  --set models[0].cpu.request=2 \
  --set models[0].cpu.limit=4 \
  --set models[0].memory.request=4Gi \
  --set models[0].memory.limit=8Gi \
  --set models[1].name=qwen3-1-7b \
  --set models[1].ggufFile=qwen3-1.7b.gguf \
  --set models[1].cpu.request=2 \
  --set models[1].cpu.limit=4 \
  --set models[1].memory.request=2Gi \
  --set models[1].memory.limit=4Gi
```

- **name** — Kubernetes-safe model name (used for InferenceService, Service, HTTPRoute).
- **ggufFile** — Filename of the GGUF under the models directory (e.g. `qwen3-8b.gguf`). The container mounts the directory and loads `$modelsPath/$ggufFile`.
- **contextSize** — Optional; overrides `engine.contextSize` for this model (e.g. 8192 for longer context).
- **cpu.request / cpu.limit**, **memory.request / memory.limit** — Resource requests and limits for the predictor pod. Defaults in the template are 2/4 CPU and 4Gi/8Gi memory if not set.

Adding or removing a model is a `helm upgrade` with an updated `models[]`; Helm creates or deletes the corresponding InferenceServices.

---

## GPU passthrough: Minikube krunkit driver

Production clouds run on NVIDIA, but macOS doesn't. The focus here is how to offer Minikube a path to access the Mac's local GPU resources.

| Minikube driver | VM technology                   | GPU passthrough?            |
| --------------- | ------------------------------- | --------------------------- |
| docker          | Docker Desktop Linux VM         | No — no Metal in VM         |
| krunkit         | Apple Virtualization.framework  | **Yes** — virtio-gpu device |

The **krunkit driver** uses Apple's native Virtualization.framework and exposes the host GPU as `/dev/dri` (virtio-gpu) inside the VM. A `generic-device-plugin` DaemonSet makes it schedulable as a K8s resource (`squat.ai/dri`). Pods request GPU access via standard resource limits.

**Requirements:** Apple Silicon, macOS 14+, minikube v1.37.0+, krunkit v1.0.0+, vmnet-helper.

```bash
brew tap slp/krunkit && brew install krunkit
curl -fsSL https://github.com/minikube-machine/vmnet-helper/releases/latest/download/install.sh | bash

minikube start --driver krunkit --mount-string ~/.models:/mnt/models
```

The virtio-gpu device provides Vulkan-level GPU compute. llama-server (llama.cpp) uses this via its Vulkan backend with `-ngl 999` (offload all layers to GPU). This enables model inference **inside K8s pods with GPU acceleration — the same Deployment/Service/Ingress pattern as GKE.**

### Metal GPU limitation

Apple's Metal framework has no container GPU passthrough. To build the Inference stack in macOS, we need a GPU provisioner for the Inference Engine. So:
- vLLM-Metal and vLLM-MLX are native macOS LLM providers — they are not GPU provisioner for K8s 
- The krunkit virtio-gpu path uses Vulkan to 'provision' Apple Silicon's local GPUs.
- This is why llama-server (GGUF + Vulkan) is the engine for the in-cluster local path (Helm default values).

---

## Engine options (local)

| Engine                   | Hardware                | GPU API               | Format | In K8s pod? | Use case                    |
| ------------------------ | ----------------------- | --------------------- | ------ | ----------- | --------------------------- |
| llama-server (llama.cpp) | Apple Silicon (krunkit) | Vulkan via virtio-gpu | GGUF   | **Yes**     | In-cluster production-like  |

### Native-only engines (fallback / daily use)

These run as macOS processes, not inside K8s. Use with ExternalName Service when full-stack simulation is not needed.

| Engine     | Status          | Notes                                                                 |
| ---------- | --------------- | --------------------------------------------------------------------- |
| mlx-lm     | Stable          | Native Metal, simple.                                                  |
| vLLM-MLX   | Sub-v1.0 (2025) | vLLM-like scheduling + MLX. `pip install vllm-mlx`.                   |
| vLLM-Metal | Sub-v1.0 (2026) | Official vLLM plugin. Text-only.                                       |
| Ollama     | Stable          | Wraps llama.cpp. Easiest setup, slightly lower throughput.            |

All native engines use Metal GPU directly. The server must bind to `0.0.0.0`, not `127.0.0.1`. Cluster nodes reach the host via a non-loopback IP.

**Process management:** macOS uses launchd (`~/Library/LaunchAgents/`).

---

## Multi-model local setup

### Model selection (krunkit in-cluster)

Current lineup: Qwen3 1.7B and 8B (GGUF), plus Qwen2.5 32B for high-quality or native single-model use.

| Model                 | Disk     | Active memory | Role                              |
| --------------------- | -------- | ------------- | --------------------------------- |
| Qwen3-8B (GGUF Q4)    | ~5 GB    | ~6 GB         | Primary — quality, chat           |
| Qwen3-1.7B (GGUF Q4)  | ~1.3 GB  | ~2 GB         | Secondary — fast, canary / A/B     |
| Qwen2.5-32B (GGUF Q4) | ~18 GB   | ~23 GB        | Primary (single-model) or flagship |

### Memory budget (64 GB unified, krunkit full-stack)

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

With all three models the VM uses ~40 GB; ~17 GB headroom allows KV caches to grow. For more headroom, run only 8B + 1.7B in-cluster and use 32B natively (see below).

### Single-model native setup (fallback)

For daily use without full-stack simulation, run one model natively (e.g. mlx-lm or Ollama):

| Model                 | Disk     | Active memory | Decode speed   |
| --------------------- | -------  | ------------- | -------------- |
| Qwen2.5-32B (GGUF Q4) | ~18 GB   | ~23 GB        | ~25–40 tok/s   |
| Qwen3-8B (GGUF Q4)    | ~5 GB    | ~6 GB         | ~50–80 tok/s   |
| Qwen3-1.7B (GGUF Q4)  | ~1.3 GB  | ~2 GB         | ~100–150 tok/s |

---

## Storage sizing (local)

| Component               | Size      | Notes                    |
| ----------------------- | --------- | ------------------------- |
| Qwen3-8B (GGUF Q4)      | ~5 GB     | Primary                   |
| Qwen3-1.7B (GGUF Q4)    | ~1.3 GB   | Secondary / canary        |
| Qwen2.5-32B (GGUF Q4)   | ~18 GB    | Flagship / single-model   |
| HF cache overhead       | ~1 GB     | Tokenizer configs         |
| **PV total**            | **26 Gi** | Rounded up                |

---

## Mac Mini M4 Pro — hardware example

- Chip: Apple M4 Pro (12-core CPU: 8P + 4E, 20-core GPU)
- Memory: 64 GB unified (CPU + GPU share the same pool)
- Storage: External NVMe, 1.7 TB free

### krunkit cluster start

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

1. **Option 4 — Start cluster**  
   Starts minikube (krunkit, 3 nodes, mount `~/.models:/mnt/models`) and installs KServe infrastructure: cert-manager, Gateway API CRDs, Envoy Gateway, KServe CRDs and controller, MetalLB, and the `envoy` GatewayClass.

2. **Option 5 — Deploy inference stack**  
   Runs `helm upgrade --install neural-gate ./k8s/neural-gate/` with `--set` for the models you select from the models directory.

3. **Option 6 — Configure ingress**  
   Ensures the Gateway has a LoadBalancer IP (MetalLB) and adds `*.inference.local` to `/etc/hosts`. On macOS, the MetalLB IP is often not routable from the host; use port-forward to reach predictors.

4. **Reach a model from the host**

```bash
kubectl port-forward -n inference svc/qwen3-1-7b-predictor 8081:80
curl -s http://127.0.0.1:8081/v1/models
curl -s http://127.0.0.1:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-1-7b","messages":[{"role":"user","content":"hello"}]}'
```

See [mac_runbook.md](mac_runbook.md) for full setup and smoke-test steps.

---

## Environment mapping (local vs GKE vs EKS)

| Component    | Local (`values.yaml`)        | GKE (`values-gke.yaml`)      | EKS (`values-eks.yaml`)       |
| ----------- | ---------------------------- | ----------------------------- | ----------------------------- |
| Engine      | llama-server (ramalama)      | vLLM                          | vLLM                          |
| GPU resource| squat.ai/dri                 | nvidia.com/gpu                | nvidia.com/gpu                |
| Model format| GGUF                         | Safetensors                   | Safetensors                   |
| PV          | hostPath via krunkit mount   | GCE pd-ssd (PVC)              | EBS (gp3/io2) or EFS         |
| Gateway     | Envoy Gateway (MetalLB)      | GKE Gateway or Istio          | AWS Gateway API Controller → ALB |
| DNS         | /etc/hosts → *.inference.local | Cloud DNS A record          | Route 53 A or CNAME          |

---

## What this stack validates locally

- **KServe CRDs**: Deploy/update models declaratively — same YAML patterns as GKE.
- **Autoscaling**: Scale model pods 0→N based on queue depth / batch size.
- **Canary rollouts**: Route traffic between model versions, promote if latency meets SLO.
- **llm-d routing**: Requests hit the least-loaded pod with best cache affinity (when enabled).
- **Multi-model serving**: KServe manages multiple model lifecycles independently.
- **Rolling updates**: Swap model versions with zero downtime.
- **Monitoring**: Same Prometheus rules and Grafana dashboards as production.

### What differs from production (GKE)

| Aspect             | Local (krunkit)                    | GKE/EKS                       |
| ------------------ | ---------------------------------- | ----------------------------- |
| GPU type           | virtio-gpu (Vulkan via krunkit)    | NVIDIA A100/H100 (CUDA)       |
| Engine             | llama-server (llama.cpp)           | vLLM or TensorRT-LLM          |
| Model format       | GGUF                               | Safetensors / TRT engine      |
| Tensor parallelism | No (single GPU)                    | Yes (multi-GPU NVLink)        |
| Node count         | 1 (or 3-node minikube)             | Army of GPU nodes             |
| llm-d precision    | Load-aware (no KV-Events)          | Precise KV-cache-aware (vLLM) |
| Throughput         | ~25–70 tok/s (Mini taking stand?)  | ~3,000+ tok/s per node        |
| Costs              | $0 + a hot Mini in the morning     | $$$$ drained by a bad LLM loop|

The throughput differs, but every K8s manifest, CRD, routing rule, autoscaling policy, and canary configuration is aligned with production.
