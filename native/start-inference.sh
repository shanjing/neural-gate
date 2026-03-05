#!/usr/bin/env bash
set -euo pipefail

MODEL="${MODEL:-$HOME/models/qwen2.5-8b-instruct-q4_k_m.gguf}"
PORT="${PORT:-8000}"
CTX_SIZE="${CTX_SIZE:-4096}"

exec mlx_lm.server \
  --model "$MODEL" \
  --host 0.0.0.0 \
  --port "$PORT"
