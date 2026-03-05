#!/usr/bin/env bash
# competitions.sh — Benchmark neural-gate (port-forward) vs Ollama on the same models (Qwen3 1.7B, 8B).
# Usage: ensure port-forwards are running, then run ./scripts/competitions.sh
#   kubectl port-forward -n inference svc/qwen3-1-7b-predictor 8081:80
#   kubectl port-forward -n inference svc/qwen3-8b-predictor 8082:80
set -euo pipefail

# Neural-gate: port-forwarded predictor URLs (one port per model)
NEURAL_GATE_1_7B_URL="${NEURAL_GATE_1_7B_URL:-http://127.0.0.1:8081}"
NEURAL_GATE_8B_URL="${NEURAL_GATE_8B_URL:-http://127.0.0.1:8082}"
# Ollama
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

# Same prompt for all runs (short, deterministic-ish)
PROMPT="${PROMPT:-Say hello in one word.}"
MAX_TOKENS="${MAX_TOKENS:-64}"
RUNS="${RUNS:-3}"

# Model names: neural-gate uses k8s-style names; Ollama uses repo:tag
NG_MODEL_1_7B="qwen3-1-7b"
NG_MODEL_8B="qwen3-8b"
OLLAMA_MODEL_1_7B="qwen3:1.7b"
OLLAMA_MODEL_8B="qwen3:8b"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Run one chat completion, print elapsed seconds and completion_tokens (one line: "seconds tokens").
# On failure prints "0 0" so script does not exit.
run_one() {
  local url model
  url="$1"
  model="$2"
  local tmp
  tmp=$(mktemp)
  trap "rm -f '$tmp'" RETURN
  if ! time_total=$(curl -sf -w "%{time_total}" -o "$tmp" -m 120 -X POST "${url}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PROMPT}\"}],\"max_tokens\":${MAX_TOKENS}}"); then
    echo "0 0"
    return 0
  fi
  tokens=$(python3 -c "
import json
try:
    with open(\"$tmp\") as f:
        d = json.load(f)
    print(d.get('usage', {}).get('completion_tokens', 0))
except Exception:
    print(0)
" 2>/dev/null || echo "0")
  echo "$time_total $tokens"
}

# Run $RUNS requests and report avg time, avg tokens, tok/s. Prints two lines: human summary, then "avg_time avg_tok tok_per_s".
benchmark() {
  local label url model
  label="$1"
  url="$2"
  model="$3"
  local i sum_time sum_tokens result t tok
  sum_time=0
  sum_tokens=0
  for i in $(seq 1 "$RUNS"); do
    result=$(run_one "$url" "$model")
    t=$(echo "$result" | awk '{print $1}')
    tok=$(echo "$result" | awk '{print $2}')
    sum_time=$(python3 -c "print($sum_time + $t)")
    sum_tokens=$(python3 -c "print($sum_tokens + $tok)")
  done
  local avg_time avg_tok tok_per_s
  avg_time=$(python3 -c "print(round($sum_time / $RUNS, 2))")
  avg_tok=$(python3 -c "print(int($sum_tokens / $RUNS))")
  tok_per_s=$(python3 -c "print(round($avg_tok / $avg_time, 1) if $avg_time > 0 else 0)")
  echo "  ${label}: ${avg_time}s avg, ${avg_tok} tok/req → ${tok_per_s} tok/s"
  echo "$avg_time $avg_tok $tok_per_s"
}

echo -e "${BOLD}=== neural-gate vs Ollama (Qwen3 1.7B & 8B) ===${RESET}"
echo "Prompt: \"${PROMPT}\" | max_tokens: ${MAX_TOKENS} | runs: ${RUNS}"
echo

# Check Ollama is reachable
if ! curl -sf -m 2 "${OLLAMA_URL}/api/tags" >/dev/null 2>&1; then
  echo -e "${YELLOW}Warning: Ollama not reachable at ${OLLAMA_URL}. Start with: ollama serve${RESET}"
fi

# --- Qwen3 1.7B ---
echo -e "${CYAN}--- Qwen3 1.7B ---${RESET}"
ng_1_7b=""
if curl -sf -m 2 -o /dev/null "${NEURAL_GATE_1_7B_URL}/health" 2>/dev/null || curl -sf -m 2 -o /dev/null "${NEURAL_GATE_1_7B_URL}/v1/models" 2>/dev/null; then
  full=$(benchmark "neural-gate (port-forward)" "$NEURAL_GATE_1_7B_URL" "$NG_MODEL_1_7B")
  echo "$full" | sed '$d'
  ng_1_7b=$(echo "$full" | tail -1)
else
  echo -e "  ${RED}neural-gate 1.7B: not reachable at ${NEURAL_GATE_1_7B_URL} (start port-forward?)${RESET}"
fi
ollama_1_7b=""
full=$(benchmark "Ollama" "$OLLAMA_URL" "$OLLAMA_MODEL_1_7B") || true
if echo "$full" | grep -q '^[0-9]'; then
  echo "$full" | sed '$d'
  last=$(echo "$full" | tail -1)
  # All-zero line means requests failed (e.g. model not pulled)
  if [[ "$last" != "0 0 0" ]] && [[ -n "$last" ]]; then
    ollama_1_7b="$last"
  else
    echo -e "  ${RED}Ollama ${OLLAMA_MODEL_1_7B}: not available (ollama pull ${OLLAMA_MODEL_1_7B})${RESET}"
  fi
else
  echo -e "  ${RED}Ollama ${OLLAMA_MODEL_1_7B}: not available (ollama pull ${OLLAMA_MODEL_1_7B})${RESET}"
fi

echo

# --- Qwen3 8B ---
echo -e "${CYAN}--- Qwen3 8B ---${RESET}"
ng_8b=""
if curl -sf -m 2 -o /dev/null "${NEURAL_GATE_8B_URL}/health" 2>/dev/null || curl -sf -m 2 -o /dev/null "${NEURAL_GATE_8B_URL}/v1/models" 2>/dev/null; then
  full=$(benchmark "neural-gate (port-forward)" "$NEURAL_GATE_8B_URL" "$NG_MODEL_8B")
  echo "$full" | sed '$d'
  ng_8b=$(echo "$full" | tail -1)
else
  echo -e "  ${RED}neural-gate 8B: not reachable at ${NEURAL_GATE_8B_URL} (start port-forward?)${RESET}"
fi
ollama_8b=""
full=$(benchmark "Ollama" "$OLLAMA_URL" "$OLLAMA_MODEL_8B") || true
if echo "$full" | grep -q '^[0-9]'; then
  echo "$full" | sed '$d'
  last=$(echo "$full" | tail -1)
  if [[ "$last" != "0 0 0" ]] && [[ -n "$last" ]]; then
    ollama_8b="$last"
  else
    echo -e "  ${RED}Ollama ${OLLAMA_MODEL_8B}: not available (ollama pull ${OLLAMA_MODEL_8B})${RESET}"
  fi
else
  echo -e "  ${RED}Ollama ${OLLAMA_MODEL_8B}: not available (ollama pull ${OLLAMA_MODEL_8B})${RESET}"
fi

echo
echo -e "${BOLD}--- Summary (avg time, tok/req, tok/s) ---${RESET}"
printf "%-12s %-28s %-28s\n" "Model" "neural-gate" "Ollama"
printf "%-12s %-28s %-28s\n" "------" "----------------------------" "----------------------------"
if [[ -n "$ng_1_7b" ]]; then
  ng_1_7b_t=$(echo "$ng_1_7b" | awk '{print $1}')
  ng_1_7b_tok=$(echo "$ng_1_7b" | awk '{print $2}')
  ng_1_7b_s=$(echo "$ng_1_7b" | awk '{print $3}')
  ng1=$(printf "%.2fs, %s tok → %s tok/s" "$ng_1_7b_t" "$ng_1_7b_tok" "$ng_1_7b_s")
else
  ng1="—"
fi
if [[ -n "$ollama_1_7b" ]]; then
  o_1_7b_t=$(echo "$ollama_1_7b" | awk '{print $1}')
  o_1_7b_tok=$(echo "$ollama_1_7b" | awk '{print $2}')
  o_1_7b_s=$(echo "$ollama_1_7b" | awk '{print $3}')
  o1=$(printf "%.2fs, %s tok → %s tok/s" "$o_1_7b_t" "$o_1_7b_tok" "$o_1_7b_s")
else
  o1="—"
fi
printf "%-12s %-28s %-28s\n" "Qwen3 1.7B" "$ng1" "$o1"

if [[ -n "$ng_8b" ]]; then
  ng_8b_t=$(echo "$ng_8b" | awk '{print $1}')
  ng_8b_tok=$(echo "$ng_8b" | awk '{print $2}')
  ng_8b_s=$(echo "$ng_8b" | awk '{print $3}')
  ng2=$(printf "%.2fs, %s tok → %s tok/s" "$ng_8b_t" "$ng_8b_tok" "$ng_8b_s")
else
  ng2="—"
fi
if [[ -n "$ollama_8b" ]]; then
  o_8b_t=$(echo "$ollama_8b" | awk '{print $1}')
  o_8b_tok=$(echo "$ollama_8b" | awk '{print $2}')
  o_8b_s=$(echo "$ollama_8b" | awk '{print $3}')
  o2=$(printf "%.2fs, %s tok → %s tok/s" "$o_8b_t" "$o_8b_tok" "$o_8b_s")
else
  o2="—"
fi
printf "%-12s %-28s %-28s\n" "Qwen3 8B" "$ng2" "$o2"
echo
echo "Port-forwards: kubectl port-forward -n inference svc/qwen3-1-7b-predictor 8081:80 (and 8082 for 8B)."
