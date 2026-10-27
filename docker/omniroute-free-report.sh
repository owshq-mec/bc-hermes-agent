#!/usr/bin/env bash
# ==============================================================================
# Report what OmniRoute's FREE / keyless routing can actually reach, and
# optionally send a real completion through it.
#
#   ./docker/omniroute-free-report.sh            # report only
#   ./docker/omniroute-free-report.sh --test     # also POST a completion
#
# Background: "auto/*" model IDs are routing chains. A ":free" tier suffix (and
# the auto/best-free variant) filters the candidate pool to free targets, but
# the filter is FAIL-OPEN -- if nothing matches, the FULL pool is used. So a
# ":free" model string expresses a preference, not a cost guarantee.
# ==============================================================================
set -uo pipefail

PORT="${OMNIROUTE_PORT:-20128}"
BASE="http://localhost:${PORT}"
KEY="${GTW_API_KEY:-omniroute-local}"
MODEL="${FREE_MODEL:-auto/best-free}"

echo "=== Keyless candidate pool (no credential required) ==="
cands="$(curl -fsS "${BASE}/v1/auto-combo/chat/candidates" 2>/dev/null)"
if [ -z "$cands" ]; then
  echo "  UNREACHABLE at ${BASE} - is the gateway up? (docker compose ps omniroute)"
  exit 1
fi
printf '%s' "$cands" | python3 -I -c '
import json,sys,collections
d=json.load(sys.stdin); c=d.get("candidates",[])
print("  channel:",d.get("channel"),"| candidates:",len(c))
print("  by provider:",dict(collections.Counter(x.get("provider") for x in c)))
print("  keyless(noauth):",sum(1 for x in c if x.get("connectionId")=="noauth"),
      "| reachable:",sum(1 for x in c if x.get("reachable")),
      "| excluded:",sum(1 for x in c if x.get("excluded")))
for x in c[:8]: print("    ",x.get("modelStr"))
if len(c)>8: print("     ... and",len(c)-8,"more")
'

echo
echo "=== Free model IDs this gateway advertises ==="
models="$(curl -fsS -H "Authorization: Bearer ${KEY}" "${BASE}/v1/models" 2>/dev/null)"
if [ -z "$models" ]; then
  echo "  401/unreachable - GTW_API_KEY is not a key OmniRoute knows."
  echo "  Fix: make omniroute-key"
else
  printf '%s' "$models" | python3 -I -c '
import json,sys
ms=[m.get("id","") for m in json.load(sys.stdin).get("data",[])]
f=[m for m in ms if m.startswith("auto") and "free" in m.lower()]
print("  total models:",len(ms))
print("  free routing IDs:", ", ".join(f) if f else "(none advertised)")
'
fi

if [ "${1:-}" != "--test" ]; then
  echo
  echo "Run with --test (or: make free-combo-test) to send a real completion."
  exit 0
fi

echo
echo "=== Real completion through model=${MODEL} ==="
resp="$(curl -s -m 180 -X POST "${BASE}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":20}" 2>/dev/null)"

printf '%s' "$resp" | python3 -I -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print("  no response (timeout?)"); raise SystemExit(1)
try: d=json.loads(raw)
except Exception:
    print("  non-JSON response:",raw[:300]); raise SystemExit(1)
if "error" in d:
    print("  FAILED - every candidate was tried and refused:")
    for part in str(d["error"].get("message","")).split("; "):
        print("   -",part.strip())
    print()
    print("  Common causes:")
    print("   * cloudflare-playground needs Chromium -> make omniroute-browser-build")
    print("     then set OMNIROUTE_IMAGE=omniroute-browser:local in .env")
    print("   * uncloseai public beta is closed (HTTP 401) - nothing to do")
    print("   * otherwise connect a free-tier provider with a key in the dashboard")
    raise SystemExit(1)
print("  served by:",d.get("model"))
print("  content:",repr(d["choices"][0]["message"]["content"][:160]))
u=d.get("usage") or {}
if u: print("  usage:",{k:u[k] for k in list(u)[:4]})
'
