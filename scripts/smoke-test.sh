#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${ENDPOINT:-http://inference.local}"

echo "=== Smoke Test ==="

echo "--- Health check ---"
curl -sf "$ENDPOINT/v1/models" | python3 -m json.tool
echo

echo "--- Chat completion ---"
curl -sf "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen-8b","messages":[{"role":"user","content":"hello"}],"max_tokens":32}' \
  | python3 -m json.tool
echo

echo "=== All checks passed ==="
