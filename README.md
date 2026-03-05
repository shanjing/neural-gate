# neural-gate

Kubernetes-native Inference-as-a-Service gateway: one entry point for agentic apps (Draft, MarginCall, sudoroot) with a unified OpenAI-compatible API across Apple Silicon and NVIDIA cloud.

## Core components

- **KServe** — Model lifecycle via `InferenceService` CRDs; Standard (RawDeployment) mode, no Knative.
- **Gateway API + Envoy Gateway** — Host-based routing to model predictors; one Gateway, HTTPRoutes per model.
- **Helm chart** (`k8s/neural-gate/`) — Single chart for namespace, device-plugin, InferenceServices, Gateway, HTTPRoutes, monitoring rules; values override for local vs GKE/EKS.
- **MetalLB** (local) — LoadBalancer IP for the Envoy proxy; on Mac/minikube, use `kubectl port-forward` to reach models from the host.
- **Observability** — Prometheus alerting rules and a Grafana dashboard ConfigMap (install Prometheus/Grafana separately to view).

## Key features

- **Hardware-aware scheduling** — NFD-style overlays; Apple Metal (krunkit/virtio-gpu) or NVIDIA CUDA; generic-device-plugin exposes `squat.ai/dri` for local GPU.
- **Unified OpenAI API** — `v1/chat/completions`, `v1/models`, `v1/embeddings`; same contract for all consumers.
- **Disaggregated serving** — Designed for split prefill/decode and lower TTFT (llm-d EPP optional).
- **Observability** — Prometheus rules for P99 latency, KV cache utilization, token throughput; Grafana dashboard for inference metrics.
- **Intelligent routing** — Per-model hostnames and Gateway routes; optional llm-d for cache-aware routing.

## Quick start (macOS)

1. Configure models dir, install CLI tools, download models: `./scripts/setup.sh` (options 1–3).
2. Start cluster and KServe stack: option 4.
3. Deploy models: option 5 (Helm install with selected GGUFs).
4. Reach predictors from the host: port-forward, e.g. `kubectl port-forward -n inference svc/qwen3-1-7b-predictor 8081:80`, then `http://127.0.0.1:8081`.

## Documentation

- [Inference design](docs/Inference_design.md) — Engines, GPU passthrough (krunkit), memory budgets, overlays.
- [Infrastructure design](docs/Infrastructure_design.md) — Kubernetes layout, Helm chart, KServe, Gateway API, deployment workflow.
- [macOS runbook](docs/mac_runbook.md) — Installation, benchmark, smoke-test steps.
