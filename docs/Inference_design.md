# neural-gate Inference Design

**Scope:** A production-grade inference stack for **GCP GKE** and **AWS EKS**. It serves agentic applications via a unified, OpenAI-compatible API with enterprise-level control plane, scheduling, and observability.

This document focuses on **inference design and GKE/EKS enterprise components**. For detailed implementations such as Kubernetes layout and Helm chart, see [Infrastructure_implementation.md](Infrastructure_implementation.md).

---

## End-goals

1. **Production inference stack** — KServe control plane, llm-d scheduling, and vLLM/TensorRT-LLM engines for large-scale workloads on GKE/EKS.
2. **Private internal LLM for all agentic apps** — One shared service; every app points `LLM_ENDPOINT` at the same API.
3. **CI/CD for cloud deployment** — Helm value overrides (e.g. `values-gke.yaml`, `values-eks.yaml`) swap engine image, GPU resource, and storage per platform. App code stays unchanged.
4. **Observability** — End-to-end, transparent monitoring with Prometheus and Grafana.

---

## Three-tier architecture

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
│  Execution Engine — per-pod                                │
│  GKE/EKS: vLLM (CUDA) or TensorRT-LLM                       │
│  API: /v1/chat/completions, /v1/models, /v1/embeddings     │
└─────────────────────────────────────────────────────────────┘
```

**Control plane (KServe)** manages model deployments as Kubernetes CRDs (`InferenceService`). It handles canary rollouts, A/B testing, autoscaling, model versioning, and multi-model serving. KServe is CNCF incubating, standalone — no Kubeflow required.

**Scheduling layer (llm-d)** sits between the Gateway and engine pods. It routes requests to the pod with the warmest KV cache (significant latency and throughput gains in benchmarks). Supports prefill/decode disaggregation. Built on Kubernetes Gateway API with Envoy data plane.

**Execution engine** runs inside each pod, owns the GPU, loads the model, manages KV cache, and batches requests. Exposes the OpenAI-compatible API. On GKE and EKS the engine is vLLM or TensorRT-LLM (NVIDIA GPU nodes).

---

## Inference engines (GKE / EKS / enterprise)

| Engine           | Hardware     | GPU API | Format       | Use case                |
| ---------------- | ------------ | ------- | ------------ | ----------------------- |
| vLLM             | NVIDIA GPU   | CUDA   | Safetensors  | GKE/EKS production      |
| TensorRT-LLM     | NVIDIA GPU   | CUDA   | TRT engine   | GKE/EKS max throughput  |
| TGI              | NVIDIA GPU   | CUDA   | Safetensors  | GKE/EKS simple ops      |

vLLM is the default in `values-gke.yaml` and the same pattern applies on EKS: high throughput, paged attention, OpenAI-compatible server. TensorRT-LLM is used when maximum throughput and latency are required. TGI offers a simpler operational profile. On **EKS**, use GPU-optimized node groups (e.g. P4d, P5, or g5 instances) and the NVIDIA device plugin; the same InferenceService and vLLM image run unchanged.

---

## K8s components (production path)

### KServe InferenceService (vLLM)

Each model is a KServe `InferenceService` CRD. KServe manages the Deployment, Service, and optional autoscaler. In neural-gate, one InferenceService per model is generated from the Helm template; for GKE and EKS the predictor uses the vLLM container.

**Example: InferenceService with vLLM container (GKE or EKS)**

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: qwen-72b
  namespace: inference
spec:
  predictor:
    containers:
    - name: inference-engine
      image: vllm/vllm-openai:latest
      command: [python3, -m, vllm.entrypoints.openai.api_server]
      args:
        - --host
        - "0.0.0.0"
        - --port
        - "8080"
        - --model
        - /mnt/models/Qwen2.5-72B-Instruct  # or Hugging Face model id
        - --max-model-len
        - "32768"
        - --tensor-parallel-size
        - "1"
      ports:
      - name: http
        containerPort: 8080
        protocol: TCP
      resources:
        requests:
          cpu: "4"
          memory: 16Gi
        limits:
          cpu: "8"
          memory: 32Gi
          nvidia.com/gpu: "1"
      readinessProbe:
        httpGet:
          path: /health
          port: 8080
        initialDelaySeconds: 60
        periodSeconds: 10
      volumeMounts:
      - name: models
        mountPath: /mnt/models
    volumes:
    - name: models
      persistentVolumeClaim:
        claimName: model-weights
```

For multi-GPU, set `--tensor-parallel-size` to the number of GPUs and increase `nvidia.com/gpu` in limits. Model path can be a directory on the PVC (Safetensors) or a Hugging Face model id if the image supports it.

### llm-d scheduler (optional)

When enabled, llm-d sits between the Gateway and model pods and routes requests to the pod with the best KV cache hit. On GKE and EKS with vLLM, llm-d can use vLLM's KV-Events API for precise cache introspection. Scorers: KV-cache-aware, prefix-aware, session-aware, load-aware.

### Gateway API

Gateway API is the Kubernetes-standard successor to Ingress. neural-gate uses it for host-based routing to model predictors (e.g. `qwen-72b.inference.example.com` → predictor Service).

- **GKE:** Gateway is typically implemented by the GKE Gateway controller or Istio (`gatewayClassName: gke-l7-global-external-managed` or similar).
- **EKS:** Use the AWS Gateway API Controller (or ALB Ingress Controller with Ingress) and an appropriate GatewayClass; the Gateway provisions an Application Load Balancer. Route53 can map hostnames to the ALB.

For LLM workloads:

- **proxy-buffering: off** — required for streaming completions (SSE).
- **proxy-read-timeout: 300** — 5-minute timeout for long generations.

### PersistentVolume and PVC

Model weights persist independently of pod lifecycle. Reclaim policy: `Retain`. Models are staged via CI/CD or init jobs; pods mount the PVC at `/mnt/models`.

- **GKE:** PersistentVolumeClaim backed by GCE pd-ssd (or higher-tier SSD).
- **EKS:** PVC backed by EBS (e.g. gp3 for cost-effective, io2 for high IOPS). For read-only shared weights across replicas, EFS is an option; otherwise one EBS volume per pod or StatefulSet.

### Monitoring

Prometheus scrapes engine metrics (tokens/s, batch size, queue depth, GPU utilization). Grafana dashboards provide SLO tracking. The same alerting rules and dashboard definitions work across environments; only the data source endpoint changes. See the chart's `monitoring/` templates (Prometheus rules, Grafana dashboard ConfigMap).

---

## Storage sizing (GKE / EKS production)

| Component                | Size       | Notes                     |
| ------------------------ | ---------- | ------------------------- |
| Primary model (70B FP8)  | ~70 GB     | Multi-GPU tensor parallel |
| Secondary model slot     | ~70 GB     | A/B testing               |
| HF cache overhead        | ~5 GB      | Tokenizers, configs       |
| **PV total**             | **300 Gi** | GKE: pd-ssd; EKS: EBS gp3 / io2 |

Weights live on the fastest available persistent storage: **GKE** — pd-ssd or NVMe-backed storage class; **EKS** — EBS gp3 (general purpose) or io2 (high IOPS), or EFS for read-only shared access.

---

## Environment mapping (Helm values)

Production uses the same Helm chart with platform-specific value overrides:

| Component    | GKE (`values-gke.yaml`)              | EKS (`values-eks.yaml` or equivalent) |
| ------------ | ------------------------------------ | ------------------------------------- |
| Engine image | `vllm/vllm-openai:latest`             | Same                                   |
| GPU resource | `nvidia.com/gpu: 1` (or more)        | Same (NVIDIA device plugin on GPU nodes) |
| Model format | Safetensors (FP8/FP16)               | Same                                   |
| PV backend   | GCE pd-ssd (PVC)                     | EBS (gp3 / io2) or EFS                 |
| Gateway      | GKE Gateway or Istio                 | AWS Gateway API Controller → ALB      |
| Autoscaler   | HPA + KServe built-in (scale-to-zero)| Same                                   |
| llm-d        | Optional; precise KV-cache (vLLM)    | Same                                   |
| DNS          | Cloud DNS                             | Route53                                |

Local/minikube setup is documented in [Local_environment.md](Local_environment.md).

---

## Deployment files (neural-gate repo)

All Kubernetes resources are defined in the Helm chart. Model InferenceServices and HTTPRoutes are generated from the `models` list in values (e.g. from CI/CD or `setup.sh` for local).

```
neural-gate/
├── k8s/neural-gate/
│   ├── Chart.yaml
│   ├── values.yaml                   # Local defaults (see Local_environment.md)
│   ├── values-gke.yaml               # GKE overrides (vLLM, nvidia.com/gpu, GCE PVC)
│   ├── values-eks.yaml               # EKS overrides (vLLM, nvidia.com/gpu, EBS/EFS)
│   └── templates/
│       ├── _helpers.tpl
│       ├── namespace.yaml
│       ├── device-plugin.yaml        # Omit or disable on GKE/EKS (NVIDIA plugin)
│       ├── model-inferenceservice.yaml
│       ├── gateway.yaml
│       ├── httproute.yaml
│       ├── llm-d/
│       │   ├── envoy-config.yaml
│       │   └── epp-deployment.yaml
│       └── monitoring/
│           ├── prometheus-rules.yaml
│           └── grafana-dashboard.yaml
├── scripts/
├── docs/
│   ├── Inference_design.md           # This document
│   ├── Local_environment.md          # macOS / krunkit setup
│   ├── Infrastructure_implementation.md
│   └── ...
└── requirements.txt
```

Production workflow: CI/CD loads config (e.g. `config/production.yaml`) and runs `helm upgrade --install neural-gate` with the appropriate values for the target cloud (GKE or EKS). See [CICD_proposed.md](CICD_proposed.md) for the deployment and parameter-update plan.
