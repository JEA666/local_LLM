#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Stop any existing container
docker rm -f openwebui >/dev/null 2>&1 || true

mkdir -p "$DIR/openwebui-data"

docker network create local-llm-net >/dev/null 2>&1 || true

# NOTE on web-search env vars below: they only seed the setting the *first*
# time this container's data volume is initialized. Once openwebui writes a
# value to its DB (config table, key-per-row), the DB wins on every future
# recreate -- these env vars become no-ops after that. Change search settings
# via Admin Settings > Web Search in the UI (or edit the DB directly) once
# the volume already has data, not by editing this script.
#
# Reaches llm-server (a separate, already-running container on the default
# bridge network) via host-gateway rather than joining its network -- avoids
# touching that container at all. Reaches searxng via container-name DNS on
# the shared local-llm-net network instead -- searxng's host port is bound
# to 127.0.0.1 only (no auth of its own), so host-gateway can't reach it from
# another container; a shared user-defined network can.
docker run -d --name openwebui --restart unless-stopped \
  --network local-llm-net \
  --add-host=host.docker.internal:host-gateway \
  -e WEBUI_AUTH=False \
  -e OPENAI_API_BASE_URL=http://host.docker.internal:8080/v1 \
  -e OPENAI_API_KEY=sk-local \
  -e ENABLE_WEB_SEARCH=True \
  -e WEB_SEARCH_ENGINE=searxng \
  -e SEARXNG_QUERY_URL="http://searxng:8080/search?q=<query>" \
  -e WEB_SEARCH_RESULT_COUNT=3 \
  -e WEB_SEARCH_CONCURRENT_REQUESTS=5 \
  -v "$DIR/openwebui-data":/app/backend/data \
  -p 3000:8080 \
  ghcr.io/open-webui/open-webui:main

echo "openwebui started. UI at http://localhost:3000"
echo "Follow logs with: docker logs -f openwebui"
