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

MODELS_LINK="$HOME/.models"
GGUF_MAGIC="47475546"

echo -e "${BOLD}=== ollama-export ===${RESET}"
echo -e "Export Ollama model blobs as usable GGUF files.\n"

# ── Resolve Ollama models directory ──────────────────────────────────────────

OLLAMA_DIR=""

if command -v ollama &>/dev/null && ollama list &>/dev/null 2>&1; then
  # Query a known model to find the blobs path from its modelfile
  first_model=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | head -1)
  if [ -n "$first_model" ]; then
    blob_path=$(ollama show "$first_model" --modelfile 2>/dev/null | grep '^FROM /' | sed 's/^FROM //' | head -1)
    if [ -n "$blob_path" ]; then
      # Walk up from .../blobs/sha256-xxx to the models root
      OLLAMA_DIR=$(echo "$blob_path" | sed 's|/blobs/.*||')
    fi
  fi
fi

if [ -z "$OLLAMA_DIR" ]; then
  # Fallback: check common locations
  for candidate in "$HOME/.ollama/models" "$HOME/workspace/ollama_models" "$HOME/.ollama"; do
    if [ -d "$candidate/blobs" ]; then
      OLLAMA_DIR="$candidate"
      break
    fi
  done
fi

if [ -z "$OLLAMA_DIR" ] || [ ! -d "$OLLAMA_DIR/blobs" ]; then
  echo -e "  Could not auto-detect the Ollama models directory."
  read -r -p "  Enter the path to your Ollama models directory: " user_dir
  user_dir="$(echo "$user_dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  user_dir="${user_dir/#\~/$HOME}"
  if [ -d "$user_dir/blobs" ]; then
    OLLAMA_DIR="$user_dir"
  elif [ -d "$user_dir" ]; then
    OLLAMA_DIR="$user_dir"
  else
    fail "Directory not found: $user_dir"
    exit 1
  fi
fi

ok "Ollama models directory: $OLLAMA_DIR"

# ── Resolve output directory ─────────────────────────────────────────────────

OUTPUT_DIR=""
if [ -L "$MODELS_LINK" ]; then
  OUTPUT_DIR=$(readlink "$MODELS_LINK")
  echo -e "  Output directory: ${CYAN}$OUTPUT_DIR${RESET} (via ~/.models symlink)"
elif [ -d "$MODELS_LINK" ]; then
  OUTPUT_DIR="$MODELS_LINK"
  echo -e "  Output directory: ${CYAN}$OUTPUT_DIR${RESET}"
fi

if [ -z "$OUTPUT_DIR" ] || [ ! -d "$OUTPUT_DIR" ]; then
  echo ""
  read -r -p "  Enter output directory for GGUF files: " user_out
  user_out="$(echo "$user_out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  user_out="${user_out/#\~/$HOME}"
  if [ ! -d "$user_out" ]; then
    read -r -p "  Directory does not exist. Create it? (y/N): " create
    create="$(echo "$create" | tr '[:upper:]' '[:lower:]')"
    if [ "$create" = "y" ] || [ "$create" = "yes" ]; then
      mkdir -p "$user_out"
    else
      fail "No output directory. Exiting."
      exit 1
    fi
  fi
  OUTPUT_DIR="$user_out"
fi
echo ""

# ── List Ollama models ───────────────────────────────────────────────────────

if ! command -v ollama &>/dev/null; then
  fail "ollama CLI not found."
  exit 1
fi

echo -e "${DIM}Querying ollama for downloaded models...${RESET}\n"

MODELS=()
BLOB_PATHS=()
SIZES=()

while IFS= read -r line; do
  [ -z "$line" ] && continue
  model_name=$(echo "$line" | awk '{print $1}')
  model_size=$(echo "$line" | awk '{print $3, $4}')

  blob_path=$(ollama show "$model_name" --modelfile 2>/dev/null | grep '^FROM /' | sed 's/^FROM //' | head -1)
  if [ -z "$blob_path" ] || [ ! -f "$blob_path" ]; then
    continue
  fi

  # Verify it's actually GGUF by checking magic bytes
  magic=$(xxd -l 4 -p "$blob_path" 2>/dev/null || echo "")
  if [ "$magic" != "$GGUF_MAGIC" ]; then
    continue
  fi

  MODELS+=("$model_name")
  BLOB_PATHS+=("$blob_path")
  SIZES+=("$model_size")
done < <(ollama list 2>/dev/null | tail -n +2)

if [ ${#MODELS[@]} -eq 0 ]; then
  fail "No exportable GGUF models found in Ollama."
  exit 1
fi

echo -e "  Ollama models with GGUF weights:\n"

for i in "${!MODELS[@]}"; do
  local_name=$(echo "${MODELS[$i]}" | tr '/:' '-')
  gguf_name="${local_name}.gguf"

  if [ -f "$OUTPUT_DIR/$gguf_name" ]; then
    echo -e "  ${GREEN}$((i + 1)))${RESET} ${MODELS[$i]}  ${DIM}(${SIZES[$i]})${RESET}  ${GREEN}[exported → $gguf_name]${RESET}"
  else
    echo -e "  ${CYAN}$((i + 1)))${RESET} ${MODELS[$i]}  ${DIM}(${SIZES[$i]})${RESET}  ${YELLOW}[available]${RESET}"
  fi
done

echo ""
echo -e "  Enter model numbers to export (comma-separated, e.g. 1,3)"
echo -e "  or ${DIM}A${RESET} for all available, ${DIM}Enter${RESET} to cancel.\n"
read -r -p "  Export: " export_choice
export_choice="$(echo "$export_choice" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

if [ -z "$export_choice" ]; then
  echo -e "  ${DIM}No models selected.${RESET}"
  exit 0
fi

indices=()
if [ "$(echo "$export_choice" | tr '[:upper:]' '[:lower:]')" = "a" ]; then
  for i in $(seq 1 ${#MODELS[@]}); do
    indices+=("$i")
  done
else
  IFS=',' read -ra indices <<< "$export_choice"
fi

# ── Export selected models ───────────────────────────────────────────────────

exported=0

for raw_idx in "${indices[@]}"; do
  idx="$(echo "$raw_idx" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt ${#MODELS[@]} ]; then
    warn "Skipping invalid choice: $raw_idx"
    continue
  fi

  i=$((idx - 1))
  model_name="${MODELS[$i]}"
  blob_path="${BLOB_PATHS[$i]}"
  model_size="${SIZES[$i]}"

  local_name=$(echo "$model_name" | tr '/:' '-')
  gguf_name="${local_name}.gguf"
  dest="$OUTPUT_DIR/$gguf_name"

  if [ -f "$dest" ]; then
    echo -e "\n  ${DIM}$model_name already exported → $gguf_name — skipping.${RESET}"
    continue
  fi

  echo -e "\n  Exporting ${BOLD}$model_name${RESET} ($model_size)..."
  echo -e "  ${DIM}Source: $blob_path${RESET}"
  echo -e "  ${DIM}Dest:   $dest${RESET}"

  cp "$blob_path" "$dest"

  # Verify the copy
  echo -e "  Verifying..."
  dest_magic=$(xxd -l 4 -p "$dest" 2>/dev/null || echo "")
  if [ "$dest_magic" != "$GGUF_MAGIC" ]; then
    fail "Verification failed — GGUF magic bytes not found in $dest"
    rm -f "$dest"
    continue
  fi

  src_size_bytes=$(stat -f%z "$blob_path" 2>/dev/null || stat --printf="%s" "$blob_path" 2>/dev/null || echo "0")
  dest_size_bytes=$(stat -f%z "$dest" 2>/dev/null || stat --printf="%s" "$dest" 2>/dev/null || echo "0")
  if [ "$src_size_bytes" != "$dest_size_bytes" ]; then
    fail "Verification failed — size mismatch (source: $src_size_bytes, dest: $dest_size_bytes)"
    rm -f "$dest"
    continue
  fi

  ok "Verified: GGUF header valid, size matches ($model_size)"
  exported=$((exported + 1))
done

# ── Summary ──────────────────────────────────────────────────────────────────

echo -e "\n${BOLD}--- Summary ---${RESET}\n"

if [ "$exported" -gt 0 ]; then
  ok "$exported model(s) exported"
fi

echo -e "\n  GGUF files in ${CYAN}$OUTPUT_DIR${RESET}:\n"

gguf_total=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  fname=$(basename "$f")
  fsize=$(ls -lh "$f" | awk '{print $5}')
  echo -e "    ${GREEN}$fname${RESET}  ($fsize)"
  gguf_total=$((gguf_total + 1))
done < <(find "$OUTPUT_DIR" -maxdepth 1 -name '*.gguf' -type f 2>/dev/null | sort)

if [ "$gguf_total" -eq 0 ]; then
  echo -e "    ${DIM}(none)${RESET}"
fi

echo -e "\n  Total: $gguf_total GGUF file(s)"
if [ -L "$MODELS_LINK" ]; then
  echo -e "  Symlink: ~/.models → $(readlink "$MODELS_LINK")"
fi
echo ""
