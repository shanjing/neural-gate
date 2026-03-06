# Infrastructure Implementation (Enterprise)

**Scope:** Enterprise-grade deployment of neural-gate on **GKE** and **EKS**. This document describes how to manage, deploy, and serve inference workloads for large-scale LLMs (e.g. Qwen3.5-397B-A17B-class or equivalent models) with vLLM, Gateway API, and KServe. Platform-specific value overrides (GKE vs EKS) handle load balancers, storage, and DNS.

For inference design and engine selection, see [Inference_design.md](Inference_design.md).

---

## Guiding Principles

1. **One chart, N environments.** A single Helm chart (`k8s/neural-gate/`) defines all Kubernetes resources. GKE vs EKS differences are expressed as value overrides (`values-gke.yaml`, `values-eks.yaml`), not separate manifests.
2. **KServe as the control plane.** Every model is an `InferenceService` CRD. KServe manages Deployment, Service, and HPA — the same primitives used in production GPU clusters.
3. **Gateway API for routing.** Kubernetes Gateway API provides host-based routing to model predictors. KServe and llm-d integrate natively with Gateway API; on GKE/EKS the Gateway is implemented by the cloud provider or Envoy.
4. **CI/CD and GitOps.** Model list and key parameters are driven by config in Git or a config server; Helm applies the chart with the appropriate values file. No ad-hoc `kubectl apply`.

---

## Kubernetes Architecture

```
   qwen3.5-397b.local
       DATA PLANE (Request Flow)                      MANAGEMENT PLANE (Ownership)
────────────────────────────────────────       ────────────────────────────────────────
       External Request 
               ↓
┌──────────────────────────────────────┐       ┌──────────────────────────────────────┐
│  Gateway (inference-gateway)         │       │ PLATFORM OPS (Helm)                  │
│  - Entry point for traffic           │ <──── │ - Installs Envoy Gateway Class       │
│  - Managed by Platform Team          │       │ - Deploys Gateway Resource           │
└──────────────────────────────────────┘       └──────────────────────────────────────┘
               ↓                                                  │
┌──────────────────────────────────────┐       ┌──────────────────┴───────────────────┐
│  HTTPRoute (qwen3.5-397b.local)      │       │ KSERVE OPERATOR (InferenceService)   │
│  - Hostname/Path Matching            │ <──── │ - Watches ISVC CRD                   │
└──────────────────────────────────────┘       │ - Creates Routes, Services, Pods     │
               ↓                               └──────────────────┬───────────────────┘
┌──────────────────────────────────────┐                          │
│  Service (qwen3.5-397b-predictor)    │ <────────────────────────┤
│  - Load Balances internal traffic    │                          │
└──────────────────────────────────────┘                          │
               ↓                                                  │
┌──────────────────────────────────────┐                          │
│  Pod (qwen3.5-397b-predictor-xxxxx)  │ <────────────────────────┘
│  - vLLM (8080)                       │
│  - Hardware: Nvidia                  │
└──────────────────────────────────────┘
               ↓
        [ Token Response ]
```
The Inference workflow follows a North-South traffic pattern. 

### Resource Layers

| Layer | Managed by | What it does |
|-------|------------|--------------|
| **Gateway** | Helm chart template | Single entry point. On GKE: GKE Gateway or Istio; on EKS: AWS Gateway API Controller → ALB. Cloud load balancer assigns external IP/DNS. |
| **HTTPRoute** | Helm chart template (per model) | Host-based routing: `<model>.inference.example.com` to the model's KServe predictor service. |
| **llm-d EPP** | Helm chart template | External Processing Plugin for Envoy. Routes requests to the pod with the best KV cache affinity (vLLM KV-Events). |
| **InferenceService** | Helm chart template (per model) + KServe controller | KServe CRD. Controller creates Deployment, Service, and optional HPA. Engine: vLLM (or TensorRT-LLM). |
| **Device Plugin** | Cluster (NVIDIA) | NVIDIA device plugin on GPU nodes exposes `nvidia.com/gpu`. No custom device plugin on GKE/EKS. |
| **Monitoring** | Helm chart template | Prometheus alerting rules and Grafana dashboard ConfigMap. |

---

## Helm Chart Structure (Enterprise)

```
k8s/neural-gate/
├── Chart.yaml                          # Chart metadata
├── values.yaml                         # Base (local defaults; see Local_environment.md)
├── values-gke.yaml                     # GKE production: vLLM, nvidia.com/gpu, GCE PVC
├── values-eks.yaml                     # EKS production: vLLM, nvidia.com/gpu, EBS/EFS
├── templates/
│   ├── _helpers.tpl                    # Common labels, model name sanitizer
│   ├── namespace.yaml                 # inference namespace
│   ├── device-plugin.yaml             # Disabled on GKE/EKS (NVIDIA plugin built-in)
│   ├── model-inferenceservice.yaml    # KServe InferenceService (loops models[])
│   ├── gateway.yaml                   # Gateway API Gateway resource
│   ├── httproute.yaml                 # HTTPRoute per model (loops models[])
│   ├── llm-d/
│   │   ├── envoy-config.yaml          # Envoy static config with ext_proc filter
│   │   └── epp-deployment.yaml        # EPP scheduler Deployment + Service
│   └── monitoring/
│       ├── prometheus-rules.yaml      # Alerting rules (P99 latency, KV cache)
│       └── grafana-dashboard.yaml     # Dashboard JSON wrapped in ConfigMap
```

---

## Key Helm Values (Enterprise)

For GKE/EKS, use `values-gke.yaml` or `values-eks.yaml`. The chart is designed so CI/CD or operators pass model-specific overrides via `--set` or a merged values file. Reference scale: **Qwen3.5-397B-A17B**-class models (large MoE/flagship LLMs) and 70B–72B dense models.

```yaml
# values-gke.yaml / values-eks.yaml (abbreviated, enterprise)

namespace: inference

engine:
  image: vllm/vllm-openai:latest
  command: [python3, -m, vllm.entrypoints.openai.api_server]
  contextSize: 32768                 # max prompt + completion; 262144 for long-context models
  extraArgs:
    - --host
    - "0.0.0.0"
    - --port
    - "8080"
    # --max-model-len, --tensor-parallel-size set per model
  gpu:
    resource: nvidia.com/gpu
    count: 8                          # e.g. 8 for 70B+ tensor parallel

models: []                            # populated by CI/CD or helm --set

gateway:
  enabled: true
  className: gke-l7-global-external-managed   # or EKS equivalent
  hostname: inference.example.com

monitoring:
  enabled: true

llmd:
  enabled: true                       # KV-cache-aware routing with vLLM

devicePlugin:
  enabled: false                      # NVIDIA plugin managed by cluster

volumes:
  type: pvc
  modelsPath: /mnt/models
  pvc:
    storageClass: pd-ssd              # GKE; on EKS use gp3 or io2
    size: 500Gi                       # 397B-class: large NVMe or multi-disk
```

---

## Model Parameterization (Enterprise)

Each model is an entry in the `models[]` array. For enterprise LLMs (e.g. Qwen3.5-397B-A17B, Qwen2.5-72B), parameters include model name, model path or Hugging Face ID, tensor parallelism, max context length, and resource requests/limits.

**Example: CI/CD or Helm invocations for large LLMs**

```bash
# GKE: flagship 397B-class model (multi-GPU)
helm upgrade --install neural-gate ./k8s/neural-gate/ \
  -f ./k8s/neural-gate/values-gke.yaml \
  --namespace inference --create-namespace \
  --set models[0].name=qwen3.5-397b-a17b \
  --set models[0].modelPath=Qwen/Qwen3.5-397B-A17B \
  --set models[0].tensorParallelSize=8 \
  --set models[0].maxModelLen=32768 \
  --set models[0].cpu.request=16 \
  --set models[0].cpu.limit=32 \
  --set models[0].memory.request=80Gi \
  --set models[0].memory.limit=160Gi \
  --set models[0].gpuCount=8

# Secondary 72B dense model
helm upgrade --install neural-gate ./k8s/neural-gate/ \
  -f ./k8s/neural-gate/values-gke.yaml \
  --namespace inference \
  --set models[0].name=qwen3.5-397b-a17b \
  ... \
  --set models[1].name=qwen2.5-72b \
  --set models[1].modelPath=/mnt/models/Qwen2.5-72B-Instruct \
  --set models[1].tensorParallelSize=4 \
  --set models[1].maxModelLen=32768
```

Adding or removing a model is a `helm upgrade` with an updated `models[]` array. Helm creates new InferenceServices and removes deleted ones; unchanged ones are left alone.

### Environment Overrides (GKE vs EKS)

| Value | GKE (`values-gke.yaml`) | EKS (`values-eks.yaml`) |
|-------|-------------------------|--------------------------|
| `engine.image` | `vllm/vllm-openai:latest` | Same |
| `engine.gpu.resource` | `nvidia.com/gpu` | `nvidia.com/gpu` |
| `gateway.className` | `gke-l7-global-external-managed` | AWS Gateway API / ALB |
| `devicePlugin.enabled` | `false` | `false` |
| `volumes.type` | `pvc` | `pvc` |
| `volumes.pvc.storageClass` | `pd-ssd` | `gp3` or `io2` |
| DNS | Cloud DNS | Route 53 |

---

## KServe Integration

### Deployment Mode

KServe runs in **Standard mode** (`RawDeployment`): plain Kubernetes Deployments + HPA, Gateway API for routing, no Knative. Compatible with any conformant Kubernetes cluster (GKE, EKS).

### KServe Dependencies

Installed once per cluster (CI/CD or cluster bootstrap):

| Component | Version | Install Method | Purpose |
|-----------|---------|----------------|---------|
| cert-manager | v1.17+ | Helm (`jetstack/cert-manager`) | TLS for KServe webhooks |
| Gateway API CRDs | v1.2.1 | `kubectl apply` from upstream | Gateway, HTTPRoute, GatewayClass |
| Envoy Gateway (or GKE/EKS native) | latest | Helm or provider | Gateway API controller + data plane |
| KServe CRDs | v0.16.0 | Helm (OCI) | InferenceService CRD |
| KServe controller | v0.16.0 | Helm (OCI) | Reconciles InferenceService → Deployment/Service |

### InferenceService Lifecycle

When the chart creates an InferenceService, KServe's controller:

1. Creates a **Deployment** with the vLLM (or TensorRT-LLM) container
2. Creates a **Service** (`<model>-predictor`) pointing to the deployment
3. Optionally creates an **HPA** from configured scaling metrics
4. Monitors readiness (`/health` on port 8080)
5. Updates InferenceService `.status.conditions`

The chart's HTTPRoute references `<model>-predictor` as the backend.

### Model as Code

Each model's specification — image, command, args (e.g. `--max-model-len`, `--tensor-parallel-size`), resources, GPU count, volume mounts, anti-affinity — lives in the Helm chart template. Variable inputs: model name, model path or HF id, tensor parallel size, max model length, CPU/memory/GPU. Reproducible from chart + values; rollback via `helm rollback neural-gate <revision>`.

---

## Networking

### Request Flow

```
Client (apps, agents)
    │
    ▼
Gateway (GKE LB or EKS ALB, port 80/443)
    │
    ├── Host: qwen3.5-397b-a17b.inference.example.com → HTTPRoute → qwen3.5-397b-a17b-predictor:80
    ├── Host: qwen2.5-72b.inference.example.com     → HTTPRoute → qwen2.5-72b-predictor:80
    └── ...
```

### DNS Resolution

| Environment | Mechanism |
|-------------|-----------|
| GKE | Cloud load balancer + Cloud DNS; map `<model>.inference.example.com` to LB IP. |
| EKS | ALB/NLB + Route 53 A or CNAME to the Gateway/Ingress hostname. |

### Endpoints per Model

Each deployed model gets:

- A KServe InferenceService (`<model>`)
- A predictor Service (`<model>-predictor`)
- An HTTPRoute binding `<model>.<hostname>` to the predictor
- OpenAI-compatible API: `GET /health`, `GET /v1/models`, `POST /v1/chat/completions`, `POST /v1/embeddings`

---

## llm-d Scheduling Layer

The EPP scheduler sits between the Gateway and model pods and routes requests to the pod with the best KV cache hit. On GKE/EKS with vLLM, llm-d uses vLLM's KV-Events API for precise cache introspection.

| Strategy | When used | How it works |
|----------|-----------|--------------|
| KV-cache-aware | vLLM on NVIDIA (GKE/EKS) | vLLM KV-Events API → pod with warmest cache for request prefix |
| Session-aware | All environments | Sticky sessions by client ID for cache reuse |

EPP Deployment and Envoy ConfigMap are in the chart (`llm-d/`), gated by `.Values.llmd.enabled`.

---

## Monitoring

### Prometheus Rules

ConfigMap with recording and alerting rules: `HighP99Latency`, `KVCacheUtilizationHigh`, `inference:tokens_per_second:rate5m`, `inference:requests_concurrent`.

### Grafana Dashboard

Dashboard ConfigMap (panels: token throughput, KV cache utilization, concurrent requests, P50/P99 latency, TTFT). Same dashboard across environments; only the Prometheus data source differs.

---

## Pod Scheduling

### Anti-Affinity

Each InferenceService uses pod anti-affinity on `neural-gate/role: model-server` with `kubernetes.io/hostname`, so one model pod per node and no GPU contention across models.

### GPU Resource Request

Pods request `nvidia.com/gpu: <N>` (e.g. 8 for 70B+ tensor parallel). Scheduler places pods only on nodes with sufficient NVIDIA GPU capacity.

### Resource Budgets (Enterprise Reference)

For **Qwen3.5-397B-A17B**-class and 70B dense models, typical per-model budgets (overridable per model):

| Model scale | Tensor parallel | GPU count | Memory (request/limit) | CPU |
|-------------|-----------------|-----------|------------------------|-----|
| 70B–72B     | 4–8             | 4–8       | 80Gi–160Gi             | 16–32 |
| 397B-class (MoE) | 8+        | 8+        | 160Gi+                 | 32+  |

---

## Deployment Workflow (Enterprise)

### First-Time / CI-CD

1. **Bootstrap cluster** — Install cert-manager, Gateway API CRDs, Envoy Gateway (or use GKE/EKS native Gateway), KServe CRDs and controller.
2. **Configure values** — Use `values-gke.yaml` or `values-eks.yaml`; provide `models[]` from Git or config server (model name, path or HF id, tensor parallel size, max-model-len, resources).
3. **Deploy chart** — `helm upgrade --install neural-gate ./k8s/neural-gate/ -f values-gke.yaml ...` with model overrides.
4. **DNS** — Map `<model>.inference.example.com` to the Gateway’s external address (Cloud DNS or Route 53).

### Adding / Removing / Updating a Model

Update the `models[]` in config and re-run `helm upgrade`. Helm adds new InferenceServices, removes deleted ones, and triggers rolling updates for changed ones.

### Tearing Down

`helm uninstall neural-gate` removes all chart resources. KServe infrastructure (CRDs, controller) can remain for reuse.

---

## Security Considerations

- **NVIDIA device plugin** is cluster-managed on GKE/EKS; no custom privileged DaemonSet for enterprise.
- **cert-manager** provides TLS for KServe webhooks; on GKE this can integrate with GCP Certificate Manager.
- **Model weights** are read-only (PVC or EFS); pods do not write to the model store.
- **TLS**: In production, terminate TLS at the cloud load balancer or via cert-manager on the Gateway.

---

## What This Architecture Delivers (Enterprise)

- **KServe InferenceService lifecycle** — Deploy, update, rollback, delete via CRDs; same pattern for 72B and 397B-class models.
- **Gateway API routing** — Host-based routing at scale; GKE or EKS load balancer.
- **llm-d scheduling** — KV-cache-aware routing with vLLM for low latency and high throughput.
- **Helm-driven GitOps** — Chart + values fully describe cluster state; CI/CD applies changes.
- **Multi-model serving** — Independent scaling and lifecycle per model (e.g. 397B flagship + 72B dense).
- **Monitoring** — Prometheus rules and Grafana dashboards for SLO tracking.

For **local Apple Silicon / krunkit** and **SLM** Helm values and model parameterization, see [Local_environment.md](Local_environment.md).
