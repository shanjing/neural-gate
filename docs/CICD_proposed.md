# CI/CD Plan: Model Deployment and Parameter Updates

**Status:** Design in progress.

This document describes the proposed CI/CD approach for deploying neural-gate (models and key parameters) in a repeatable, Git-driven way.

---

## 1. Source of truth for models and parameters

- **Recommended:** Git as source of truth.
  - **What:** One or more config files that define the list of models and their parameters (e.g. a `config/` or `deploy/` tree in the neural-gate repo, or a separate inference-config repo).
  - **Contents (per env or per cluster):**
    - Model list: `name`, `ggufFile` (or object path in cloud).
    - Per-model (optional): `contextSize`, `cpu.request`/`limit`, `memory.request`/`limit`, engine overrides.
    - Global defaults: `engine.contextSize`, `engine.image`, `volumes.modelsPath`, etc.
  - **Format:** YAML (or JSON) that either **is** the Helm values for the chart, or is **transformed** in CI into a values file or `--set` for `helm upgrade`.

- **Alternatives:** Parameters in a secret manager (e.g. GCP Secret Manager, AWS SSM) or a config server that CI fetches; CI still produces the final values and runs Helm. Git-only is simpler to audit and roll back.

---

## 2. Parameters to manage via CI/CD

- **Model identity:** `name`, `ggufFile` (or cloud path for GKE).
- **Per-model:** `contextSize`, `cpu.request`/`cpu.limit`, `memory.request`/`memory.limit`; optionally per-model `extraArgs` or image overrides.
- **Global / engine:** `engine.contextSize` (default when per-model is unset), `engine.image`, `engine.extraArgs`, `volumes.modelsPath`, `volumes.type` (hostPath vs PVC).
- **Environment-specific:** `gateway.hostname`, `gateway.className`, `devicePlugin.enabled`, namespace, env-specific overrides.

All of these should live in the config/values that CI consumes so that “update context size” or “add a model” is a config change plus merge, not a manual `setup.sh` run.

---

## 3. Deployment flow (high level)

1. **Trigger**
   - On merge to `main` (or a dedicated `deploy` branch), or on tag (e.g. `deploy/inference-v1.2.0`).
   - Optionally: scheduled (e.g. nightly) or manual “Deploy” workflow.

2. **CI steps (conceptual)**
   - Checkout repo (and config repo if split).
   - **Authenticate** to the cluster (e.g. GKE workload identity, OIDC, or kubeconfig from secret).
   - **Resolve config:** Load the model list and parameters for the target env (e.g. `config/production.yaml` or `config/overlays/gke/values.yaml`).
   - **Optional:** Fetch secrets (registry, object storage) from a secret manager; do not store them in Git.
   - **Helm:** Run `helm upgrade --install neural-gate ./k8s/neural-gate/ -f <generated-or-static-values> --namespace inference ...` (with `--wait` and optionally `--atomic`). The values file (or `--set`) must include the full `models[]` and all key parameters (including per-model `contextSize` when implemented).

3. **Result**
   - Chart is applied; KServe creates/updates InferenceServices. New models appear; removed models are removed; changed parameters (e.g. context size, resources) roll out with the next rollout.

---

## 4. Updating key parameters (e.g. context size)

- **Per-model context size (when implemented):** Edit the model list in the config (e.g. set `contextSize: 8192` for one model). Merge to the branch that triggers deployment. CI runs and performs `helm upgrade` with the new values; only the affected model’s InferenceService gets the new `--ctx-size` and rolls out.
- **Global default:** Same idea: change `engine.contextSize` in the values/config used by CI; merge; CI deploys; all models that don’t override get the new default.
- No manual `helm upgrade` or `setup.sh` for parameter updates—everything goes through “config change → CI → Helm”.

---

## 5. Model lifecycle in CI/CD

- **Add model:** Add an entry to `models[]` in the config (name, ggufFile, optional contextSize/resources). Ensure the GGUF is available where the cluster expects it (e.g. host path for local, object storage + init or PVC for GKE). Merge; CI deploys; new InferenceService is created.
- **Remove model:** Remove the entry from `models[]`; merge; CI deploys; Helm removes the corresponding InferenceService (and related resources if fully templated).
- **Update model (same name, new file or version):** Change `ggufFile` (or object path) and/or parameters; merge; CI deploys; existing InferenceService is updated and pods roll.

---

## 6. Environments and promotion

- **Environments:** e.g. `staging`, `production`, or `local` (minikube). Each has its own values file or overlay (e.g. `config/staging.yaml`, `config/production.yaml`).
- **Promotion:** Option A: same branch, different values per env (CI runs per env using that env’s values). Option B: promote config from staging to prod (e.g. copy or merge config, then run prod pipeline). Option C: tag-based (e.g. tag `deploy/prod-1.0` triggers prod with a specific config version).
- **Local / dev:** Can remain manual (`setup.sh` + port-forward) or use the same chart with a “local” values file and a lightweight CI that deploys to a dev cluster.

---

## 7. Security and hygiene

- **Secrets:** No raw secrets in Git. Use CI secrets or a secret manager; inject at deploy time (e.g. registry pull secret, GCS/S3 credentials for model weights).
- **Kubeconfig / cluster access:** Prefer short-lived credentials (OIDC, workload identity); avoid long-lived kubeconfig in repo.
- **Readiness:** CI should `--wait` for Helm and optionally run a quick smoke test (e.g. hit `/v1/models` or one completion) after deploy; fail the pipeline if the stack is not healthy.

---

## 8. Summary

| Concern | Plan |
|--------|------|
| **Per-model context size** | Add optional `contextSize` to each `models[]` entry; template uses it with fallback to `engine.contextSize` then default. |
| **Where parameters live** | Git (config/values); optionally plus secret manager for secrets only. |
| **What CI does** | On merge/tag: load config for env → run `helm upgrade --install` with full values (models + all key parameters). |
| **Changing parameters** | Edit config/values and merge; CI runs and applies the change. |
| **Adding/removing models** | Add/remove entries in `models[]` in config; ensure weights exist for add; merge and let CI deploy. |
| **Environments** | One values/config file (or overlay) per env; CI selects by branch or trigger. |

---

*Last updated: design in progress.*
