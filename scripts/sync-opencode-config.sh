#!/usr/bin/env bash
set -euo pipefail

# sync-opencode-config.sh -- updates OpenCode's model config to match
# whichever .gguf is currently active in .env's MODEL_FILE, after switching
# models via the admin panel (or by hand).
#
# Runs on THIS machine, not in any container -- OpenCode's config lives in
# the operator's own home directory, not the project, so this is a
# deliberate pull/apply step the operator runs themselves rather than
# something a container reaches into a host user's home directory and
# rewrites automatically. Matches this project's existing template+script
# pattern (.env.example -> .env, Caddyfile.example -> Caddyfile via
# generate-local-ca.sh) and fmt/gitops/principles.md's "pulled not pushed,
# reconciled" principle -- and this exact file drifted stale once already
# this project's life and got fixed by hand, not by any push mechanism.
#
# Only edits the config's top-level `model` key and one model entry under
# the configured provider -- everything else (instructions, compaction,
# disabled_providers, other providers/models already listed) is left
# untouched. Does NOT create the config file, or the provider block within
# it, from scratch -- if either is missing, this exits with an error
# rather than guessing at settings (npm package, baseURL) it has no real
# way to know are correct.
#
# Usage: ./sync-opencode-config.sh
# Reads MODEL_FILE from .env (see .env.example). Override the provider key
# or config path via OPENCODE_PROVIDER / OPENCODE_CONFIG env vars if yours
# differ from the defaults below.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
OPENCODE_PROVIDER="${OPENCODE_PROVIDER:-local-llama}"

if ! command -v opencode >/dev/null 2>&1; then
  echo "OpenCode not found on this machine (no 'opencode' on PATH) -- skipping."
  exit 0
fi
if [[ ! -f "$OPENCODE_CONFIG" ]]; then
  echo "No OpenCode config at $OPENCODE_CONFIG -- skipping (won't create one from scratch)."
  exit 0
fi

ENV_FILE="$DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi
MODEL_FILE="${MODEL_FILE:?Set MODEL_FILE in .env -- see .env.example}"

OPENCODE_CONFIG="$OPENCODE_CONFIG" OPENCODE_PROVIDER="$OPENCODE_PROVIDER" MODEL_FILE="$MODEL_FILE" python3 <<'PYEOF'
import json
import os
import re
import sys

config_path = os.environ['OPENCODE_CONFIG']
provider = os.environ['OPENCODE_PROVIDER']
model_file = os.environ['MODEL_FILE']

stem = re.sub(r'\.gguf$', '', model_file, flags=re.IGNORECASE)
# Fixed, stable keys (not derived from the exact filename/quantization/
# version) so switching between different builds of "the instruct model"
# keeps updating the same entry instead of accumulating a new one per
# filename -- there are only two logical slots that matter here (whichever
# instruct model is active, whichever coder model is active), not one per
# exact .gguf ever used.
is_coder = 'coder' in stem.lower()
key = 'coder' if is_coder else 'instruct'
label = 'Coder' if is_coder else 'Instruct'
display_name = f'{stem} ({label}, hybrid)'

with open(config_path) as f:
    config = json.load(f)

providers = config.get('provider', {})

# Reuse an existing model entry if one already looks like it's for the
# same profile (e.g. a human-created "qwen3-30b-a3b-instruct" from before
# this script existed) instead of creating a second, differently-keyed
# entry for the same logical slot -- only fall back to the plain
# 'instruct'/'coder' key if nothing already matches.
existing_models = providers.get(provider, {}).get('models', {})
for existing_key in existing_models:
    existing_is_coder = 'coder' in existing_key.lower()
    if existing_is_coder == is_coder:
        key = existing_key
        break

if provider not in providers or 'options' not in providers.get(provider, {}):
    print(
        f'Provider "{provider}" not found (or missing options) in {config_path} -- '
        f'add its base connection config (npm, options.baseURL) yourself first, '
        f'this script only adds/updates one model entry under an already-configured '
        f'provider, it will not guess connection settings.',
        file=sys.stderr,
    )
    sys.exit(1)

config['model'] = f'{provider}/{key}'
providers[provider].setdefault('models', {})[key] = {
    'name': display_name,
    'tool_call': True,
    'limit': {'context': 32768, 'output': 8192},
}

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')

print(f'Updated {config_path}')
print(f'  model = {provider}/{key}')
print(f'  name  = {display_name}')
PYEOF
