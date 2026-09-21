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
SEARXNG_LANGUAGE="${SEARXNG_LANGUAGE:-all}"
OPENWEBUI_ADMIN_EMAIL="${OPENWEBUI_ADMIN_EMAIL:-admin@localhost}"

fix_searxng_url() {
  echo "=== Fixing SearXNG query URL (PersistentConfig, env var only seeds fresh DB) ==="
  # Must go through Caddy's public route, NOT directly to searxng:8080 --
  # SearXNG's server.base_url (searxng/settings.yml) makes its
  # ReverseProxyPathFix middleware unconditionally force every request's
  # Host/scheme to base_url's, so a direct container-to-container call gets
  # 308-redirected to this exact URL anyway (confirmed via searx/flaskfix.py
  # and a live request trace, 2026-07-27) -- going direct just adds a
  # pointless failed hop first (and fails outright unless the caller also
  # trusts the private CA for that redirect, which is why openwebui gets
  # SSL_CERT_FILE in compose.yml).
  docker exec -i -e DOMAIN="$DOMAIN" openwebui python3 <<'PYEOF'
import os, sqlite3
url = f'"https://{os.environ["DOMAIN"]}/search/search?q=<query>"'
conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.cursor()
cur.execute(
    "UPDATE config SET value = ? WHERE key = 'web.search.searxng_query_url'",
    (url,),
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

fix_search_query_language() {
  echo "=== Fixing search-query generation to keep the user's own language (PersistentConfig) ==="
  # deployments/compose.yml seeds this correctly via QUERY_GENERATION_PROMPT_
  # TEMPLATE/SEARXNG_LANGUAGE now (same content as below) -- this function is
  # the drift-repair path for a DB that already exists with the old/default
  # values, per this file's header comment, not the primary seed anymore.
  #
  # OpenWebUI's own default query-generation prompt (used to turn a chat
  # message into 1-3 search queries) says "in the given language" but is
  # itself entirely in English -- observed live (2026-07-27) that Qwen3
  # would silently translate a Norwegian question into English search
  # queries, losing locale-specific intent ("en norsk webbutikk" -> generic
  # English query), which then pulled in US retailer results instead of
  # Norwegian ones for this deployment. Custom template makes the
  # language-preservation instruction explicit and first. Also biases
  # SearXNG's own language param -- set SEARXNG_LANGUAGE in .env (an ISO
  # code like "no", or leave at the default "all") -- since this project
  # stays generic/portable, nothing Norway-specific is hardcoded here.
  docker exec -i -e SEARXNG_LANGUAGE="$SEARXNG_LANGUAGE" openwebui python3 <<'PYEOF'
import json, os, sqlite3

template = """### Task:
Analyze the chat history to determine the necessity of generating search queries, in the SAME language the user is writing in -- do not translate the query into English or any other language. If the user mentions a country, region, store, or brand, keep that term in the query exactly. By default, prioritize generating 1-3 broad and relevant search queries unless it is absolutely certain that no additional information is required.

### Guidelines:
- Respond EXCLUSIVELY with a JSON object. Any form of extra commentary, explanation, or additional text is strictly prohibited.
- When generating search queries, respond in the format: { "queries": ["query1", "query2"] }, ensuring each query is distinct, concise, and relevant to the topic.
- If and only if it is entirely certain that no useful results can be retrieved by a search, return: { "queries": [] }.
- Err on the side of suggesting search queries if there is any chance they might provide useful or updated information.
- Today is: {{CURRENT_DATE}}.

### Output:
Strictly return in JSON format:
{
  "queries": ["query1", "query2"]
}

### Chat History:
<chat_history>
{{MESSAGES:END:6}}
</chat_history>
"""

conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.cursor()
cur.execute(
    "UPDATE config SET value = ? WHERE key = 'task.query.prompt_template'",
    (json.dumps(template),),
)
cur.execute(
    "UPDATE config SET value = ? WHERE key = 'web.search.searxng_language'",
    (json.dumps(os.environ['SEARXNG_LANGUAGE']),),
)
conn.commit()
cur.execute("SELECT key, length(value) FROM config WHERE key = 'task.query.prompt_template'")
print(cur.fetchall())
cur.execute("SELECT key, value FROM config WHERE key = 'web.search.searxng_language'")
print(cur.fetchall())
PYEOF
}

fix_search_breadth() {
  echo "=== Widening search/retrieval breadth (PersistentConfig) ==="
  # Defaults (result_count=3, top_k=3) turned out too narrow for anything
  # beyond a single fact lookup -- confirmed live (2026-07-27): "compare
  # prices across ~5 stores" structurally can't work when only 3 pages
  # ever get fetched and only 3 chunks ever reach the model's context
  # (frequently all from the same one page). First raised to 8/10 -- still
  # too narrow. Checked SearXNG directly for a real query: 75 raw hits, 21
  # unique domains, ~19 genuinely relevant Norwegian retailers -- raised to
  # 20/20 to actually capture that real pool instead of discarding most of
  # it. Matches WEB_SEARCH_RESULT_COUNT/RAG_TOP_K/RAG_TOP_K_RERANKER/
  # CHUNK_SIZE/CHUNK_OVERLAP in compose.yml -- all places need it since the
  # env vars only seed a *fresh* DB (see header comment). chunk_size also
  # widened: default 1000 splits dense e-commerce listing pages into many
  # near-identical tiny chunks, none individually distinctive enough to
  # rank in the top-K for a broad query -- confirmed live a page with real
  # embedded prices (verified via direct fetch) still didn't surface them
  # until chunks were widened enough to keep a product block and its price
  # together.
  docker exec -i openwebui python3 <<'PYEOF'
import sqlite3
conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.cursor()
cur.execute("UPDATE config SET value = '20' WHERE key = 'web.search.result_count'")
cur.execute("UPDATE config SET value = '20' WHERE key = 'rag.top_k'")
cur.execute("UPDATE config SET value = '20' WHERE key = 'rag.top_k_reranker'")
cur.execute("UPDATE config SET value = '3000' WHERE key = 'rag.chunk_size'")
cur.execute("UPDATE config SET value = '300' WHERE key = 'rag.chunk_overlap'")
conn.commit()
cur.execute("SELECT key, value FROM config WHERE key IN ('web.search.result_count','rag.top_k','rag.top_k_reranker','rag.chunk_size','rag.chunk_overlap')")
print(cur.fetchall())
PYEOF
}

fix_rag_template_denial() {
  echo "=== Fixing RAG template so the model stops denying it can search (PersistentConfig) ==="
  # deployments/compose.yml seeds this correctly via RAG_TEMPLATE now (same
  # content as below) -- this function is the drift-repair path for a DB
  # that already exists with the old/default value, not the primary seed.
  #
  # Observed live (2026-07-27): a fresh web search genuinely ran (confirmed
  # via openwebui logs -- real pages fetched, real chunks embedded) but the
  # model still replied "jeg kan ikke utfore nye websok" (I cannot perform
  # new web searches). Root cause: the default rag.template calls the
  # injected content generic "provided context" with no indication it's the
  # result of a search just performed for this exact message -- the model
  # falls back on its generic "I can't browse the web" training instinct
  # instead of recognizing the context it was just handed. This template
  # states that explicitly and forbids the denial outright. Also adds an
  # anti-fabrication + domain-attribution clause: observed live that the
  # model would blend real retrieved content with remembered store names,
  # and separately invent a plausible-looking-but-nonexistent domain when
  # told to "always cite a store" -- requiring the literal source domain
  # per claim (not a free-text company name) makes fabricated claims
  # checkable rather than just prohibited by instruction.
  docker exec -i openwebui python3 <<'PYEOF'
import json, sqlite3

template = """### Task:
Respond to the user query using ONLY the provided context below, incorporating inline citations in the format [id] **only when the <source> tag includes an explicit id attribute** (e.g., <source id="1">).

### Critical guideline:
The <context> below is the result of a REAL, live web search performed automatically for this exact message, just now -- it is NOT your training data and NOT a hypothetical. Never say you "cannot search the web" or "cannot fetch new information" when a <context> block is present -- that is always false when this template is in use; the search already happened.
Never mention a specific store, retailer, brand, product, or price that does not literally appear in the <context> below, even if you recognize the name from your own training. Do not fill gaps with remembered stores or well-known retailers -- if the context only covers 2 stores, discuss only those 2; do not pad the answer with others you merely recall. If a detail (like a price, or a 5th store) genuinely isn't present anywhere in the context, say plainly that it wasn't found in the pages retrieved -- do not substitute your own general knowledge to fill the gap, and do not suggest websites you have not actually seen search results from.

### Source attribution (critical):
When stating a price, product, or claim, you MUST attribute it to the exact source it came from using its [id] citation -- never blend facts from two different sources into one attributed claim, and never state a company/store name that does not match the <source> tag's actual domain for that [id]. In any table, include a column with the literal domain (e.g. skyt.no, vapensmia.no) the row's data came from, taken directly from the <source> tag -- not a nicer-sounding company name you infer or recall. This lets the user judge the source's legitimacy themselves; do not omit, prettify, or substitute it.

### Guidelines:
- If the answer is in the context, state it directly and confidently, citing the source.
- If uncertain, ask the user for clarification.
- Respond in the same language as the user's query.
- If the context is unreadable or of poor quality, inform the user and provide the best possible answer from what IS readable.
- **Only include inline citations using [id] (e.g., [1], [2]) when the <source> tag includes an id attribute.**
- Do not cite if the <source> tag does not contain an id attribute.
- Do not use XML tags in your response.
- Ensure citations are concise and directly related to the information provided.

### Example of Citation:
If the user asks about a specific topic and the information is found in a source with a provided id attribute, the response should include the citation like in the following example:
* "According to the study, the proposed method increases efficiency by 20% [1]."

### Output:
Provide a clear and direct response to the user's query, including inline citations in the format [id] only when the <source> tag with id attribute is present in the context. Never introduce a store, price, or product not literally present in <context>. In tables, always include the real source domain per row.

<context>
{{CONTEXT}}
</context>
"""

conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.cursor()
cur.execute(
    "UPDATE config SET value = ? WHERE key = 'rag.template'",
    (json.dumps(template),),
)
conn.commit()
cur.execute("SELECT key, length(value) FROM config WHERE key = 'rag.template'")
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
  #
  # TWO INDEPENDENT IMPLEMENTATIONS OF THE SAME API CONTRACT, NOT ONE SHARED
  # ONE: admin/main.go's syncOpenWebUIModel hits the same endpoints
  # (/auths/signin, /models/create, /models/model/update) with the same body
  # shape, including the same access_grants:[] workaround. Nothing enforces
  # they stay identical -- if OpenWebUI's API contract ever changes, update
  # BOTH places or they'll silently disagree.
  local model_id="/models/$MODEL_FILE"
  local token
  token=$(curl -sk -X POST "https://$DOMAIN:3000/api/v1/auths/signin" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$OPENWEBUI_ADMIN_EMAIL\",\"password\":\"$password\"}" \
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
  echo "=== Setting $OPENWEBUI_ADMIN_EMAIL password ==="
  docker exec -i -e BOOTSTRAP_PW="$password" -e BOOTSTRAP_EMAIL="$OPENWEBUI_ADMIN_EMAIL" openwebui python3 <<'PYEOF'
import os
import bcrypt
import sqlite3
pw = os.environ['BOOTSTRAP_PW']
email = os.environ['BOOTSTRAP_EMAIL']
h = bcrypt.hashpw(pw.encode(), bcrypt.gensalt()).decode()
conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.cursor()
cur.execute("UPDATE auth SET password = ? WHERE email = ?", (h, email))
conn.commit()
print(f'{email} password set')
PYEOF
}

main() {
  local password="${1:?Usage: bootstrap-openwebui.sh <admin-password>}"
  fix_searxng_url
  fix_llm_server_url
  fix_search_query_language
  fix_search_breadth
  fix_rag_template_denial
  set_admin_password "$password"
  # Needs to log in over HTTP, so run last -- requires the password above
  # to already be correct and the container to be serving traffic.
  set_function_calling_legacy "$password"
  echo ""
  echo "Done. If search or chat doesn't work immediately: docker restart openwebui"
}

main "$@"
