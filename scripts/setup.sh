#!/usr/bin/env bash
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✔${RESET} $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }
fail() { echo -e "  ${RED}✘${RESET} $1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
MODELS_LINK="$HOME/.models"


# Model catalog: repo|filename|display_name|size
# Curated SLMs suitable for Apple Silicon / GGUF / Q4_K_M quantization
MODEL_CATALOG=(
  "Qwen/Qwen3-8B-GGUF|Qwen3-8B-Q4_K_M.gguf|Qwen3 8B (Q4)|~5 GB"
  "Qwen/Qwen3-4B-GGUF|Qwen3-4B-Q4_K_M.gguf|Qwen3 4B (Q4)|~2.5 GB"
  "bartowski/Qwen_Qwen3-1.7B-GGUF|Qwen_Qwen3-1.7B-Q4_K_M.gguf|Qwen3 1.7B (Q4)|~1.2 GB"
  "bartowski/Qwen_Qwen3-0.6B-GGUF|Qwen_Qwen3-0.6B-Q4_K_M.gguf|Qwen3 0.6B (Q4)|~0.5 GB"
  "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF|qwen2.5-coder-7b-instruct-q4_k_m.gguf|Qwen2.5 Coder 7B (Q4)|~4.5 GB"
  "microsoft/Phi-4-mini-instruct-gguf|Phi-4-mini-instruct-Q4_K_M.gguf|Phi-4 Mini 3.8B (Q4)|~2.4 GB"
  "bartowski/gemma-3-4b-it-GGUF|gemma-3-4b-it-Q4_K_M.gguf|Gemma 3 4B IT (Q4)|~2.8 GB"
  "bartowski/Llama-3.2-3B-Instruct-GGUF|Llama-3.2-3B-Instruct-Q4_K_M.gguf|Llama 3.2 3B Instruct (Q4)|~2 GB"
)

# ── Current state ────────────────────────────────────────────────────────────

show_current_state() {
  echo -e "${DIM}--- Current state ---${RESET}"

  # Venv
  if [ -d "$VENV_DIR" ] && [ -x "$VENV_DIR/bin/python" ]; then
    echo -e "  Venv      : ${GREEN}ready${RESET} ($VENV_DIR)"
  else
    echo -e "  Venv      : ${RED}not created${RESET}"
  fi

  # Models directory
  if [ -L "$MODELS_LINK" ]; then
    local target gguf_count
    target=$(readlink "$MODELS_LINK")
    gguf_count=$(find -L "$MODELS_LINK" -maxdepth 1 -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  Models dir: ${GREEN}$target${RESET} ($gguf_count GGUF file(s))"
    if [ "$gguf_count" -gt 0 ]; then
      while IFS= read -r f; do
        echo -e "              ${DIM}$(basename "$f")${RESET}"
      done < <(find -L "$MODELS_LINK" -maxdepth 1 -name '*.gguf' 2>/dev/null | sort)
    else
      echo -e "              ${DIM}None${RESET}"
    fi
  elif [ -d "$MODELS_LINK" ]; then
    echo -e "  Models dir: ${YELLOW}$MODELS_LINK is a real directory (not a symlink)${RESET}"
  else
    echo -e "  Models dir: ${RED}not configured${RESET}"
  fi

  # CLI tools (minikube, kubectl, krunkit, helm, helm-diff)
  local tools_ok=0 tools_missing=0
  for tool in minikube kubectl krunkit helm; do
    if command -v "$tool" &>/dev/null; then
      tools_ok=$((tools_ok + 1))
    else
      tools_missing=$((tools_missing + 1))
    fi
  done
  if command -v helm &>/dev/null && helm plugin list 2>/dev/null | grep -q 'diff'; then
    tools_ok=$((tools_ok + 1))
  elif command -v helm &>/dev/null; then
    tools_missing=$((tools_missing + 1))
  fi
  if [ "$tools_missing" -eq 0 ]; then
    echo -e "  CLI tools : ${GREEN}all installed${RESET} (minikube, kubectl, krunkit, helm, helm-diff)"
  else
    echo -e "  CLI tools : ${YELLOW}${tools_missing} missing${RESET} (minikube, kubectl, krunkit, helm, helm-diff)"
  fi

  # vmnet-helper
  if command -v vmnet-helper &>/dev/null || [ -f /opt/vmnet-helper/bin/vmnet-helper ]; then
    echo -e "  vmnet     : ${GREEN}installed${RESET}"
  else
    echo -e "  vmnet     : ${RED}not installed${RESET}"
  fi

  # Cluster
  if minikube status --profile=inference &>/dev/null 2>&1; then
    local node_count
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  Cluster   : ${GREEN}running${RESET} (profile: inference, $node_count node(s))"

    # KServe status
    if kubectl get crd inferenceservices.serving.kserve.io &>/dev/null 2>&1; then
      echo -e "  KServe    : ${GREEN}installed${RESET}"
    else
      echo -e "  KServe    : ${DIM}not installed (start cluster via option 4)${RESET}"
    fi

    # Helm release
    if helm status neural-gate --namespace inference &>/dev/null 2>&1; then
      local helm_rev
      helm_rev=$(helm list --namespace inference -q -f '^neural-gate$' -o json 2>/dev/null \
        | "$VENV_DIR/bin/python" -c "import sys,json;d=json.load(sys.stdin);print(d[0].get('revision','?') if d else '?')" 2>/dev/null || echo "?")
      echo -e "  Helm      : ${GREEN}neural-gate (rev $helm_rev)${RESET}"
    else
      echo -e "  Helm      : ${DIM}not deployed${RESET}"
    fi

    # Deployed models via InferenceService
    local isvc_lines
    isvc_lines=$(kubectl get inferenceservice -n inference --no-headers 2>/dev/null || true)
    if [ -n "$isvc_lines" ]; then
      local isvc_count
      isvc_count=$(echo "$isvc_lines" | wc -l | tr -d ' ')
      echo -e "  Models    : ${GREEN}$isvc_count InferenceService(s)${RESET}"
      while IFS= read -r isvc_line; do
        [ -z "$isvc_line" ] && continue
        local iname iready iage ctx_size
        iname=$(echo "$isvc_line" | awk '{print $1}')
        iready=$(echo "$isvc_line" | awk '{print $2}')
        iage=$(echo "$isvc_line" | awk '{print $NF}')
        ctx_size=$(kubectl get inferenceservice "$iname" -n inference -o json 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    args = d.get('spec', {}).get('predictor', {}).get('containers', [{}])[0].get('args', [])
    i = args.index('--ctx-size') if '--ctx-size' in args else -1
    print(args[i+1] if i >= 0 and i+1 < len(args) else '4096')
except Exception:
    print('4096')
" 2>/dev/null || echo "4096")
        if [ "$iready" = "True" ]; then
          echo -e "              ${GREEN}$iname${RESET} ($iage) context size: $ctx_size"
        else
          echo -e "              ${YELLOW}$iname${RESET} ($iage) context size: $ctx_size"
        fi
      done <<< "$isvc_lines"
    else
      echo -e "  Models    : ${DIM}none deployed${RESET}"
    fi
  else
    echo -e "  Cluster   : ${DIM}not running${RESET}"
    echo -e "  KServe    : ${DIM}—${RESET}"
    echo -e "  Helm      : ${DIM}—${RESET}"
    echo -e "  Models    : ${DIM}—${RESET}"
  fi

  # Gateway / Ingress
  local gateway_ip=""
  gateway_ip=$(kubectl get gateway inference-gateway -n inference \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
  if [ -n "$gateway_ip" ]; then
    echo -e "  Gateway   : ${GREEN}$gateway_ip${RESET} (Envoy)"
    local route_count
    route_count=$(kubectl get httproute -n inference --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$route_count" -gt 0 ]; then
      while IFS= read -r rt; do
        [ -z "$rt" ] && continue
        local rname rhost
        rname=$(echo "$rt" | awk '{print $1}')
        rhost=$(kubectl get httproute "$rname" -n inference \
          -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || echo "")
        [ -n "$rhost" ] && echo -e "              ${CYAN}http://$rhost${RESET}"
      done < <(kubectl get httproute -n inference --no-headers 2>/dev/null)
    fi
  else
    echo -e "  Gateway   : ${DIM}not configured (run option 6 after deploying)${RESET}"
  fi

  # Version — host OS, RAM, GPU count (actual count from system_profiler)
  local host_os host_ram host_gpu version_str gpu_count chip
  host_os=$(sw_vers -productVersion 2>/dev/null || echo "—")
  if [ -n "$host_os" ] && [ "$host_os" != "—" ]; then
    host_ram=$( (sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GB", $1/1024/1024/1024}') || echo "—")
    gpu_count=1
    if command -v system_profiler &>/dev/null; then
      gpu_count=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Chipset Model" 2>/dev/null || echo "0")
      [ -z "$gpu_count" ] || [ "$gpu_count" -eq 0 ] 2>/dev/null && gpu_count=1
      chip=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/^[[:space:]]*Chip:/ {print $2; exit}')
      if [ -n "$chip" ]; then
        [ "$gpu_count" -eq 1 ] && host_gpu="1 GPU ($chip)" || host_gpu="${gpu_count} GPUs ($chip)"
      else
        [ "$gpu_count" -eq 1 ] && host_gpu="1 GPU" || host_gpu="${gpu_count} GPUs"
      fi
    else
      host_gpu="1 GPU"
    fi
    [ "$host_ram" = "—" ] && version_str="🍎 macOS $host_os | — RAM | $host_gpu" || version_str="🍎 macOS $host_os | $host_ram RAM | $host_gpu"
  else
    version_str="🍎 macOS setup"
  fi
  echo -e "  Version   : ${DIM}${version_str}${RESET}"

  echo ""
}

# ── Actions: required / suggested ─────────────────────────────────────────────

show_actions() {
  local has_required=0 has_suggested=0

  echo -e "${DIM}Actions:${RESET}"

  # Models directory
  if ! [ -L "$MODELS_LINK" ]; then
    echo -e "  ${YELLOW}[required] Configure models directory in option 1.${RESET}"
    if [ -d "$MODELS_LINK" ]; then
      echo -e "  ${YELLOW}[reason]   ~/.models exists as a real directory — must be a symlink.${RESET}"
    else
      echo -e "  ${YELLOW}[reason]   ~/.models symlink does not exist. Inference pods need model weights.${RESET}"
    fi
    has_required=1
  else
    local gguf_count
    gguf_count=$(find -L "$MODELS_LINK" -maxdepth 1 -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$gguf_count" -eq 0 ]; then
      echo -e "  ${YELLOW}[required] Download at least one GGUF model in option 3 (Download models).${RESET}"
      echo -e "  ${YELLOW}[reason]   Models directory is configured but empty — smoke test and benchmark will fail.${RESET}"
      has_required=1
    fi
  fi

  # CLI tools
  local missing_tools=""
  for tool in minikube kubectl krunkit helm; do
    if ! command -v "$tool" &>/dev/null; then
      missing_tools="$missing_tools $tool"
    fi
  done
  if ! command -v vmnet-helper &>/dev/null && ! [ -f /opt/vmnet-helper/bin/vmnet-helper ]; then
    missing_tools="$missing_tools vmnet-helper"
  fi
  if [ -n "$missing_tools" ]; then
    echo -e "  ${YELLOW}[required] Install missing CLI tools in option 2:${missing_tools}.${RESET}"
    echo -e "  ${YELLOW}[reason]   Cannot start the cluster without these tools.${RESET}"
    has_required=1
  fi

  # helm-diff plugin (required for option 5 plan view)
  if command -v helm &>/dev/null && ! helm plugin list 2>/dev/null | grep -q 'diff'; then
    echo -e "  ${YELLOW}[required] Install helm-diff plugin in option 2 (Install CLI tools).${RESET}"
    echo -e "  ${YELLOW}[reason]   Option 5 (Deploy) needs helm-diff for the plan view.${RESET}"
    has_required=1
  fi

  # Cluster
  if [ -z "$missing_tools" ] && [ -L "$MODELS_LINK" ]; then
    if ! minikube status --profile=inference &>/dev/null 2>&1; then
      echo -e "  ${YELLOW}[required] Start the minikube cluster in option 4.${RESET}"
      echo -e "  ${YELLOW}[reason]   Cluster is not running. All K8s operations depend on it.${RESET}"
      has_required=1
    else
      # Check if KServe infra is installed
      if ! kubectl get crd inferenceservices.serving.kserve.io &>/dev/null 2>&1; then
        echo -e "  ${YELLOW}[required] Restart cluster via option 4 to install KServe infrastructure.${RESET}"
        echo -e "  ${YELLOW}[reason]   KServe CRDs not found — required for InferenceService deployments.${RESET}"
        has_required=1
      else
        local isvc_count
        isvc_count=$(kubectl get inferenceservice -n inference --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        if [ "$isvc_count" -eq 0 ]; then
          echo -e "  ${YELLOW}[suggested] Deploy the inference stack in option 5 — select models to serve.${RESET}"
          echo -e "  ${YELLOW}[reason]    Cluster is running but no InferenceServices deployed.${RESET}"
          has_suggested=1
        else
          # In RawDeployment mode KServe often leaves READY empty; use predictor pod status instead
          local running_predictors
          running_predictors=$(kubectl get pods -n inference -l neural-gate/role=model-server --no-headers 2>/dev/null | grep -c Running || echo "0")
          if [ "$running_predictors" -lt "$isvc_count" ]; then
            echo -e "  ${YELLOW}[waiting]   $(( isvc_count - running_predictors )) predictor(s) not yet Running. Wait or check logs.${RESET}"
            echo -e "  ${DIM}            kubectl get pods -n inference -l neural-gate/role=model-server -w${RESET}"
            has_suggested=1
          fi

          # Check if Gateway IP + /etc/hosts is configured
          local gw_ip
          gw_ip=$(kubectl get gateway inference-gateway -n inference \
            -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
          if [ -z "$gw_ip" ]; then
            echo -e "  ${YELLOW}[suggested] Configure ingress (Gateway + /etc/hosts) in option 6.${RESET}"
            echo -e "  ${YELLOW}[reason]    Models deployed but not reachable from the host yet.${RESET}"
            has_suggested=1
          else
            echo -e "  ${YELLOW}[suggested] Run smoke test (7) or benchmark (8) to verify the deployment.${RESET}"
            has_suggested=1
          fi
        fi
      fi
    fi
  fi

  if [ "$has_required" -eq 0 ] && [ "$has_suggested" -eq 0 ]; then
    echo -e "  ${YELLOW}[None] You are good to go. Run smoke test (7) or benchmark (8).${RESET}"
  fi
  echo ""
}

# ── Prerequisite checks (run once at start) ──────────────────────────────────

ensure_venv() {
  local req_file="$SCRIPT_DIR/requirements.txt"

  if [ -d "$VENV_DIR" ] && [ -x "$VENV_DIR/bin/python" ]; then
    ok "Virtual environment exists ($VENV_DIR)"
  else
    local pyexe=""
    for py in python3.12 python3.11 python3; do
      if command -v "$py" &>/dev/null; then
        pyexe="$py"
        break
      fi
    done
    if [ -z "$pyexe" ]; then
      fail "Python 3 not found. Install Python 3.11+ via Homebrew: brew install python@3.12"
      return
    fi

    echo -e "  Creating virtual environment with $pyexe..."
    "$pyexe" -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip
    ok "Virtual environment created ($VENV_DIR)"
  fi

  # Parse active (non-commented) packages from requirements.txt
  local missing=()
  while IFS= read -r line; do
    line="$(echo "$line" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    local pkg_name
    pkg_name="$(echo "$line" | sed 's/[>=<].*//')"
    if "$VENV_DIR/bin/pip" show "$pkg_name" &>/dev/null; then
      ok "$pkg_name installed"
    else
      missing+=("$line")
      warn "$pkg_name not installed"
    fi
  done < "$req_file"

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "  Installing ${#missing[@]} missing package(s)..."
    "$VENV_DIR/bin/pip" install --quiet "${missing[@]}"
    ok "All packages installed"
  fi
}

check_prerequisites() {
  echo -e "\n${BOLD}Checking prerequisites${RESET}"

  if ! command -v brew &>/dev/null; then
    fail "Homebrew is not installed."
    echo -e "     Install: ${CYAN}/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${RESET}"
    exit 1
  fi
  ok "Homebrew found"

  if [[ "$(uname -m)" != "arm64" ]]; then
    fail "Apple Silicon required (got $(uname -m)). krunkit only works on arm64."
    exit 1
  fi
  ok "Apple Silicon detected"

  local macos_version
  macos_version=$(sw_vers -productVersion | cut -d. -f1)
  if [[ "$macos_version" -lt 14 ]]; then
    fail "macOS 14+ required (got $(sw_vers -productVersion)). krunkit needs Virtualization.framework."
    exit 1
  fi
  ok "macOS $(sw_vers -productVersion)"

  ensure_venv
  echo ""
}

# ── Option 1: Configure models directory ─────────────────────────────────────

do_configure_models() {
  echo -e "\n${DIM}--- Configure models directory ---${RESET}"
  echo -e "  Model weight files (GGUF format) are stored on disk and mounted into"
  echo -e "  the minikube VM. A symlink at ${CYAN}~/.models${RESET} points to the actual directory.\n"

  if [ -L "$MODELS_LINK" ]; then
    local current_target
    current_target=$(readlink "$MODELS_LINK")
    local gguf_count
    gguf_count=$(find -L "$MODELS_LINK" -maxdepth 1 -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  ${GREEN}[Current]${RESET} ~/.models → $current_target ($gguf_count GGUF file(s))"
    echo ""
    read -r -p "  (S)kip or (R)eset? [S]: " sr_choice
    sr_choice="$(echo "$sr_choice" | tr '[:upper:]' '[:lower:]')"
    if [ "$sr_choice" != "r" ] && [ "$sr_choice" != "reset" ]; then
      echo -e "  ${DIM}No change.${RESET}"
      echo ""
      return
    fi
    echo -e "  ${DIM}Resetting models directory...${RESET}\n"
  fi

  while true; do
    read -r -p "  Enter the absolute path for model weights storage: " models_path
    models_path="$(echo "$models_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -z "$models_path" ]; then
      echo -e "  ${DIM}Cancelled.${RESET}"
      echo ""
      return
    fi

    models_path="${models_path/#\~/$HOME}"

    if [ ! -d "$models_path" ]; then
      echo ""
      read -r -p "  Directory does not exist. Create it? (y/N): " create_choice
      create_choice="$(echo "$create_choice" | tr '[:upper:]' '[:lower:]')"
      if [ "$create_choice" = "y" ] || [ "$create_choice" = "yes" ]; then
        mkdir -p "$models_path"
        ok "Created $models_path"
      else
        echo -e "  ${DIM}Try a different path.${RESET}\n"
        continue
      fi
    fi

    if [ -L "$MODELS_LINK" ]; then
      rm "$MODELS_LINK"
    elif [ -d "$MODELS_LINK" ]; then
      fail "$MODELS_LINK is a real directory, not a symlink."
      echo -e "     Remove or rename it first: ${CYAN}mv $MODELS_LINK ${MODELS_LINK}.bak${RESET}"
      echo ""
      return
    fi

    ln -sfn "$models_path" "$MODELS_LINK"
    ok "Symlink created: ~/.models → $models_path"

    local gguf_count
    gguf_count=$(find -L "$MODELS_LINK" -maxdepth 1 -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$gguf_count" -eq 0 ]; then
      warn "No GGUF models found in $models_path"
      echo -e "     Use option 3 (Download models) to fetch models."
    else
      ok "$gguf_count GGUF model(s) found"
    fi
    echo ""
    break
  done
}

# ── Option 2: Install CLI tools (renamed from old option 2, same content) ────

do_install_tools() {
  echo -e "\n${DIM}--- Install CLI tools ---${RESET}"

  if command -v minikube &>/dev/null; then
    ok "minikube already installed ($(minikube version --short))"
  else
    echo -e "  Installing minikube via Homebrew..."
    brew install minikube
    ok "minikube installed"
  fi

  if command -v kubectl &>/dev/null; then
    ok "kubectl already installed"
  else
    echo -e "  Installing kubectl via Homebrew..."
    brew install kubectl
    ok "kubectl installed"
  fi

  if command -v krunkit &>/dev/null; then
    ok "krunkit already installed"
  else
    echo -e "  Installing krunkit via Homebrew..."
    brew tap slp/krunkit && brew install krunkit
    ok "krunkit installed"
  fi

  if command -v vmnet-helper &>/dev/null || [ -f /opt/vmnet-helper/bin/vmnet-helper ]; then
    ok "vmnet-helper already installed"
  else
    echo -e "  Installing vmnet-helper (may prompt for sudo)..."
    curl -fsSL https://github.com/minikube-machine/vmnet-helper/releases/latest/download/install.sh | bash
    ok "vmnet-helper installed"
  fi

  if command -v helm &>/dev/null; then
    ok "helm already installed ($(helm version --short 2>/dev/null))"
  else
    echo -e "  Installing helm via Homebrew..."
    brew install helm
    ok "helm installed"
  fi

  if helm plugin list 2>/dev/null | grep -q 'diff'; then
    ok "helm-diff plugin already installed"
  else
    echo -e "  Installing helm-diff plugin..."
    if python3 "$SCRIPT_DIR/scripts/install_tools.py" helm-diff; then
      ok "helm-diff plugin installed"
    else
      warn "Could not install helm-diff. Install manually: helm plugin install https://github.com/databus23/helm-diff --verify=false"
    fi
  fi
  echo ""
}

# ── Option 3: Download models ────────────────────────────────────────────────

do_download_models() {
  echo -e "\n${DIM}--- Download models ---${RESET}"

  if ! [ -L "$MODELS_LINK" ]; then
    fail "Models directory not configured. Run option 1 first."
    echo ""
    return
  fi

  local models_dir
  models_dir=$(readlink "$MODELS_LINK")

  if ! [ -d "$VENV_DIR" ] || ! [ -x "$VENV_DIR/bin/python" ]; then
    fail "Virtual environment not found. Re-run setup to create it."
    echo ""
    return
  fi

  if ! "$VENV_DIR/bin/pip" show huggingface-hub &>/dev/null; then
    echo -e "  Installing huggingface-hub..."
    "$VENV_DIR/bin/pip" install --quiet huggingface-hub
    ok "huggingface-hub installed"
  fi

  echo -e "  Models directory: ${CYAN}$models_dir${RESET}\n"
  echo -e "  Available SLM models (GGUF Q4_K_M quantization):\n"

  local idx=1
  for entry in "${MODEL_CATALOG[@]}"; do
    IFS='|' read -r repo filename display_name size <<< "$entry"
    if [ -f "$models_dir/$filename" ]; then
      echo -e "  ${GREEN}$idx)${RESET} $display_name  ${DIM}($size)${RESET}  ${GREEN}[downloaded]${RESET}"
    else
      echo -e "  ${CYAN}$idx)${RESET} $display_name  ${DIM}($size)${RESET}  ${YELLOW}[available]${RESET}"
    fi
    idx=$((idx + 1))
  done

  echo ""
  echo -e "  Enter model numbers to download (comma-separated, e.g. 1,2,4)"
  echo -e "  or ${DIM}A${RESET} for all available, ${DIM}Enter${RESET} to go back.\n"
  read -r -p "  Download: " download_choice
  download_choice="$(echo "$download_choice" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [ -z "$download_choice" ]; then
    echo -e "  ${DIM}No models selected.${RESET}"
    echo ""
    return
  fi

  local indices=()
  if [ "$(echo "$download_choice" | tr '[:upper:]' '[:lower:]')" = "a" ]; then
    for i in $(seq 1 ${#MODEL_CATALOG[@]}); do
      indices+=("$i")
    done
  else
    IFS=',' read -ra indices <<< "$download_choice"
  fi

  local downloaded=0
  for raw_idx in "${indices[@]}"; do
    local i
    i="$(echo "$raw_idx" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if ! [[ "$i" =~ ^[0-9]+$ ]] || [ "$i" -lt 1 ] || [ "$i" -gt ${#MODEL_CATALOG[@]} ]; then
      warn "Skipping invalid choice: $raw_idx"
      continue
    fi

    local entry="${MODEL_CATALOG[$((i - 1))]}"
    IFS='|' read -r repo filename display_name size <<< "$entry"

    if [ -f "$models_dir/$filename" ]; then
      echo -e "  ${DIM}$display_name already downloaded — skipping.${RESET}"
      continue
    fi

    echo -e "\n  Downloading ${BOLD}$display_name${RESET} ($size)..."
    echo -e "  ${DIM}From: huggingface.co/$repo${RESET}\n"

    if "$VENV_DIR/bin/python" -c "
from huggingface_hub import hf_hub_download
hf_hub_download(repo_id='$repo', filename='$filename', local_dir='$models_dir', local_dir_use_symlinks=False)
print('done')
"; then
      ok "$display_name downloaded to $models_dir/$filename"
      downloaded=$((downloaded + 1))
    else
      fail "Failed to download $display_name"
    fi
  done

  echo ""
  if [ "$downloaded" -gt 0 ]; then
    local total
    total=$(find -L "$MODELS_LINK" -maxdepth 1 -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')
    ok "$downloaded model(s) downloaded. Total GGUF files: $total"
  fi
  echo ""
}

# ── Option 4: Start minikube cluster ─────────────────────────────────────────

do_start_cluster() {
  echo -e "\n${DIM}--- Start minikube cluster ---${RESET}"

  if ! [ -L "$MODELS_LINK" ]; then
    fail "Models directory not configured. Run option 1 first."
    echo ""
    return
  fi

  local models_store
  models_store=$(readlink "$MODELS_LINK")

  if minikube status --profile=inference &>/dev/null; then
    warn "Cluster is already running."

    # If KServe is missing, offer to install just the infrastructure
    if ! kubectl get crd inferenceservices.serving.kserve.io &>/dev/null 2>&1; then
      echo -e "  ${YELLOW}KServe not installed.${RESET}"
      read -r -p "  Install KServe infrastructure on the running cluster? (Y/n): " kserve_choice
      kserve_choice="$(echo "$kserve_choice" | tr '[:upper:]' '[:lower:]')"
      if [ "$kserve_choice" != "n" ] && [ "$kserve_choice" != "no" ]; then
        if ! do_install_kserve_infra; then
          warn "KServe infrastructure install had errors. You can retry by re-running option 4."
        fi
        while true; do
          read -r -p "  Press C to continue: " cont
          cont="$(echo "$cont" | tr '[:upper:]' '[:lower:]')"
          case "$cont" in c|continue) break ;; *) ;; esac
        done
        echo ""
        return
      fi
    fi

    read -r -p "  Restart it? (y/N): " restart_choice
    restart_choice="$(echo "$restart_choice" | tr '[:upper:]' '[:lower:]')"
    if [ "$restart_choice" = "y" ] || [ "$restart_choice" = "yes" ]; then
      echo -e "  Stopping existing cluster..."
      minikube stop --profile=inference
    else
      echo -e "  ${DIM}Skipped.${RESET}\n"
      return
    fi
  fi

  echo -e "  Starting 3-node krunkit cluster with GPU passthrough..."
  echo -e "  Nodes: controlplane, node-01, node-02 (cpus=max, memory=36 GB)"
  echo -e "  Mounting ${CYAN}$models_store${RESET} → /mnt/models\n"

  minikube start \
    --driver=krunkit \
    --nodes=3 \
    --cpus=max \
    --memory=36g \
    --mount-string "$models_store:/mnt/models" \
    --profile=inference

  ok "Cluster running (3 nodes)"

  echo -e "  Verifying GPU device on each node..."
  for node in inference inference-m02 inference-m03; do
    if minikube ssh --profile=inference --node="$node" -- ls /dev/dri/renderD128 &>/dev/null; then
      ok "GPU available on $node (/dev/dri/renderD128)"
    else
      warn "GPU not found on $node. Check: minikube ssh --profile=inference --node=$node -- ls -la /dev/dri/"
    fi
  done

  echo -e "\n  Enabling addons..."
  minikube addons enable metrics-server --profile=inference
  ok "Metrics server enabled (required for HPA autoscaling)"

  # Cluster summary
  echo -e "\n  ${BOLD}── Cluster configuration ──${RESET}\n"

  echo -e "  ${BOLD}Profile:${RESET}  inference"
  echo -e "  ${BOLD}Driver:${RESET}   krunkit (Apple Virtualization.framework)"
  echo -e "  ${BOLD}CPUs:${RESET}     max (all host cores per node)"
  echo -e "  ${BOLD}Memory:${RESET}   36 GB (split across nodes)"
  echo -e "  ${BOLD}Models:${RESET}   $models_store → /mnt/models"

  echo -e "\n  ${BOLD}Nodes:${RESET}"
  kubectl get nodes -o wide 2>/dev/null || true

  echo -e "\n  ${BOLD}GPU devices:${RESET}"
  for node in inference inference-m02 inference-m03; do
    local gpu_status
    if minikube ssh --profile=inference --node="$node" -- ls /dev/dri/renderD128 &>/dev/null; then
      gpu_status="${GREEN}virtio-gpu (Vulkan)${RESET}"
    else
      gpu_status="${RED}not detected${RESET}"
    fi
    echo -e "    $node: $gpu_status"
  done

  echo -e "\n  ${BOLD}Addons:${RESET}"
  minikube addons list --profile=inference 2>/dev/null | grep -E "enabled" || echo "    (none enabled)"

  echo -e "\n  ${BOLD}Kubernetes version:${RESET}"
  echo -e "    $(kubectl version --short 2>/dev/null || kubectl version --client 2>/dev/null || echo "unknown")"

  # Install KServe + Gateway API + cert-manager + Envoy Gateway + MetalLB
  if ! do_install_kserve_infra; then
    warn "KServe infrastructure install had errors. You can retry by re-running option 4."
  fi

  while true; do
    read -r -p "  Press C to continue: " cont
    cont="$(echo "$cont" | tr '[:upper:]' '[:lower:]')"
    case "$cont" in
      c|continue) break ;;
      *) ;;
    esac
  done
  echo ""
}

# ── KServe infrastructure install (called by option 4 after cluster start) ────

KSERVE_VERSION="v0.16.0"
CERT_MANAGER_VERSION="v1.17.0"

do_install_kserve_infra() {
  echo -e "\n  ${BOLD}── Installing KServe infrastructure ──${RESET}\n"

  if ! command -v helm &>/dev/null; then
    fail "helm not found. Run option 2 (Install CLI tools) first."
    return 1
  fi

  # 1. cert-manager
  if kubectl get namespace cert-manager &>/dev/null 2>&1; then
    ok "cert-manager already installed"
  else
    echo -e "  Installing cert-manager ${CERT_MANAGER_VERSION}..."
    helm repo add jetstack https://charts.jetstack.io --force-update 2>/dev/null
    helm repo update jetstack 2>/dev/null
    helm install cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --create-namespace \
      --version "$CERT_MANAGER_VERSION" \
      --set crds.enabled=true \
      --wait
    ok "cert-manager ${CERT_MANAGER_VERSION} installed"
  fi

  # 2. Envoy Gateway (bundles Gateway API CRDs)
  if kubectl get namespace envoy-gateway-system &>/dev/null 2>&1; then
    ok "Envoy Gateway already installed"
  else
    local skip_crds_flag=""
    if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null 2>&1; then
      ok "Gateway API CRDs already present"
      skip_crds_flag="--skip-crds"
    fi
    echo -e "  Installing Envoy Gateway (includes Gateway API CRDs)..."
    helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
      --namespace envoy-gateway-system \
      --create-namespace \
      $skip_crds_flag \
      --wait
    ok "Envoy Gateway installed"
  fi

  # 2b. Ensure GatewayClass "envoy" exists so Envoy Gateway adopts our Gateway and creates the data-plane proxy + LoadBalancer
  if ! kubectl get gatewayclass envoy &>/dev/null 2>&1; then
    echo -e "  Creating GatewayClass ${CYAN}envoy${RESET} for Envoy Gateway..."
    kubectl apply -f - <<'GATEWAYCLASS'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  description: Envoy Gateway class for neural-gate
GATEWAYCLASS
    ok "GatewayClass envoy created"
  else
    ok "GatewayClass envoy exists"
  fi

  # 4. KServe CRDs + controller (Standard mode with Gateway API)
  if kubectl get crd inferenceservices.serving.kserve.io &>/dev/null 2>&1; then
    ok "KServe already installed"
  else
    echo -e "  Installing KServe CRDs ${KSERVE_VERSION}..."
    helm install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd \
      --version "$KSERVE_VERSION" \
      --wait

    echo -e "  Installing KServe controller ${KSERVE_VERSION} (Standard mode)..."
    echo -e "  ${DIM}(If webhook is not ready yet, script will wait and retry once.)${RESET}"
    local kserve_install_args=(
      --version "$KSERVE_VERSION"
      --set kserve.controller.deploymentMode=RawDeployment
      --set kserve.controller.gateway.ingressGateway.enableGatewayApi=true
      --wait
      --timeout 5m
      --atomic=false
    )
    if ! helm install kserve oci://ghcr.io/kserve/charts/kserve "${kserve_install_args[@]}"; then
      if helm list -a -q -f '^kserve$' 2>/dev/null | grep -q .; then
        warn "First install failed (webhook not ready). Waiting 90s for controller to start, then retrying..."
        sleep 90
        if helm upgrade kserve oci://ghcr.io/kserve/charts/kserve "${kserve_install_args[@]}"; then
          ok "KServe ${KSERVE_VERSION} installed (Standard mode + Gateway API) after retry"
        else
          fail "KServe install failed. Check: kubectl get pods -A | grep kserve"
          return 1
        fi
      else
        fail "KServe install failed. Check: kubectl get pods -A | grep kserve"
        return 1
      fi
    else
      ok "KServe ${KSERVE_VERSION} installed (Standard mode + Gateway API)"
    fi
  fi

  # 5. MetalLB (for local LoadBalancer IPs)
  if minikube addons list --profile=inference 2>/dev/null | grep -q "metallb.*enabled"; then
    ok "MetalLB addon already enabled"
  else
    echo -e "  Enabling MetalLB addon..."
    minikube addons enable metallb --profile=inference
    ok "MetalLB addon enabled"
  fi

  local minikube_ip
  minikube_ip=$(minikube ip --profile=inference 2>/dev/null || echo "")
  if [ -n "$minikube_ip" ]; then
    local ip_prefix
    ip_prefix=$(echo "$minikube_ip" | awk -F. '{printf "%s.%s.%s", $1, $2, $3}')
    local pool_start="${ip_prefix}.200"
    local pool_end="${ip_prefix}.220"

    local metallb_yaml
    metallb_yaml=$(mktemp /tmp/neural-gate-metallb-XXXXXX.yaml)
    cat > "$metallb_yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: config
  namespace: metallb-system
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${pool_start}-${pool_end}
YAML
    kubectl apply -f "$metallb_yaml"
    rm -f "$metallb_yaml"
    ok "MetalLB pool: ${pool_start}–${pool_end}"
  fi

  echo ""
  ok "KServe infrastructure ready"
  echo ""
}

# ── Option 5: Deploy the inference stack ─────────────────────────────────────

HELM_CHART_DIR="$SCRIPT_DIR/k8s/neural-gate"

model_to_k8s_name() {
  echo "$1" | sed 's/\.gguf$//;s/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | cut -c1-63 | sed 's/-$//'
}

do_deploy_stack() {
  echo -e "\n${DIM}--- Deploy inference stack (Helm + KServe) ---${RESET}"

  if ! minikube status --profile=inference &>/dev/null; then
    fail "Cluster is not running. Run option 4 (Start minikube cluster) first."
    echo ""
    return
  fi

  if ! command -v helm &>/dev/null; then
    fail "helm not found. Run option 2 (Install CLI tools) first."
    echo ""
    return
  fi

  if ! kubectl get crd inferenceservices.serving.kserve.io &>/dev/null 2>&1; then
    fail "KServe not installed. Run option 4 (Start minikube cluster) to install KServe infrastructure."
    echo ""
    return
  fi

  if ! [ -L "$MODELS_LINK" ]; then
    fail "Models directory not configured. Run option 1 first."
    echo ""
    return
  fi

  local models_dir
  models_dir=$(readlink "$MODELS_LINK")

  # ── Step 1: Select models to deploy ──────────────────────────────────────

  local -a available_gguf=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    available_gguf+=("$(basename "$f")")
  done < <(find -L "$MODELS_LINK" -maxdepth 1 -name '*.gguf' 2>/dev/null | sort)

  if [ ${#available_gguf[@]} -eq 0 ]; then
    fail "No GGUF models in $models_dir. Run option 3 (Download models) first."
    echo ""
    return
  fi

  # Detect already-deployed model names via Helm release
  local -a deployed_models=()
  local helm_values_json=""
  if helm status neural-gate --namespace inference &>/dev/null 2>&1; then
    helm_values_json=$(helm get values neural-gate --namespace inference -o json 2>/dev/null || echo "{}")
    while IFS= read -r mname; do
      [ -z "$mname" ] && continue
      deployed_models+=("$mname")
    done < <(echo "$helm_values_json" | "$VENV_DIR/bin/python" -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('models', []):
    print(m.get('name', ''))
" 2>/dev/null || true)
  fi

  echo -e "\n  ${BOLD}Step 1: Select models to deploy${RESET}\n"
  echo -e "  GGUF files in ${CYAN}$models_dir${RESET}:\n"

  local idx=1
  local deployed_count=0
  for gguf in "${available_gguf[@]}"; do
    local k8s_name
    k8s_name=$(model_to_k8s_name "$gguf")
    local status_tag="${GREEN}available${RESET}"
    if [ ${#deployed_models[@]} -gt 0 ]; then
      for d in "${deployed_models[@]}"; do
        if [ "$d" = "$k8s_name" ]; then
          status_tag="${DIM}deployed${RESET}"
          deployed_count=$((deployed_count + 1))
          break
        fi
      done
    fi
    echo -e "  ${CYAN}$idx)${RESET} $gguf  [${status_tag}]"
    idx=$((idx + 1))
  done

  if [ "$deployed_count" -gt 0 ]; then
    echo -e "\n  ${DIM}$deployed_count model(s) already deployed. Re-selecting will update in place.${RESET}"
  fi

  echo ""
  echo -e "  Enter ${BOLD}one${RESET} model number to deploy (1–${#available_gguf[@]}), ${DIM}Enter${RESET} to go back.\n"
  read -r -p "  Deploy model: " model_choice
  model_choice="$(echo "$model_choice" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [ -z "$model_choice" ]; then
    echo -e "  ${DIM}Cancelled.${RESET}\n"
    return
  fi

  # Take only the first number so we deploy one model at a time
  local -a selected_indices=()
  local first_num
  first_num=$(echo "$model_choice" | sed 's/,.*//' | tr -d ' ')
  if [[ "$first_num" =~ ^[0-9]+$ ]]; then
    selected_indices=("$first_num")
  else
    fail "Enter a single model number (1–${#available_gguf[@]})."
    echo ""
    return
  fi

  local -a selected_models=()
  for raw_idx in "${selected_indices[@]}"; do
    local i
    i="$(echo "$raw_idx" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if ! [[ "$i" =~ ^[0-9]+$ ]] || [ "$i" -lt 1 ] || [ "$i" -gt ${#available_gguf[@]} ]; then
      warn "Skipping invalid choice: $raw_idx"
      continue
    fi
    selected_models+=("${available_gguf[$((i - 1))]}")
  done

  if [ ${#selected_models[@]} -eq 0 ]; then
    fail "No valid models selected."
    echo ""
    return
  fi

  echo ""
  if [ ${#selected_models[@]} -eq 1 ]; then
    ok "1 model selected for deployment"
  else
    ok "${#selected_models[@]} models selected for deployment"
  fi

  # Warn if total models (deployed + new) exceeds node count
  local node_count
  node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  local new_count=0
  for gguf_file in "${selected_models[@]}"; do
    local k8s_name
    k8s_name=$(model_to_k8s_name "$gguf_file")
    local already=0
    if [ ${#deployed_models[@]} -gt 0 ]; then
      for d in "${deployed_models[@]}"; do
        if [ "$d" = "$k8s_name" ]; then already=1; break; fi
      done
    fi
    [ "$already" -eq 0 ] && new_count=$((new_count + 1))
  done
  local total_after=$(( deployed_count + new_count ))
  if [ "$total_after" -gt "$node_count" ]; then
    warn "After deploy: $total_after model(s) total but only $node_count node(s) available."
    echo -e "     ${DIM}Anti-affinity requires 1 model per node — excess pods will stay Pending.${RESET}"
    echo ""
    read -r -p "  Continue anyway? (y/N): " over_choice
    over_choice="$(echo "$over_choice" | tr '[:upper:]' '[:lower:]')"
    if [ "$over_choice" != "y" ] && [ "$over_choice" != "yes" ]; then
      echo -e "  ${DIM}Cancelled.${RESET}\n"
      return
    fi
  fi

  # ── Step 2: Build Helm --set arguments ─────────────────────────────────

  # Merge previously deployed models with newly selected ones
  local -a all_models=()
  if [ ${#deployed_models[@]} -gt 0 ]; then
    for d in "${deployed_models[@]}"; do
      local gguf_for_deployed="${d}.gguf"
      # Match against available GGUFs to get exact filename
      for avail in "${available_gguf[@]}"; do
        if [ "$(model_to_k8s_name "$avail")" = "$d" ]; then
          gguf_for_deployed="$avail"
          break
        fi
      done
      all_models+=("$gguf_for_deployed")
    done
  fi
  for sm in "${selected_models[@]}"; do
    local k8s_name
    k8s_name=$(model_to_k8s_name "$sm")
    local dup=0
    if [ ${#deployed_models[@]} -gt 0 ]; then
      for d in "${deployed_models[@]}"; do
        if [ "$d" = "$k8s_name" ]; then dup=1; break; fi
      done
    fi
    if [ "$dup" -eq 0 ]; then
      all_models+=("$sm")
    fi
  done

  local -a helm_set_args=()
  for idx in "${!all_models[@]}"; do
    local gguf="${all_models[$idx]}"
    local name
    name=$(model_to_k8s_name "$gguf")
    local ctx_size="32768"
    if [ -f "$HELM_CHART_DIR/values.yaml" ]; then
      local from_vals
      from_vals=$(python3 -c "
import sys
try:
    import yaml
except ImportError:
    print(32768)
    sys.exit(0)
name = sys.argv[1]
path = sys.argv[2]
try:
    with open(path) as f:
        v = yaml.safe_load(f) or {}
except Exception:
    print(32768)
    sys.exit(0)
engine_ctx = (v.get('engine') or {}).get('contextSize', 4096)
for m in (v.get('models') or []):
    if m.get('name') == name:
        print(m.get('contextSize') or engine_ctx)
        sys.exit(0)
print(engine_ctx)
" "$name" "$HELM_CHART_DIR/values.yaml" 2>/dev/null || echo "32768")
      [ -n "$from_vals" ] && ctx_size="$from_vals"
    fi
    helm_set_args+=(
      "--set" "models[$idx].name=$name"
      "--set" "models[$idx].ggufFile=$gguf"
      "--set" "models[$idx].contextSize=$ctx_size"
      "--set" "models[$idx].cpu.request=2"
      "--set" "models[$idx].cpu.limit=4"
      "--set" "models[$idx].memory.request=4Gi"
      "--set" "models[$idx].memory.limit=8Gi"
    )
  done

  # Plan-only args: render chart for the one selected model so the preview shows only that model's resources
  local -a helm_set_args_plan=()
  for idx in "${!selected_models[@]}"; do
    local gguf="${selected_models[$idx]}"
    local name
    name=$(model_to_k8s_name "$gguf")
    helm_set_args_plan+=(
      "--set" "models[$idx].name=$name"
      "--set" "models[$idx].ggufFile=$gguf"
      "--set" "models[$idx].cpu.request=2"
      "--set" "models[$idx].cpu.limit=4"
      "--set" "models[$idx].memory.request=4Gi"
      "--set" "models[$idx].memory.limit=8Gi"
    )
  done

  # ── Step 2: Execution plan (helm-diff + helm_plan.py) ────────────────────────────

  echo -e "\n  ${BOLD}Step 2: Execution plan (helm diff) — ${#selected_models[@]} model(s) this run${RESET}\n"

  if ! helm plugin list 2>/dev/null | grep -q 'diff'; then
    if [ ! -t 0 ]; then
      fail "helm-diff plugin is required for the plan view. Install: helm plugin install https://github.com/databus23/helm-diff --verify=false"
      echo ""
      return 1
    fi
    read -r -p "  Install helm-diff plugin for plan view? (Y/n): " diff_choice
    diff_choice=$(echo "${diff_choice:-y}" | tr '[:upper:]' '[:lower:]')
    if [[ ! "$diff_choice" =~ ^(y|yes)?$ ]]; then
      echo -e "  ${DIM}helm-diff is required. Exiting. Install manually: helm plugin install https://github.com/databus23/helm-diff --verify=false${RESET}\n"
      return 1
    fi
    echo -e "  ${DIM}Installing helm-diff plugin...${RESET}"
    if ! python3 "$SCRIPT_DIR/scripts/install_tools.py" helm-diff; then
      fail "Could not install helm-diff. Install manually: helm plugin install https://github.com/databus23/helm-diff --verify=false"
      echo ""
      return 1
    fi
    ok "helm-diff installed"
  fi

  local plan_json
  plan_json=$(python3 "$SCRIPT_DIR/scripts/helm_plan.py" neural-gate "$HELM_CHART_DIR" inference "${helm_set_args[@]}" 2>/dev/null || echo '{"changes":[],"has_changes":false}')
  if echo "$plan_json" | grep -q '"error"'; then
    warn "helm_plan.py failed. ($(echo "$plan_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("error","?"))' 2>/dev/null))"
    plan_json='{"changes":[],"has_changes":true}'
  fi

  echo -e "  ${DIM}Diff (green + add, red - remove, yellow ~ change):${RESET}\n"
  helm diff upgrade neural-gate "$HELM_CHART_DIR" --namespace inference "${helm_set_args[@]}" 2>/dev/null || true
  echo ""

  local change_count
  change_count=$(echo "$plan_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d.get('changes', [])))
" 2>/dev/null || echo "0")

  echo -e "  ${BOLD}Changes:${RESET}"
  if echo "$plan_json" | grep -q '"error"'; then
    echo -e "  ${DIM}(change list unavailable — install PyYAML: pip install pyyaml)${RESET}"
  elif [ "$change_count" -eq 0 ]; then
    echo -e "  ${DIM}(no changes — release is up to date)${RESET}"
  else
    echo "$plan_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for i, c in enumerate(d.get('changes', []), 1):
    action = c.get('action', '')
    state = c.get('state', '')
    print(f\"  {i}. {c.get('kind','')}: {c.get('name','')}, {action}, {state}, {c.get('source_file','')}\")
" 2>/dev/null
  fi
  echo ""
  local model_summary=""
  for m in "${all_models[@]}"; do
    local k8s_name
    k8s_name=$(model_to_k8s_name "$m")
    if [[ " ${selected_models[*]} " == *" $m "* ]]; then
      model_summary="${model_summary:+$model_summary, }$k8s_name [updated]"
    else
      model_summary="${model_summary:+$model_summary, }$k8s_name [unchanged]"
    fi
  done
  echo -e "  ${DIM}Plan: ${change_count} resource(s) with changes. On Apply, release will have ${#all_models[@]} model(s) total: ${model_summary}.${RESET}\n"

  # ── Step 3: Apply / Reject / Quit ────────────────────────────────────────

  while true; do
    read -r -p "  (A)pply / (R)eject / (Q)uit to menu: " choice
    choice="$(echo "$choice" | tr '[:upper:]' '[:lower:]')"
    case "$choice" in
      a|apply)
        echo ""
        # Adopt existing resources so Helm can manage them (avoids "invalid ownership" error)
        if kubectl get namespace inference &>/dev/null; then
          echo -e "  Adopting existing ${CYAN}inference${RESET} namespace for Helm..."
          kubectl label namespace inference app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
          kubectl annotate namespace inference meta.helm.sh/release-name=neural-gate meta.helm.sh/release-namespace=inference --overwrite 2>/dev/null || true
        fi
        if kubectl get daemonset generic-device-plugin -n kube-system &>/dev/null; then
          echo -e "  Adopting existing ${CYAN}generic-device-plugin${RESET} DaemonSet for Helm..."
          kubectl label daemonset generic-device-plugin -n kube-system app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
          kubectl annotate daemonset generic-device-plugin -n kube-system meta.helm.sh/release-name=neural-gate meta.helm.sh/release-namespace=inference --overwrite 2>/dev/null || true
        fi
        # Avoid HTTPRoute field-manager conflict (e.g. Envoy Gateway "manager"): delete so Helm can recreate and own them
        if kubectl get httproute -n inference -l app.kubernetes.io/name=neural-gate --no-headers 2>/dev/null | grep -q .; then
          echo -e "  Recreating HTTPRoutes so Helm can own them (avoids conflict with Gateway controller)..."
          kubectl delete httproute -n inference -l app.kubernetes.io/name=neural-gate --ignore-not-found 2>/dev/null || true
        fi
        echo -e "  Running: ${DIM}helm upgrade --install neural-gate ...${RESET}\n"
        helm upgrade --install neural-gate "$HELM_CHART_DIR" \
          --namespace inference \
          --create-namespace \
          "${helm_set_args[@]}" \
          --wait --timeout 5m

        echo ""
        ok "Helm release 'neural-gate' deployed"
        echo -e "\n  Deployed models:"
        for m in "${all_models[@]}"; do
          echo -e "    ${CYAN}$(model_to_k8s_name "$m")${RESET} ($m)"
        done
        echo -e "\n${DIM}Actions:${RESET}"
        echo -e "  ${YELLOW}[waiting]   Pods starting — watch with: kubectl get pods -n inference -w${RESET}"
        echo -e "  ${YELLOW}[suggested] Configure ingress (Gateway + /etc/hosts) in option 6.${RESET}"
        echo -e "  ${YELLOW}[suggested] Once pods are Running, run smoke test in option 7.${RESET}\n"
        return
        ;;
      r|reject)
        echo -e "  ${DIM}Rejected. No changes applied.${RESET}\n"
        return
        ;;
      q|quit)
        echo -e "  ${DIM}Returning to menu.${RESET}\n"
        return
        ;;
      *)
        ;;
    esac
  done
}

# ── Option 6: Configure ingress (KServe Gateway + /etc/hosts) ────────────────

do_configure_ingress() {
  echo -e "\n${DIM}--- Configure ingress (KServe Gateway + /etc/hosts) ---${RESET}"

  if ! minikube status --profile=inference &>/dev/null; then
    fail "Cluster is not running. Run option 4 (Start minikube cluster) first."
    echo ""
    return
  fi

  # ── Step 1: Verify Gateway exists ────────────────────────────────────────

  echo -e "\n  ${BOLD}Step 1: Verify KServe Gateway${RESET}\n"

  if ! kubectl get gateway inference-gateway -n inference &>/dev/null 2>&1; then
    warn "Gateway 'inference-gateway' not found in namespace 'inference'."
    echo -e "  ${DIM}Deploy models via option 5 first (the Helm chart creates the Gateway).${RESET}"
    echo ""
    return
  fi
  ok "Gateway 'inference-gateway' found"

  # ── Step 2: Wait for Gateway external IP (MetalLB) ────────────────────────

  echo -e "\n  ${BOLD}Step 2: Gateway external IP (via MetalLB)${RESET}\n"

  echo -e "  Waiting for Gateway to receive an external IP from MetalLB..."
  local gateway_ip="" retries=0
  while [ -z "$gateway_ip" ] && [ "$retries" -lt 45 ]; do
    # 1) From Gateway status (Envoy Gateway populates when Envoy Service gets an IP)
    gateway_ip=$(kubectl get gateway inference-gateway -n inference \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    # 2) From Envoy proxy Service in inference namespace (GatewayNamespace mode)
    if [ -z "$gateway_ip" ]; then
      gateway_ip=$(kubectl get svc -n inference -l gateway.networking.k8s.io/gateway-name=inference-gateway \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    fi
    # 3) From Envoy proxy Service in envoy-gateway-system (default: controller namespace)
    if [ -z "$gateway_ip" ]; then
      gateway_ip=$(kubectl get svc -n envoy-gateway-system \
        -l gateway.envoyproxy.io/owning-gateway-namespace=inference,gateway.envoyproxy.io/owning-gateway-name=inference-gateway \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    fi
    # 4) Any LoadBalancer in envoy-gateway-system with an IP (single Gateway fallback)
    if [ -z "$gateway_ip" ]; then
      gateway_ip=$(kubectl get svc -n envoy-gateway-system -o custom-columns=TYPE:.spec.type,IP:.status.loadBalancer.ingress[0].ip --no-headers 2>/dev/null | \
        awk '$1=="LoadBalancer" && $2!="" && $2!="<pending>" {print $2; exit}' || true)
    fi
    if [ -z "$gateway_ip" ]; then
      sleep 2
      retries=$((retries + 1))
    fi
  done

  if [ -z "$gateway_ip" ]; then
    # Ensure Envoy proxy Service is LoadBalancer so MetalLB can assign an IP
    local envoy_svc
    envoy_svc=$(kubectl get svc -n envoy-gateway-system \
      -l gateway.envoyproxy.io/owning-gateway-namespace=inference,gateway.envoyproxy.io/owning-gateway-name=inference-gateway \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$envoy_svc" ]; then
      local svc_type
      svc_type=$(kubectl get svc "$envoy_svc" -n envoy-gateway-system -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
      if [ "$svc_type" != "LoadBalancer" ]; then
        echo -e "  Patching Envoy proxy Service ${CYAN}$envoy_svc${RESET} to LoadBalancer..."
        kubectl patch svc "$envoy_svc" -n envoy-gateway-system -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null && \
          ok "Patched. Re-run option 6 in a minute so MetalLB can assign an IP." || true
      fi
    fi
    # If GatewayClass "envoy" is missing, Envoy Gateway won't create the data-plane proxy
    if ! kubectl get gatewayclass envoy &>/dev/null 2>&1; then
      echo -e "  ${YELLOW}GatewayClass \"envoy\" not found. Creating it so Envoy Gateway adopts the Gateway...${RESET}"
      kubectl apply -f - <<'GATEWAYCLASS'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  description: Envoy Gateway class for neural-gate
GATEWAYCLASS
      ok "GatewayClass envoy created. Wait ~60s then re-run option 6."
    fi
    warn "Gateway has no external IP yet."
    echo -e "     Envoy proxy Service may still be pending MetalLB. Check:"
    echo -e "     ${CYAN}kubectl get svc -n envoy-gateway-system${RESET}"
    echo -e "     ${CYAN}kubectl get gateway inference-gateway -n inference${RESET}"
    echo -e "     If the Service is LoadBalancer but <pending>, ensure MetalLB addon is enabled and has an IP pool (option 4)."
    echo ""
    return
  fi

  ok "Gateway IP: ${gateway_ip}"

  # ── Step 3: Discover HTTPRoutes / model hostnames ────────────────────────

  echo -e "\n  ${BOLD}Step 3: Model endpoints (HTTPRoutes)${RESET}\n"

  local -a hostnames=()
  local -a model_names=()
  while IFS= read -r route_name; do
    [ -z "$route_name" ] && continue
    local hostname
    hostname=$(kubectl get httproute "$route_name" -n inference \
      -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || echo "")
    if [ -n "$hostname" ]; then
      hostnames+=("$hostname")
      model_names+=("$route_name")
    fi
  done < <(kubectl get httproute -n inference -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  if [ ${#hostnames[@]} -eq 0 ]; then
    warn "No HTTPRoutes found. Deploy models via option 5 first."
    echo ""
    return
  fi

  for i in "${!model_names[@]}"; do
    echo -e "  ${GREEN}✔${RESET} ${model_names[$i]}  →  ${CYAN}http://${hostnames[$i]}${RESET}"
  done

  # ── Step 4: Configure /etc/hosts ─────────────────────────────────────────

  echo -e "\n  ${BOLD}Step 4: DNS (/etc/hosts)${RESET}\n"

  local hosts_changed=0
  for hostname in "${hostnames[@]}"; do
    if grep -q "$hostname" /etc/hosts 2>/dev/null; then
      local existing_ip
      existing_ip=$(grep "$hostname" /etc/hosts | awk '{print $1}' | head -1)
      if [ "$existing_ip" = "$gateway_ip" ]; then
        ok "$hostname → $gateway_ip (already set)"
      else
        warn "$hostname points to $existing_ip, updating to $gateway_ip"
        sudo sed -i '' "s/.*${hostname}/${gateway_ip} ${hostname}/" /etc/hosts
        ok "$hostname → $gateway_ip (updated)"
        hosts_changed=1
      fi
    else
      hosts_changed=1
    fi
  done

  if [ "$hosts_changed" -eq 1 ]; then
    local new_entries=""
    for hostname in "${hostnames[@]}"; do
      if ! grep -q "$hostname" /etc/hosts 2>/dev/null; then
        new_entries="${new_entries}${gateway_ip} ${hostname}\n"
      fi
    done
    if [ -n "$new_entries" ]; then
      echo -e "  Adding to /etc/hosts (requires sudo)..."
      echo -e "$new_entries" | sudo tee -a /etc/hosts >/dev/null
      for hostname in "${hostnames[@]}"; do
        if grep -q "$hostname" /etc/hosts 2>/dev/null; then
          ok "$hostname → $gateway_ip"
        fi
      done
    fi
  fi

  # ── Summary ─────────────────────────────────────────────────────────────

  echo -e "\n  ${BOLD}${GREEN}Ingress ready.${RESET} Endpoints:\n"
  for i in "${!model_names[@]}"; do
    echo -e "  ${CYAN}Health:${RESET}  curl http://${hostnames[$i]}/health"
    echo -e "  ${CYAN}Chat:${RESET}    curl http://${hostnames[$i]}/v1/chat/completions \\"
    echo -e "           -H 'Content-Type: application/json' \\"
    echo -e "           -d '{\"model\": \"${model_names[$i]}\", \"messages\": [{\"role\": \"user\", \"content\": \"hello\"}]}'"
    echo ""
  done
}

# ── Option 7: Run smoke test ─────────────────────────────────────────────────

do_smoke_test() {
  echo -e "\n${DIM}--- Smoke test ---${RESET}"
  bash "$SCRIPT_DIR/scripts/smoke-test.sh"
  echo ""
}

# ── Option 8: Run benchmark ──────────────────────────────────────────────────

do_benchmark() {
  echo -e "\n${DIM}--- Benchmark ---${RESET}"
  bash "$SCRIPT_DIR/scripts/benchmark.sh"
  echo ""
}

# ── Option 9: Teardown ───────────────────────────────────────────────────────

do_teardown() {
  echo -e "\n${DIM}--- Teardown ---${RESET}"
  read -r -p "  This will delete the minikube cluster (profile: inference). Continue? (y/N): " confirm
  confirm="$(echo "$confirm" | tr '[:upper:]' '[:lower:]')"
  if [ "$confirm" = "y" ] || [ "$confirm" = "yes" ]; then
    # Clean up /etc/hosts entries
    if grep -q "inference.local" /etc/hosts 2>/dev/null; then
      echo -e "  Removing *.inference.local from /etc/hosts (requires sudo)..."
      sudo sed -i '' '/inference\.local/d' /etc/hosts
      ok "DNS entries removed"
    fi
    minikube delete --profile=inference
    ok "Cluster deleted"
  else
    echo -e "  ${DIM}Cancelled.${RESET}"
  fi
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo -e "${BOLD}=== neural-gate setup ===${RESET}"
echo -e "Interactive setup for the inference stack on Apple Silicon.\n"

check_prerequisites

while true; do
  show_current_state
  show_actions

  echo -e "What should the setup do next?"
  echo -e "  1)  Configure models directory"
  echo -e "  2)  Install CLI tools (minikube, kubectl, krunkit, helm, helm-diff, vmnet-helper)"
  echo -e "  3)  Download models"
  echo -e "  4)  Start minikube cluster"
  echo -e "  5)  Deploy inference stack"
  echo -e "  6)  Configure ingress (Gateway + /etc/hosts)"
  echo -e "  7)  Run smoke test"
  echo -e "  8)  Run benchmark"
  echo -e "  9)  Teardown cluster"
  echo -e "  10) Done/Exit (default)"
  read -r -p "Choice (1-10) [10]: " menu_choice
  menu_choice="$(echo "$menu_choice" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  menu_choice="${menu_choice:-10}"

  case "$menu_choice" in
    1)  do_configure_models ;;
    2)  do_install_tools ;;
    3)  do_download_models ;;
    4)  do_start_cluster ;;
    5)  do_deploy_stack ;;
    6)  do_configure_ingress ;;
    7)  do_smoke_test ;;
    8)  do_benchmark ;;
    9)  do_teardown ;;
    10) echo -e "${DIM}Done.${RESET}"; exit 0 ;;
    *)  echo -e "${DIM}Invalid choice.${RESET}\n" ;;
  esac
done
