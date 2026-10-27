#!/usr/bin/env bash
# ==============================================================================
# Provision an OmniRoute client API key and write it to .env as GTW_API_KEY.
#
# Why this exists: OmniRoute's /v1 endpoint rejects any bearer token that does
# not exist in its own database, even with REQUIRE_API_KEY=false. The shipped
# GTW_API_KEY=omniroute-local is a placeholder, so a fresh stack always 401s
# until someone clicks through Dashboard -> Endpoints. This does it over the
# same HTTP API the dashboard uses, so `make up` can reach a working state
# without a browser.
#
# It does NOT create provider connections. Keyless ("noauth") providers need
# none; anything with a credential or OAuth flow still has to be done by hand
# in the dashboard.
#
# Usage: make omniroute-key
# ==============================================================================
set -euo pipefail

PORT="${OMNIROUTE_PORT:-20128}"
BASE="http://localhost:${PORT}"
PASSWORD="${OMNIROUTE_INITIAL_PASSWORD:-omniroute-admin}"
KEY_NAME="${OMNIROUTE_KEY_NAME:-hermes-course}"
ENV_FILE="${ENV_FILE:-.env}"

COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT

if ! curl -fsS -o /dev/null "${BASE}/v1/auto-combo/chat/candidates"; then
  echo "omniroute-provision: cannot reach ${BASE}" >&2
  echo "  Is the gateway up?  docker compose ps omniroute" >&2
  exit 1
fi

echo "Logging in to ${BASE} ..."
if ! curl -fsS -c "$COOKIE" -X POST "${BASE}/api/auth/login" \
      -H 'Content-Type: application/json' \
      -d "{\"password\":$(printf '%s' "$PASSWORD" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}" \
      -o /dev/null; then
  echo "omniroute-provision: login failed." >&2
  echo "  OMNIROUTE_INITIAL_PASSWORD only seeds the password on FIRST boot." >&2
  echo "  If you changed it in the dashboard, set the real one in .env." >&2
  exit 1
fi

# Does a bearer token actually work against /v1? The listing endpoint returns
# MASKED key values when allowKeyReveal is false (the default), so a value read
# back from /api/keys is usually a truncated prefix that 401s. Never trust a
# key we did not just mint -- verify it.
key_works() {
  [ -n "$1" ] || return 1
  curl -fsS -o /dev/null -H "Authorization: Bearer $1" "${BASE}/v1/models" 2>/dev/null
}

KEY=""

# 1) If .env already holds a working key, keep it: re-minting on every run
#    would invalidate nothing but would churn .env and confuse the demo.
current="$(grep -m1 '^GTW_API_KEY=' "${ENV_FILE:-.env}" 2>/dev/null | cut -d= -f2- || true)"
if [ -n "$current" ] && [ "$current" != "omniroute-local" ] && key_works "$current"; then
  echo "Existing GTW_API_KEY in ${ENV_FILE} already works; nothing to do."
  exit 0
fi

# 2) Try reusing a listed key of this name, but only if it verifies.
existing="$(curl -fsS -b "$COOKIE" "${BASE}/api/keys" || echo '{}')"
candidate="$(KEY_NAME="$KEY_NAME" printf '%s' "$existing" | KEY_NAME="$KEY_NAME" python3 -c '
import json,os,sys
try: d=json.load(sys.stdin)
except Exception: d={}
name=os.environ.get("KEY_NAME","hermes-course")
for k in d.get("keys",[]):
    if k.get("name")==name and k.get("key"):
        print(k["key"]); break
' 2>/dev/null || true)"

if key_works "$candidate"; then
  KEY="$candidate"
  echo "Reusing existing key named '${KEY_NAME}'."
else
  [ -n "$candidate" ] && echo "A key named '${KEY_NAME}' exists but its secret is masked (allowKeyReveal=false); minting a new one."
  echo "Creating API key '${KEY_NAME}' ..."
  resp="$(curl -fsS -b "$COOKIE" -X POST "${BASE}/api/keys" \
      -H 'Content-Type: application/json' \
      -d "{\"name\":\"${KEY_NAME}\"}")"
  KEY="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("key",""))')"
  if [ -z "$KEY" ]; then
    echo "omniroute-provision: no key in response:" >&2
    printf '%s\n' "$resp" >&2
    exit 1
  fi
  if ! key_works "$KEY"; then
    echo "omniroute-provision: the freshly minted key still fails against /v1/models." >&2
    echo "  Check 'docker compose logs omniroute'." >&2
    exit 1
  fi
fi

# Write GTW_API_KEY into .env without disturbing anything else.
if [ ! -f "$ENV_FILE" ]; then
  echo "omniroute-provision: $ENV_FILE not found (run 'make setup-dirs')" >&2
  exit 1
fi
cp "$ENV_FILE" "${ENV_FILE}.bak-$(date +%Y%m%d%H%M%S)"
if grep -q '^GTW_API_KEY=' "$ENV_FILE"; then
  # Use a python rewrite rather than sed -i: the key can contain characters
  # that sed would treat as delimiters or backreferences.
  KEY="$KEY" ENV_FILE="$ENV_FILE" python3 - <<'PY'
import os
p=os.environ["ENV_FILE"]; key=os.environ["KEY"]
out=[]
for line in open(p,encoding="utf-8"):
    out.append(f"GTW_API_KEY={key}\n" if line.startswith("GTW_API_KEY=") else line)
open(p,"w",encoding="utf-8").writelines(out)
PY
else
  printf '\nGTW_API_KEY=%s\n' "$KEY" >> "$ENV_FILE"
fi

echo "Wrote GTW_API_KEY to $ENV_FILE (value not printed; backup kept)."
echo
echo "Next:"
echo "  make restart            # Hermes + Hindsight pick up the new key"
echo "  make omniroute-models   # expect HTTP 200"
echo "  make free-combos        # see which keyless models are reachable"
