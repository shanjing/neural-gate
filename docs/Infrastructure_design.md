# Infrastructure Design

**Scope:** How neural-gate manages, deploys, and serves inference workloads on Kubernetes. This document is platform-agnostic — the same Helm chart and KServe architecture applies to K8, GKE, EKS and Minikube. Platform-specific details (krunkit, NVIDIA drivers, cloud load balancers) are handled entirely through Helm value overrides.

See [Inference_design.md](Inference_design.md) for engine selection, GPU passthrough mechanics, and memory budgets.

---

## Guiding Principles

1. **One chart, N environments.** A single Helm chart (`k8s/neural-gate/`) defines all Kubernetes resources. Platform differences are expressed as value overrides, not separate manifests.
2. **KServe as the control plane.** Every model is a `InferenceService` CRD. KServe manages pod lifecycle, autoscaling, and traffic splitting — the same primitives used in production GKE/EKS clusters.
3. **Gateway API for routing.** Kubernetes Gateway API (not legacy Ingress) provides host-based routing to model endpoints. KServe and llm-d integrate natively with Gateway API.
4. **setup.sh drives parameters, Helm drives state.** The interactive setup script collects user choices (which models, what resources) and passes them as `--set` flags to `helm upgrade --install`. Kubernetes state is managed by Helm, not by ad-hoc `kubectl apply`.

---

## Kubernetes Architecture

```
                        ┌─────────────────────────────┐
                        │     Gateway API (Envoy)     │
                        │  inference-gateway :80      │
                        └──────────┬──────────────────┘
                                   │  HTTPRoute per model
                          ┌────────┴────────┐
                          ▼                 ▼
                   ┌─────────────┐    ┌─────────────┐
                   │ HTTPRoute:  │    │ HTTPRoute:  │
                   │ qwen3-8b    │    │ qwen3-4b    │
                   │ .inference  │    │ .inference  │
                   │ .local      │    │ .local      │
                   └──────┬──────┘    └──────┬──────┘
                          │                  │
               ┌──────────┴──┐        ┌──────┴──────────┐
               │ llm-d EPP   │        │  (passthrough   │
               │ scheduler   │        │   if disabled)  │
               └──────┬──────┘        └──────┬──────────┘
                      │                      │
            ┌─────────┴─────────┐   ┌────────┴──────────┐
            │ InferenceService  │   │ InferenceService  │
            │ qwen3-8b          │   │ qwen3-4b          │
            │ (KServe-managed   │   │                   │
            │  Deployment+Svc)  │   │                   │
            └───────────────────┘   └───────────────────┘
```

### Resource Layers

| Layer | Managed by | What it does |
|---|---|---|
| **Gateway** | Helm chart template | Single entry point. Envoy Gateway listens on port 80, MetalLB or cloud LB assigns an external IP. |
| **HTTPRoute** | Helm chart template (per model) | Host-based routing: `<model>.inference.local` to the model's KServe predictor service. |
| **llm-d EPP** | Helm chart template | External Processing Plugin for Envoy. Routes requests to the pod with the best KV cache affinity. |
| **InferenceService** | Helm chart template (per model) + KServe controller | KServe CRD. The controller creates a Deployment, Service, and optional HPA for each model. |
| **Device Plugin** | Helm chart template (DaemonSet) | Registers `/dev/dri` as `squat.ai/dri` on each node so pods can request GPU access via standard resource limits. |
| **Monitoring** | Helm chart template | Prometheus alerting rules and a Grafana dashboard ConfigMap. |

---

## Helm Chart Structure

```
k8s/neural-gate/
├── Chart.yaml                          # Chart metadata (v0.1.0)
├── values.yaml                         # Defaults: local-krunkit (Apple Silicon)
├── values-gke.yaml                     # GKE production overrides
├── templates/
│   ├── _helpers.tpl                    # Common labels, model name sanitizer
│   ├── namespace.yaml                  # inference namespace
│   ├── device-plugin.yaml              # DaemonSet: squat.ai/dri (conditional)
│   ├── model-inferenceservice.yaml     # KServe InferenceService (loops models[])
│   ├── gateway.yaml                    # Gateway API Gateway resource
│   ├── httproute.yaml                  # HTTPRoute per model (loops models[])
│   ├── llm-d/
│   │   ├── envoy-config.yaml           # Envoy static config with ext_proc filter
│   │   └── epp-deployment.yaml         # EPP scheduler Deployment + Service
│   └── monitoring/
│       ├── prometheus-rules.yaml       # Alerting rules (P99 latency, KV cache)
│       └── grafana-dashboard.yaml      # Dashboard JSON wrapped in ConfigMap
```

### Key Helm Values

The chart is designed so `setup.sh` only needs to pass model-specific overrides via `--set`. Everything else has sensible defaults.

```yaml
# values.yaml (abbreviated)

namespace: inference

engine:
  image: quay.io/ramalama/ramalama:latest
  command: [llama-server, --host, "0.0.0.0", --port, "8080"]
  extraArgs: [-ngl, "999", --ctx-size, "4096"]
  gpu:
    resource: squat.ai/dri      # override to nvidia.com/gpu on GKE
    count: 1

models: []                       # populated dynamically by setup.sh

gateway:
  enabled: true
  className: envoy               # override to gke-l7-global-external-managed
  hostname: inference.local

monitoring:
  enabled: true

llmd:
  enabled: true

devicePlugin:
  enabled: true                  # disabled on GKE (NVIDIA plugin built-in)

volumes:
  type: hostPath                 # override to pvc on GKE
  modelsPath: /mnt/models
```

### Model Parameterization

Each model is an entry in the `models[]` array. `setup.sh` builds the `--set` flags from the user's selection:

```bash
helm upgrade --install neural-gate ./k8s/neural-gate/ \
  --namespace inference --create-namespace \
  --set models[0].name=qwen3-8b \
  --set models[0].ggufFile=qwen3-8b.gguf \
  --set models[0].cpu.request=2 \
  --set models[0].cpu.limit=4 \
  --set models[0].memory.request=4Gi \
  --set models[0].memory.limit=8Gi \
  --set models[1].name=qwen3-4b \
  --set models[1].ggufFile=qwen3-4b.gguf \
  --set models[1].cpu.request=2 \
  --set models[1].cpu.limit=4 \
  --set models[1].memory.request=2Gi \
  --set models[1].memory.limit=4Gi
```

Adding or removing a model is a `helm upgrade` with a different `models[]` array. Helm handles the diff — new InferenceServices are created, removed ones are deleted, unchanged ones are left alone.

### Environment Overrides

GKE production uses a separate values file:

```bash
helm upgrade --install neural-gate ./k8s/neural-gate/ \
  -f ./k8s/neural-gate/values-gke.yaml \
  --set models[0].name=qwen3-70b \
  --set models[0].ggufFile=... 
```

| Value | Local (default) | GKE (`values-gke.yaml`) |
|---|---|---|
| `engine.image` | `ramalama:latest` (llama-server) | `vllm/vllm-openai:latest` |
| `engine.gpu.resource` | `squat.ai/dri` | `nvidia.com/gpu` |
| `gateway.className` | `envoy` | `gke-l7-global-external-managed` |
| `devicePlugin.enabled` | `true` | `false` |
| `volumes.type` | `hostPath` | `pvc` |

---

## KServe Integration

### Deployment Mode

KServe runs in **Standard mode** (`RawDeployment`). This means:

- No Knative dependency — plain Kubernetes Deployments + HPA
- Gateway API integration for routing (not legacy Ingress)
- Compatible with any conformant Kubernetes cluster

### KServe Dependencies

These are installed once per cluster (idempotent, handled by `setup.sh` option 4):

| Component | Version | Install Method | Purpose |
|---|---|---|---|
| cert-manager | v1.17+ | Helm (`jetstack/cert-manager`) | TLS certificates for KServe webhooks |
| Gateway API CRDs | v1.2.1 | `kubectl apply` from upstream | Gateway, HTTPRoute, GatewayClass CRDs |
| Envoy Gateway | latest | Helm (OCI) | Gateway API controller + data plane |
| KServe CRDs | v0.16.0 | Helm (OCI from `ghcr.io/kserve/charts/kserve-crd`) | InferenceService CRD definition |
| KServe controller | v0.16.0 | Helm (OCI from `ghcr.io/kserve/charts/kserve`) | Reconciles InferenceService into Deployments |

### InferenceService Lifecycle

When the Helm chart creates an InferenceService, KServe's controller:

1. Creates a **Deployment** running the inference engine container
2. Creates a **Service** (named `<model>-predictor`) pointing to the deployment
3. Optionally creates an **HPA** based on configured scaling metrics
4. Monitors the predictor's readiness probe (`/health` on port 8080)
5. Reports status back on the InferenceService's `.status.conditions`

The Helm chart's HTTPRoute references `<model>-predictor` as the backend, connecting the Gateway to the KServe-managed service.

### Model as Code

Each model's full specification — image, command, resources, GPU, volume mounts, anti-affinity — lives in the Helm chart template. The only variable inputs are the model name, GGUF filename, and resource requests. This means:

- Model deployments are reproducible from the chart + values alone
- Rolling back a model is `helm rollback neural-gate <revision>`
- The full deployment state is visible via `helm get values neural-gate`

---

## Networking

### Request Flow

```
Client (curl, app)
    │
    ▼
Gateway (Envoy, port 80, external IP from MetalLB or cloud LB)
    │
    ├── Host: qwen3-8b.inference.local → HTTPRoute → qwen3-8b-predictor:80
    ├── Host: qwen3-4b.inference.local → HTTPRoute → qwen3-4b-predictor:80
    └── Host: qwen3-0-6b.inference.local → HTTPRoute → qwen3-0-6b-predictor:80
```

### DNS Resolution

| Environment | Mechanism |
|---|---|
| Local (minikube) | MetalLB assigns a LoadBalancer IP to the Gateway's Envoy service. `/etc/hosts` maps `<model>.inference.local` to that IP. |
| GKE | Cloud load balancer assigns a public IP. Cloud DNS maps `<model>.inference.example.com`. |
| EKS | AWS ALB or NLB. Route 53 A record. |

### Endpoints per Model

Each deployed model gets:

- A KServe InferenceService (`<model>`)
- A KServe-managed predictor Service (`<model>-predictor`)
- An HTTPRoute (`<model>`) binding `<model>.<hostname>` to the predictor
- OpenAI-compatible API endpoints:
  - `GET  /health` — readiness
  - `GET  /v1/models` — model metadata
  - `POST /v1/chat/completions` — chat inference
  - `POST /v1/embeddings` — embedding (if engine supports it)

---

## llm-d Scheduling Layer

The EPP (External Processing Plugin) scheduler sits between the Gateway and model pods. It intercepts requests via Envoy's `ext_proc` filter and selects the optimal backend pod.

### Routing Strategies

| Strategy | When used | How it works |
|---|---|---|
| KV-cache-aware | vLLM on NVIDIA (GKE) | Reads vLLM's KV-Events API to find the pod with the warmest cache for the request's prefix |
| Load-aware | llama-server on krunkit (local) | Routes to the pod with the fewest in-flight requests |
| Session-aware | All environments | Sticky sessions — same client ID routes to the same pod for cache reuse |

### Architecture

```yaml
# Envoy ext_proc filter → EPP gRPC → pod selection → backend
Envoy (Gateway)
    └── ext_proc filter ──► EPP Scheduler (gRPC :9002)
                                 │
                                 ├── Score pods by cache hit
                                 ├── Score pods by load
                                 └── Return selected pod address
```

The EPP Deployment and Envoy ConfigMap are part of the Helm chart (`llm-d/` templates), gated by `.Values.llmd.enabled`.

---

## Monitoring

### Prometheus Rules

The chart deploys a ConfigMap containing Prometheus recording and alerting rules:

| Rule | Type | Condition |
|---|---|---|
| `HighP99Latency` | Alert | P99 request latency > configurable threshold (default 10s) |
| `KVCacheUtilizationHigh` | Alert | KV cache usage > configurable threshold (default 90%) |
| `inference:tokens_per_second:rate5m` | Recording | Token throughput aggregated over 5m windows |
| `inference:requests_concurrent` | Recording | In-flight requests per model |

### Grafana Dashboard

A JSON dashboard is deployed as a ConfigMap with the `grafana_dashboard: "true"` label, auto-discovered by Grafana's sidecar. Panels:

- Token throughput (tok/s) — timeseries
- KV cache utilization (%) — gauge
- Concurrent requests — stat
- Request latency P50/P99 — timeseries
- Time to first token (TTFT) — timeseries

The same dashboard works identically across local and production — only the Prometheus data source endpoint differs.

---

## Pod Scheduling

### Anti-Affinity

Each InferenceService includes `requiredDuringSchedulingIgnoredDuringExecution` pod anti-affinity on the `neural-gate/role: model-server` label with `kubernetes.io/hostname` as the topology key. This guarantees one model pod per node, preventing GPU contention.

On a 3-node cluster, this means a maximum of 3 concurrent model deployments. Excess models remain `Pending` until a node is freed. `setup.sh` warns when the selection exceeds node count.

### GPU Resource Request

Each model pod requests `squat.ai/dri: 1` (local) or `nvidia.com/gpu: 1` (GKE) as a resource limit. The Kubernetes scheduler only places the pod on a node where the device plugin has registered available GPU slots.

### Resource Budgets

Default resource requests/limits per model (overridable via `--set`):

```yaml
resources:
  requests:
    cpu: "2"
    memory: 4Gi
  limits:
    cpu: "4"
    memory: 8Gi
    squat.ai/dri: 1     # or nvidia.com/gpu: 1
```

---

## Deployment Workflow

### First-Time Setup

```
setup.sh option 1 → Configure models directory (~/.models symlink)
setup.sh option 2 → Install CLI tools (minikube, kubectl, krunkit, helm)
setup.sh option 3 → Download GGUF models from HuggingFace
setup.sh option 4 → Start cluster + install KServe infrastructure
                     ├── minikube start (3 nodes, krunkit, GPU)
                     ├── cert-manager (Helm)
                     ├── Gateway API CRDs (kubectl apply)
                     ├── Envoy Gateway (Helm)
                     ├── KServe CRDs + controller (Helm, Standard mode)
                     └── MetalLB (minikube addon + IP pool)
setup.sh option 5 → Deploy models (helm upgrade --install)
                     ├── User selects models
                     ├── helm template preview (dry-run)
                     └── helm upgrade --install with --set per model
setup.sh option 6 → Configure ingress (/etc/hosts → Gateway IP)
```

### Adding a Model

Re-run option 5. Select the new model alongside existing ones. `helm upgrade` adds the new InferenceService without touching existing deployments.

### Removing a Model

Re-run option 5 without the model. `helm upgrade` removes the InferenceService. KServe deletes the corresponding Deployment and Service.

### Updating a Model

Change the GGUF file or resource values and re-run option 5. `helm upgrade` triggers a rolling update on the affected InferenceService.

### Tearing Down

`setup.sh` option 9 deletes the minikube cluster and cleans `/etc/hosts`. On GKE, `helm uninstall neural-gate` removes all chart resources; KServe infrastructure persists for reuse.

---

## Security Considerations

- The device plugin DaemonSet runs with `privileged: true` (required for `/dev` access). This is standard for device plugins across NVIDIA, AMD, and generic-device-plugin.
- cert-manager handles TLS for KServe webhook endpoints. On GKE, this integrates with GCP Certificate Manager.
- Model weights are read-only volumes. Pods mount the models directory but do not write to it.
- The Gateway does not terminate TLS locally (HTTP only on port 80). In production, TLS termination happens at the cloud load balancer or via a cert-manager-issued certificate on the Gateway.

---

## What This Architecture Validates

Running locally with the same Helm chart as production exercises:

- **KServe InferenceService lifecycle** — deploy, update, rollback, delete via CRDs
- **Gateway API routing** — host-based routing, the Kubernetes-standard successor to Ingress
- **llm-d scheduling** — request routing through Envoy ext_proc
- **Helm-driven GitOps** — chart + values file fully describe cluster state
- **Multi-model serving** — independent scaling and lifecycle per model
- **Monitoring** — same Prometheus rules and Grafana dashboards as production
- **Anti-affinity and GPU scheduling** — pods compete for GPU resources through the K8s scheduler

The only things that change between local and production are the values file and the infrastructure prerequisites (krunkit vs NVIDIA drivers). Every Kubernetes resource, every CRD, every routing rule is identical.
