#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

docker rm -f searxng >/dev/null 2>&1 || true

# JSON API only for openwebui's web-search feature -- no UI of its own is
# needed, and it has no auth, so bind to localhost only (127.0.0.1), never
# 0.0.0.0.
docker run -d --name searxng --restart unless-stopped \
  -v "$DIR/searxng":/etc/searxng \
  -p 127.0.0.1:8081:8080 \
  searxng/searxng:latest

echo "searxng started. JSON API at http://localhost:8081/search?q=test&format=json"
