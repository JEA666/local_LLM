# LLM API access

`llm-server` exposes an OpenAI-compatible API (llama.cpp's built-in server), reachable from any device on the network if you're using the Caddy/TLS setup, or `http://localhost:8080/v1` for local-only access:

```
https://<your-domain>:8080/v1
```

Replace `<your-domain>` with whatever you set `DOMAIN` to in `.env` (see [`scripts/generate-local-ca.sh`](../scripts/generate-local-ca.sh) and `README.md` "Custom domain + HTTPS").

No API key is required — llama.cpp's server doesn't check it, but most OpenAI-compatible clients require a non-empty value, so pass any placeholder string (e.g. `sk-local`).

Model name: whatever `MODEL_FILE` is set to in `.env`, without the `.gguf` extension is a reasonable convention but llama.cpp accepts any string here.

## Example

```bash
curl https://<your-domain>:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-name",
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

Works with any OpenAI-compatible client/SDK by pointing its base URL at the address above.

## Context and performance

Context window is whatever `CONTEXT_SIZE` is set to in `.env`. Actual throughput depends heavily on your hardware and how well you've tuned CPU/GPU behavior for it — see `README.md` "Tuning" for the general lessons (this project's own hardware-specific tuning setup, for one real machine, is documented as a separate reference elsewhere and isn't required reading to use this stack).
