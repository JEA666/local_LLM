#!/usr/bin/env bash
set -euo pipefail

# Reapplies config that lives only in openwebui's SQLite DB, not in
# compose.yml env vars. OpenWebUI's PersistentConfig pattern means an env
# var only seeds a value the *first* time that DB row is created -- after
# that, only editing the DB (or the Admin UI) takes effect. Needed after a
# fresh openwebui-data/ volume, or if any of these settings ever drift back
# to their defaults (or the underlying network topology changes and a
# stale seeded URL silently stops resolving).
#
# Usage: ./bootstrap-openwebui.sh [admin-password]
# Reads DOMAIN and MODEL_FILE from .env (see .env.example) -- run this from
# a stack that's already up with those set correctly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi
DOMAIN="${DOMAIN:-localhost}"
MODEL_FILE="${MODEL_FILE:?Set MODEL_FILE in .env -- see .env.example}"

fix_searxng_url() {
  echo "=== Fixing SearXNG query URL (PersistentConfig, env var only seeds fresh DB) ==="
  docker exec -i openwebui python3 <<'PYEOF'
import sqlite3
conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.cursor()
cur.execute(
    "UPDATE config SET value = ? WHERE key = 'web.search.searxng_query_url'",
    ('"http://searxng:8080/search?q=<query>"',),
)
conn.commit()
cur.execute("SELECT key, value FROM config WHERE key = 'web.search.searxng_query_url'")
print(cur.fetchall())
PYEOF
}

fix_llm_server_url() {
  echo "=== Fixing llm-server API base URL (PersistentConfig, env var only seeds fresh DB) ==="
  docker exec -i openwebui python3 <<'PYEOF'
import sqlite3
conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.cursor()
cur.execute(
    "UPDATE config SET value = ? WHERE key = 'openai.api_base_urls'",
    ('["http://llm-server:8080/v1"]',),
)
conn.commit()
cur.execute("SELECT key, value FROM config WHERE key = 'openai.api_base_urls'")
print(cur.fetchall())
PYEOF
}

set_function_calling_legacy() {
  local password="$1"
  echo "=== Forcing function_calling=legacy on the model (restores backend-driven web search) ==="
  # OpenWebUI only runs its own web-search handler when the model's
  # function_calling mode is 'legacy' -- if native tool-calling (--jinja) is
  # on, OpenWebUI expects the *model* to call a web_search tool itself
  # instead, which isn't wired up by default, so search silently no-ops.
  # Uses OpenWebUI's own API (not a raw SQL insert) so the row gets the
  # exact shape the app expects.
  local model_id="/models/$MODEL_FILE"
  local token
  token=$(curl -sk -X POST "https://$DOMAIN:3000/api/v1/auths/signin" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"admin@localhost\",\"password\":\"$password\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
  local body
  body=$(python3 -c "
import json
print(json.dumps({
    'id': '$model_id',
    'name': '$MODEL_FILE',
    'meta': {},
    'params': {'function_calling': 'legacy'},
    'is_active': True,
    # Upstream OpenWebUI bug: 'access_grants' defaults to None in the schema,
    # but /model/update re-validates the dumped form and requires a list --
    # omitting this (letting it default) causes a 500 on update (not create).
    'access_grants': [],
}))
")
  local status
  status=$(curl -sk -o /tmp/model-create.json -w '%{http_code}' -X POST \
    "https://$DOMAIN:3000/api/v1/models/create" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$body")
  if [[ "$status" != "200" ]]; then
    # Already exists -- update instead.
    curl -sk -X POST "https://$DOMAIN:3000/api/v1/models/model/update?id=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$model_id")" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$body" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print('updated:', d.get('params'))"
  else
    python3 -c "import json; d=json.load(open('/tmp/model-create.json')); print('created:', d.get('params'))"
  fi
}

set_admin_password() {
  local password="$1"
  echo "=== Setting admin@localhost password ==="
  docker exec -i -e BOOTSTRAP_PW="$password" openwebui python3 <<'PYEOF'
import os
import bcrypt
import sqlite3
pw = os.environ['BOOTSTRAP_PW']
h = bcrypt.hashpw(pw.encode(), bcrypt.gensalt()).decode()
conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.cursor()
cur.execute("UPDATE auth SET password = ? WHERE email = 'admin@localhost'", (h,))
conn.commit()
print('admin@localhost password set')
PYEOF
}

main() {
  local password="${1:?Usage: bootstrap-openwebui.sh <admin-password>}"
  fix_searxng_url
  fix_llm_server_url
  set_admin_password "$password"
  # Needs to log in over HTTP, so run last -- requires the password above
  # to already be correct and the container to be serving traffic.
  set_function_calling_legacy "$password"
  echo ""
  echo "Done. If search or chat doesn't work immediately: docker restart openwebui"
}

main "$@"
