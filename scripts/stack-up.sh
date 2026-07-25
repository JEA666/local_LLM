#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$DIR/deployments/compose.yml"

mkdir -p "$DIR/models" "$DIR/openwebui-data" "$DIR/searxng"
docker network create local-llm-net >/dev/null 2>&1 || true

# Remove any standalone (non-compose) containers left over from the old
# per-service *-run.sh scripts -- compose refuses to create a container
# whose name is already taken by one it doesn't manage.
for c in llm-server searxng openwebui; do
  if docker inspect "$c" >/dev/null 2>&1 && \
     [[ -z "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c")" ]]; then
    docker rm -f "$c" >/dev/null
  fi
done

docker compose --project-directory "$DIR" -f "$COMPOSE_FILE" up -d --wait

echo ""
docker compose --project-directory "$DIR" -f "$COMPOSE_FILE" ps
echo ""
echo "OpenWebUI: http://localhost:3000"
