#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${ENDPOINT:-http://inference.local}"
MODEL="${MODEL:-qwen-8b}"
CONCURRENCY="${CONCURRENCY:-4}"
REQUESTS="${REQUESTS:-20}"
PROMPT="Write a short paragraph about distributed systems."

echo "=== Throughput Benchmark ==="
echo "Model: $MODEL | Concurrency: $CONCURRENCY | Requests: $REQUESTS"
echo

run_request() {
  local start end elapsed
  start=$(python3 -c "import time; print(time.time())")
  response=$(curl -sf "$ENDPOINT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT\"}],\"max_tokens\":256}")
  end=$(python3 -c "import time; print(time.time())")
  tokens=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])")
  elapsed=$(python3 -c "print(round($end - $start, 2))")
  echo "  ${elapsed}s | ${tokens} tokens | $(python3 -c "print(round($tokens / ($end - $start), 1))") tok/s"
}

for i in $(seq 1 "$REQUESTS"); do
  run_request &
  [ $((i % CONCURRENCY)) -eq 0 ] && wait
done
wait

echo
echo "=== Benchmark complete ==="
