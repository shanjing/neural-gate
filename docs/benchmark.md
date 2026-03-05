# Benchmark: neural-gate vs Ollama

This document describes the **competition benchmark** that compares neural-gate (Kubernetes-served inference via port-forward) and Ollama on the same models and prompt. It also records and explains a sample result set.

## What the benchmark does

The script `scripts/competitions.sh` runs the **same chat-completion request** against two backends:

1. **neural-gate** — KServe predictor pods (llama-server / llama.cpp in-cluster) reached via `kubectl port-forward` to the predictor Service.
2. **Ollama** — Local Ollama server (`ollama serve`) using the same model names (e.g. `qwen3:1.7b`, `qwen3:8b`).

For each model (Qwen3 1.7B and Qwen3 8B), it sends a fixed prompt with a fixed `max_tokens`, runs multiple requests (default 3), and reports:

- **Avg time** — Mean end-to-end latency per request (seconds).
- **Tok/req** — Mean completion tokens per request (capped by `max_tokens`).
- **Tok/s** — Throughput: completion tokens per second (tokens ÷ time).

Same prompt, same token limit, and same models on both sides make the comparison meaningful for relative performance.

### Setup required

- **neural-gate:** Cluster running with at least one predictor per model; port-forwards to the predictor Services, e.g.:
  - `kubectl port-forward -n inference svc/qwen3-1-7b-predictor 8081:80`
  - `kubectl port-forward -n inference svc/qwen3-8b-predictor 8082:80`
- **Ollama:** Server running and models pulled: `ollama pull qwen3:1.7b`, `ollama pull qwen3:8b`

Default endpoints: neural-gate 1.7B at `http://127.0.0.1:8081`, 8B at `http://127.0.0.1:8082`; Ollama at `http://localhost:11434`.

---

## Sample results

Run: `./scripts/competitions.sh` (defaults: prompt *"Say hello in one word."*, `max_tokens: 64`, 3 runs per backend per model).

### Output

```
=== neural-gate vs Ollama (Qwen3 1.7B & 8B) ===
Prompt: "Say hello in one word." | max_tokens: 64 | runs: 3

--- Qwen3 1.7B ---
  neural-gate (port-forward): 0.83s avg, 64 tok/req → 77.1 tok/s
  Ollama: 1.48s avg, 64 tok/req → 43.2 tok/s

--- Qwen3 8B ---
  neural-gate (port-forward): 2.68s avg, 64 tok/req → 23.9 tok/s
  Ollama: 5.54s avg, 64 tok/req → 11.6 tok/s

--- Summary (avg time, tok/req, tok/s) ---
Model        neural-gate                  Ollama
------       ---------------------------- ----------------------------
Qwen3 1.7B   0.83s, 64 tok → 77.1 tok/s  1.48s, 64 tok → 43.2 tok/s
Qwen3 8B     2.68s, 64 tok → 23.9 tok/s  5.54s, 64 tok → 11.6 tok/s

Port-forwards: kubectl port-forward -n inference svc/qwen3-1-7b-predictor 8081:80 (and 8082 for 8B).
```

---

## Explanation of the results

- **Same workload:** Each request asks for up to 64 completion tokens with the same prompt. Both backends hit the 64-token cap, so tok/req is 64 for every cell. Differences show up in **time** and thus **tok/s**.

- **neural-gate is faster in this run:** For both models, neural-gate (llama-server in K8s) had lower average latency and higher tok/s:
  - **Qwen3 1.7B:** 0.83s vs 1.48s → **~77 tok/s vs ~43 tok/s** (neural-gate ~1.8× higher throughput).
  - **Qwen3 8B:** 2.68s vs 5.54s → **~24 tok/s vs ~12 tok/s** (neural-gate ~2× higher throughput).

- **Why the gap can occur:**  
  - **Engine and defaults:** neural-gate uses **llama-server** (llama.cpp server) with fixed flags (e.g. `-ngl 999`, `--ctx-size 4096`). Ollama uses its own runtime and defaults (context, batching, layers on GPU), which can differ.  
  - **Environment:** neural-gate runs inside the krunkit VM with virtio-gpu (Vulkan); Ollama runs natively on the host with Metal. In this setup, the llama-server configuration in-cluster happened to yield better single-request throughput.  
  - **Quantization / model file:** If both use the same GGUF (e.g. Q4_K_M), the comparison is like-for-like; different quants or model files would affect the numbers.

- **What this does *not* measure:**  
  - Concurrency or batch throughput.  
  - Time to first token (TTFT).  
  - Other prompts or longer generations.  
  So the benchmark is a **single-style, short-completion comparison** between the two stacks on the same hardware (Mac Mini).

---

## Summary table (from run above)

| Model       | neural-gate (port-forward)     | Ollama                         |
|------------|---------------------------------|--------------------------------|
| Qwen3 1.7B | 0.83s, 64 tok → **77.1 tok/s**  | 1.48s, 64 tok → 43.2 tok/s     |
| Qwen3 8B   | 2.68s, 64 tok → **23.9 tok/s**  | 5.54s, 64 tok → 11.6 tok/s     |

In this sample, neural-gate’s llama-server in-cluster gave roughly **1.8–2×** higher tok/s than Ollama for the same models and prompt. Re-run with `RUNS=5` or different `PROMPT`/`MAX_TOKENS` to collect more data; see `scripts/competitions.sh` for env vars.
