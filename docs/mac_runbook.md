# Mac Runbook

Operational runbook for setting up and validating neural-gate on an Apple Silicon Mac (M4 Pro / M4 Max, 64 GB unified memory). Covers the full-stack krunkit path (GPU-accelerated K8s pods) and the native fallback path (mlx-lm on host).

---

## Installation

### Prerequisites

| Requirement | Minimum version | Check |
| --- | --- | --- |
| macOS | 14.0+ (Sonoma) | `sw_vers` |
| Apple Silicon | M1 or later | `uname -m` → `arm64` |
| Homebrew | latest | `brew --version` |
| minikube | 1.37.0+ | `minikube version` |
| kubectl | 1.29+ | `kubectl version --client` |
| Python 3 | 3.11+ | `python3 --version` |

### Step 1 — Install krunkit and vmnet-helper

krunkit provides the minikube driver that exposes the Mac GPU (via virtio-gpu / Vulkan) inside the Linux VM. vmnet-helper gives the VM a routable network interface.

```bash
brew tap slp/krunkit && brew install krunkit
curl -fsSL https://github.com/minikube-machine/vmnet-helper/releases/latest/download/install.sh | bash
```

### Step 2 — Download model weights

Model weights live on the external volume at `/Volumes/External/neural-gate-models/`. A symlink at `~/.models` points there for convenience. The setup script creates the symlink automatically.

```
/Volumes/External/neural-gate-models/   ← actual storage (external NVMe)
        ↑
~/.models (symlink)                     ← used by scripts and docs
```

```bash
# Download models to the external volume
# Example: Qwen2.5 8B Q4_K_M (primary)
huggingface-cli download Qwen/Qwen2.5-8B-Instruct-GGUF \
  qwen2.5-8b-instruct-q4_k_m.gguf --local-dir /Volumes/External/neural-gate-models/

# Optional: 4B (canary) and 0.5B (router/prefill)
huggingface-cli download Qwen/Qwen2.5-4B-Instruct-GGUF \
  qwen2.5-4b-instruct-q4_k_m.gguf --local-dir /Volumes/External/neural-gate-models/
huggingface-cli download Qwen/Qwen2.5-0.5B-Instruct-GGUF \
  qwen2.5-0.5b-instruct-q4_k_m.gguf --local-dir /Volumes/External/neural-gate-models/
```

### Step 3 — Start the krunkit cluster

```bash
minikube start \
  --driver=krunkit \
  --mount-string /Volumes/External/neural-gate-models:/mnt/models \
  --profile=inference
```

Verify the GPU is visible inside the VM:

```bash
minikube ssh --profile=inference -- ls /dev/dri
# Expected: card0  renderD128
```

### Step 4 — Deploy the stack

Run the automated setup script, or use Make:

```bash
# Option A: setup script (installs everything from scratch)
bash scripts/setup.sh

# Option B: Make target (assumes krunkit and vmnet-helper are installed)
make local-up
```

This deploys:
- `inference` namespace
- generic-device-plugin DaemonSet (exposes `/dev/dri` as `squat.ai/dri`)
- KServe InferenceService CRDs (qwen-8b, qwen-4b, qwen-05b)
- llm-d scheduler (Envoy + EPP)
- Gateway API routes
- Prometheus rules and Grafana dashboard

### Step 5 — Verify pods are running

```bash
kubectl get pods -n inference
kubectl get inferenceservices -n inference
```

All model pods should show `Running` with `1/1` ready. Each InferenceService should report a URL.

### Alternative: Native fallback path

If you don't need full-stack K8s simulation, run mlx-lm directly on the host:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Start the server (binds to 0.0.0.0:8000)
bash native/start-inference.sh

# Or install as a launchd service for auto-start:
cp native/com.inference.mlx-server.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.inference.mlx-server.plist
```

Then deploy the native overlay so cluster traffic routes to the host:

```bash
make local-native
```

### Teardown

```bash
make clean
# Equivalent to: minikube delete --profile=inference
```

---

## Benchmark

Measures inference throughput under concurrent load. Run after the stack is deployed and all model pods are healthy.

### What is benchmarked

| Metric | Description |
| --- | --- |
| **Tokens per second (tok/s)** | Decode throughput — completion tokens generated per wall-clock second per request |
| **Latency per request** | End-to-end time from request sent to full response received |
| **Concurrent throughput** | Aggregate behavior under parallel requests (default: 4 concurrent) |

The benchmark sends 20 chat completion requests (configurable) with a fixed prompt and 256 max output tokens. Requests are batched by concurrency level — a new batch starts after the previous one finishes. Each request reports its latency, token count, and per-request tok/s.

### Running the benchmark

```bash
# Default: qwen-8b, 4 concurrent, 20 requests
make benchmark

# Custom parameters
ENDPOINT=http://inference.local MODEL=qwen-4b CONCURRENCY=8 REQUESTS=50 bash scripts/benchmark.sh
```

### Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `ENDPOINT` | `http://inference.local` | Inference gateway URL |
| `MODEL` | `qwen-8b` | Model name to target |
| `CONCURRENCY` | `4` | Number of parallel requests per batch |
| `REQUESTS` | `20` | Total number of requests to send |

### Example output

```
=== Throughput Benchmark ===
Model: qwen-8b | Concurrency: 4 | Requests: 20

  2.34s | 187 tokens | 79.9 tok/s
  2.51s | 201 tokens | 80.1 tok/s
  3.12s | 256 tokens | 82.1 tok/s
  ...

=== Benchmark complete ===
```

### Expected ranges (Mac Mini M4 Pro, krunkit path)

| Model | Quantization | Expected tok/s (single request) |
| --- | --- | --- |
| qwen-8b | Q4_K_M | ~25–40 |
| qwen-4b | Q4_K_M | ~40–60 |
| qwen-05b | Q4_K_M | ~60–100 |

Native path (mlx-lm with Metal) will be faster since it avoids the Vulkan translation layer.

---

## Smoke Test

Quick validation that the inference gateway is up, models are loaded, and completions work end-to-end. Run after deployment or after any configuration change.

### What is tested

| Check | Endpoint | Pass criteria |
| --- | --- | --- |
| **Model listing** | `GET /v1/models` | Returns HTTP 200 with a JSON array containing at least one model |
| **Chat completion** | `POST /v1/chat/completions` | Returns HTTP 200 with a valid response containing generated tokens |

The smoke test validates the full request path: client → Gateway → llm-d scheduler → engine pod → model inference → response. A passing result confirms that the Gateway is routing, the scheduler is dispatching, the engine is loaded, and the model is generating tokens.

### Running the smoke test

```bash
# Default endpoint: http://inference.local
make smoke-test

# Custom endpoint
ENDPOINT=http://localhost:8000 bash scripts/smoke-test.sh
```

### Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `ENDPOINT` | `http://inference.local` | Inference gateway URL |

### Example output

```
=== Smoke Test ===
--- Health check ---
{
    "object": "list",
    "data": [
        {
            "id": "qwen-8b",
            "object": "model",
            ...
        }
    ]
}

--- Chat completion ---
{
    "id": "chatcmpl-abc123",
    "object": "chat.completion",
    "choices": [
        {
            "message": {
                "role": "assistant",
                "content": "Hello! How can I help you today?"
            }
        }
    ],
    ...
}

=== All checks passed ===
```

### Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `curl: (7) Failed to connect` | Gateway not running or DNS not configured | Check `kubectl get gateway -n inference` and `/etc/hosts` for `inference.local` |
| `curl: (52) Empty reply` | Engine pod is starting / model still loading | Wait for pod readiness: `kubectl wait --for=condition=ready pod -l app=qwen-8b -n inference --timeout=120s` |
| HTTP 503 | KServe has scaled the model to zero | Send a request — KServe will scale up automatically (cold start ~30s) |
| JSON parse error | Response is not valid JSON — engine may be returning an error page | Check engine logs: `kubectl logs -l app=qwen-8b -n inference` |
