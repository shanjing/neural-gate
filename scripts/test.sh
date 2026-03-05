curl -vvv -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Host: qwen3-1-7b.inference.local" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-1-7b","messages":[{"role":"user","content":"Say hello in one word."}]}'
