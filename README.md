# neural-gate

neural-gate is a high-performance, Kubernetes-native Inference-as-a-Service gateway. It acts as the central entry point for all agentic applications (like Draft, MarginCall, and sudoroot), providing a unified OpenAI-compatible API across heterogeneous hardware—from NVIDIA-powered cloud clusters to Apple Silicon Mac.

## Key Features

- **Hardware-Aware Scheduling** — Leverages Node Feature Discovery (NFD) and specialized overlays to optimize for Apple Metal (via krunkit) or NVIDIA CUDA backends.
- **Unified OpenAI API** — A single endpoint for all consumers, supporting `v1/chat/completions`, `v1/models`, and `v1/embeddings`.
- **Disaggregated Serving** — Engineered to support split prefill/decoding phases to maximize throughput and minimize time-to-first-token (TTFT).
- **Advanced Observability** — Built-in Prometheus metrics for monitoring KV cache usage, request concurrency, and token throughput.
- **Intelligent Routing** — Dynamically routes requests based on model availability, priority, and resource constraints.

