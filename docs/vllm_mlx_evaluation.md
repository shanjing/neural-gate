# vLLM-MLX evaluation

This document describes what [vllm-mlx](https://github.com/waybarrios/vllm-mlx) is and why it does **not** address the goal of simulating cloud NVIDIA GPU provisioning on Kubernetes in a macOS environment.

---

## What vLLM-MLX is

- **Purpose:** An OpenAI- and Anthropic-compatible inference server for **Apple Silicon** using MLX (Metal). It supports LLMs, VLMs, embeddings, TTS/STT, reasoning extraction, MCP tool calling, and continuous batching.
- **Runtime:** Python 3.10+, FastAPI/uvicorn. Run via CLI `vllm-mlx serve <model> [options]` or `python -m vllm_mlx.server --model <model> [options]`. Default: `--host 0.0.0.0`, `--port 8000`.
- **API:** OpenAI-compatible (`/v1/chat/completions`, `/v1/models`, `/health`, etc.).
- **Model format:** HuggingFace model IDs or local paths; uses **MLX / mlx-lm** (e.g. `mlx-community/Qwen3-8B-4bit`), not GGUF.
- **Platform:** **macOS / Apple Silicon only.** Depends on `mlx`, `mlx-lm`, `mlx-vlm`; classifiers: `Operating System :: MacOS`. No Linux support. No Dockerfile in the repo.

In short, vllm-mlx is a **macOS-level LLM provider**—similar in role to Ollama. It runs on the **host** (your Mac), uses Metal directly, and exposes an HTTP API. It is not an Inference Engine for Kubernetes and does **not** run inside Kubernetes or inside cluster VMs.

---

## Why it does not solve simulating cloud NVIDIA GPU provisioning on Kubernetes (macOS)

The project’s local run aims to **simulate production** (GKE/EKS) where:

- Pods run **inside** the cluster (Linux nodes).
- GPU capacity is exposed as a **Kubernetes resource** (e.g. `nvidia.com/gpu`).
- A **device plugin** and node resources let the scheduler place workloads on GPU nodes and enforce limits.

On macOS, that simulation is done with **minikube (krunkit)**:

- Cluster nodes are **Linux VMs** with **Vulkan** (virtio-gpu), not Metal.
- A **device plugin** (e.g. generic-device-plugin) exposes something like `squat.ai/dri` so pods can “request 1 GPU” and get scheduled.
- **llama-server** (or similar) runs **inside** those pods and uses the VM’s GPU path. That exercises **VM-level** scheduling, resource accounting, and placement—the local stand-in for production’s `nvidia.com/gpu` and NVIDIA device plugin.

vLLM-mlx **does not** participate in that picture:

1. **It runs on the host, not in the cluster.** It is a process on the Mac, like Ollama. It never runs inside a pod or a cluster node, so it does not use or test Kubernetes GPU scheduling, device plugins, or node capacity.

2. **It is not a VM-level GPU provisioning utility.** It does not simulate or provision NVIDIA GPUs. It does not integrate with the cluster’s resource model. It simply serves inference over HTTP from the host.

3. **It cannot run inside the current cluster.** The cluster is Linux (krunkit); vllm-mlx requires macOS and Metal. So there is no “vllm-mlx in a pod” option that would exercise in-cluster GPU provisioning.

**Conclusion:** For simulating cloud NVIDIA-style GPU provisioning on Kubernetes in a macOS environment, you need the **in-cluster** path: Linux pods, a device plugin (e.g. `squat.ai/dri`), and an inference engine that runs inside the cluster (e.g. llama-server with Vulkan). vLLM-mlx is a host-side LLM provider only; it does not replace or simulate that VM-level GPU provisioning.
