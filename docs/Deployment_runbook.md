# Deployment

This document describes how to deploy neural-gate and how to set each model’s parameters (including context size, CPU, and memory).

---

## Deploying models

You can deploy models in two ways:

1. **Interactive (macOS):** Use `scripts/setup.sh`, option 5. The script selects one model at a time and applies the chart with default parameters (see [Parameter defaults](#parameter-defaults) below).
2. **Values file or Helm:** Edit the appropriate `values*.yaml` and/or pass `--set` so each model has the parameters you want. Then run `helm upgrade --install` (or use setup.sh after configuring values).

The following sections explain **which file to edit**, **per-model fields**, and **global engine defaults**.

---

### Which values file to use

| Environment        | File                  | Use when |
| ------------------ | --------------------- | -------- |
| **Local (minikube/krunkit)** | `k8s/neural-gate/values.yaml` | macOS, llama-server, GGUF, `squat.ai/dri` |
| **GKE**            | `k8s/neural-gate/values-gke.yaml` (override) | Production GKE, vLLM, `nvidia.com/gpu` |
| **EKS**            | `k8s/neural-gate/values-eks.yaml` (override) | Production EKS, vLLM, `nvidia.com/gpu` |

- **Local:** Edit `values.yaml` only, or use setup.sh (which uses `values.yaml` and passes models via `--set`).
- **GKE/EKS:** Use `-f values.yaml -f values-gke.yaml` (or `values-eks.yaml`) so base defaults plus environment overrides apply. Model list and per-model settings can live in the overlay or in a custom file.

---

### Helm operations
These commands are available in setup.sh option 5.

**Plan (diff + change list)** — install the [helm-diff](https://github.com/databus23/helm-diff) plugin, then run a diff and the change list helper:

```bash
helm plugin install https://github.com/databus23/helm-diff --verify=false   # once
helm diff upgrade neural-gate ./k8s/neural-gate --namespace inference -f k8s/neural-gate/values.yaml
python3 scripts/helm_plan.py neural-gate ./k8s/neural-gate inference -f k8s/neural-gate/values.yaml
```

The script requires PyYAML (`pip install pyyaml`). It outputs JSON with `changes` (create/replace/remove per resource) and `has_changes`.

Preview rendered manifests (dry-run) without applying:

```bash
helm template neural-gate ./k8s/neural-gate -f k8s/neural-gate/values.yaml
```

With an overlay (e.g. GKE):

```bash
helm template neural-gate ./k8s/neural-gate -f k8s/neural-gate/values.yaml -f k8s/neural-gate/values-gke.yaml
```

Deploy or upgrade the release (see [Steps to set each model's parameters](#steps-to-set-each-models-parameters) for full examples):

```bash
helm upgrade --install neural-gate ./k8s/neural-gate --namespace inference --create-namespace -f k8s/neural-gate/values.yaml
```

---

### Per-model parameters (each entry under `models[]`)

Each item in the `models` array in your values file (or each `models[N]` set via `--set`) defines one model and its parameters. Below, **Field** is the YAML key (and the `--set` path when using Helm).

| Field | Type | Meaning | Default (if omitted) |
| ----- | ---- | ------- | --------------------- |
| **`name`** | string | Logical name for the model. Used as the InferenceService name (and subdomain, e.g. `{name}.inference.local`). Use lowercase, hyphens; no spaces. | *(required)* |
| **`ggufFile`** | string | GGUF filename in the models directory (e.g. `qwen3-8b.gguf`). The full path in the pod is `{volumes.modelsPath}/{ggufFile}`. | *(required for local)* |
| **`contextSize`** | integer | Maximum context size in tokens (prompt + completion). Larger values allow longer prompts but use more memory. Common: 4096, 8192, 16384, 32768. | `engine.contextSize` (typically 4096) |
| **`cpu.request`** | string | CPU requested for the predictor pod (Kubernetes resource request). | `"2"` |
| **`cpu.limit`** | string | CPU limit for the predictor pod. | `"4"` |
| **`memory.request`** | string | Memory requested (e.g. `4Gi`, `8Gi`). | `4Gi` |
| **`memory.limit`** | string | Memory limit for the predictor pod. | `8Gi` |

**Example (in `values.yaml`):**

```yaml
models:
  - name: qwen3-8b
    ggufFile: qwen3-8b.gguf
    contextSize: 8192
    cpu:
      request: "2"
      limit: "4"
    memory:
      request: 4Gi
      limit: 8Gi
  - name: qwen3-1-7b
    ggufFile: qwen3-1.7b.gguf
    contextSize: 4096
    # cpu/memory omitted — use defaults from engine
```

**Example (Helm `--set` for one model):**

```bash
helm upgrade --install neural-gate ./k8s/neural-gate \
  --namespace inference \
  --set "models[0].name=qwen3-8b" \
  --set "models[0].ggufFile=qwen3-8b.gguf" \
  --set "models[0].contextSize=8192" \
  --set "models[0].cpu.request=2" \
  --set "models[0].cpu.limit=4" \
  --set "models[0].memory.request=4Gi" \
  --set "models[0].memory.limit=8Gi"
```

---

### Global engine defaults (apply to all models unless overridden)

These live under `engine` in the same values file. Per-model `contextSize` overrides `engine.contextSize` for that model only.

| Field | Type | Meaning | Typical default |
| ----- | ---- | ------- | ----------------- |
| **`engine.contextSize`** | integer | Default maximum context size (tokens) for models that do not set `contextSize`. | `4096` |
| **`engine.image`** | string | Container image for the inference engine (e.g. `quay.io/ramalama/ramalama:latest` for llama-server, or vLLM image on GKE/EKS). | Chart default |
| **`engine.command`** | array | Command for the container. | Chart default |
| **`engine.extraArgs`** | array | Extra CLI args (e.g. `[-ngl, "999"]` for GPU layers). | Chart default |
| **`engine.gpu.resource`** | string | Kubernetes GPU resource name (e.g. `squat.ai/dri` locally, `nvidia.com/gpu` on GKE/EKS). | Chart default |
| **`engine.gpu.count`** | integer | Number of GPUs to request per model pod. | `1` |

Editing `engine.contextSize` in `values.yaml` changes the default for every model that does not specify its own `contextSize`.

---

### Steps to set each model’s parameters

1. **Choose the values file**  
   - Local: `k8s/neural-gate/values.yaml`  
   - GKE: base `values.yaml` + `values-gke.yaml` (and optionally a custom file with `models`).  
   - EKS: base + `values-eks.yaml` (and optionally a custom file with `models`).

2. **Define or edit the `models` list**  
   - In the chosen file, set the `models` array (or merge it via an overlay).  
   - For each model, set at least `name` and `ggufFile` (for local GGUF).  
   - Set **`contextSize`** to the desired max tokens (e.g. 8192 or 16384); if omitted, `engine.contextSize` is used.  
   - Optionally set **`cpu.request`**, **`cpu.limit`**, **`memory.request`**, **`memory.limit`** per model.

3. **Optionally adjust global defaults**  
   - In the same file, under **`engine`**, set **`contextSize`** to the default you want for any model that doesn’t specify it.

4. **Deploy**  
   - **Local:** Run `scripts/setup.sh`, option 5 (it will use the chart; you can pre-fill `models` in `values.yaml` or rely on setup.sh’s `--set` for the model list).  
   - **Helm:** Run `helm upgrade --install neural-gate ./k8s/neural-gate -f values.yaml -f values-gke.yaml ...` (or with your custom values file) so the edited `models` and `engine` values are applied.

5. **Verify**  
   - Check InferenceServices: `kubectl get inferenceservice -n inference`.  
   - In setup.sh’s “Current state”, each model’s **context size** is shown next to the model name.

---

### Parameter defaults (quick reference)

| Parameter | Where | Default |
| --------- | ----- | ------- |
| Context size (per model) | `models[N].contextSize` or `engine.contextSize` | 4096 |
| CPU request | `models[N].cpu.request` | "2" |
| CPU limit | `models[N].cpu.limit` | "4" |
| Memory request | `models[N].memory.request` | 4Gi |
| Memory limit | `models[N].memory.limit` | 8Gi |

Setting **contextSize** per model (in `models[N].contextSize`) is the main way to control prompt+completion length; use the values file (or `--set`) as shown above.

---

### Troubleshooting: HTTPRoute conflicts

If `helm upgrade` fails with **conflicts with "manager"** on `HTTPRoute` (e.g. `.spec.hostnames`, `.spec.parentRefs`, `.spec.rules`), the Gateway controller (e.g. Envoy Gateway) is managing the same HTTPRoutes as Helm.

- **setup.sh (option 5)**: Before apply, the script deletes existing HTTPRoutes labeled with the release so Helm can recreate and own them. If the conflict persists, set `gateway.createHttpRoutes: false` in your values and ensure routes are created by your Gateway controller or option 6.
- **Helm / values**: Set `gateway.createHttpRoutes: false` so the chart does not create HTTPRoutes; you must create or reconcile routes elsewhere.
