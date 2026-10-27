#!/usr/bin/env bash
# ==============================================================================
# Prove Hindsight's retain -> extract -> recall round trip, independent of the
# agent model's instruction-following.
#
# This is the honest test of MEMORY. The agent-level demo (make demo-memory)
# additionally depends on the model choosing to use injected context, which free
# keyless models do unreliably. This script bypasses that and tests the store.
#
# Usage: make hindsight-roundtrip
# ==============================================================================
set -uo pipefail

C="${CONTAINER_NAME:-hermes-agent}"
BANK="${HINDSIGHT_BANK_ID:-hermes-course}"
API="http://hindsight:8888/v1/default/banks/${BANK}"
NONCE="$(date +%s)"
FACT="Round-trip probe ${NONCE}: the hermes-course canary value is QUETZAL-${NONCE}."

ex() { docker exec "$C" "$@"; }

echo "=== 1. facts before ==="
before="$(ex curl -fsS "http://hindsight:8888/v1/default/banks" 2>/dev/null \
  | BANK="$BANK" python3 -I -c 'import json,sys,os
bank=os.environ["BANK"]
for x in json.load(sys.stdin).get("banks",[]):
    if x.get("bank_id")==bank: print(x.get("fact_count",0)); break
else: print(0)' 2>/dev/null || echo 0)"
echo "  ${before}"

echo "=== 2. retain (runs the extraction LLM; can take 30-150s on free combos) ==="
payload="$(FACT="$FACT" python3 -I -c 'import json,os;print(json.dumps({"items":[{"content":os.environ["FACT"],"context":"hindsight round-trip probe"}]}))')"
ex curl -s -m 600 -X POST "${API}/memories" -H 'Content-Type: application/json' -d "$payload" \
  | python3 -I -c 'import json,sys
raw=sys.stdin.read().strip()
try: d=json.loads(raw)
except Exception: print("  non-JSON:",raw[:300]); raise SystemExit(1)
if not d.get("success"): print("  FAILED:",raw[:400]); raise SystemExit(1)
u=d.get("usage") or {}
print("  success=%s items=%s tokens=%s" % (d.get("success"),d.get("items_count"),u.get("total_tokens")))'
rc=$?
[ $rc -ne 0 ] && { echo "  retain failed - see 'make hindsight-logs'"; exit 1; }

echo "=== 3. facts after ==="
after="$(ex curl -fsS "http://hindsight:8888/v1/default/banks" 2>/dev/null \
  | BANK="$BANK" python3 -I -c 'import json,sys,os
bank=os.environ["BANK"]
for x in json.load(sys.stdin).get("banks",[]):
    if x.get("bank_id")==bank: print(x.get("fact_count",0)); break
else: print(0)' 2>/dev/null || echo 0)"
echo "  ${after}  (was ${before})"

echo "=== 4. recall the canary ==="
ex curl -s -m 180 -X POST "${API}/memories/recall" -H 'Content-Type: application/json' \
  -d "{\"query\":\"What is the hermes-course canary value?\",\"budget\":\"mid\"}" \
  | NONCE="$NONCE" python3 -I -c '
import json,sys,os
nonce=os.environ["NONCE"]
d=json.load(sys.stdin); r=d.get("results") or []
print("  hits:",len(r))
hit=None
for i,it in enumerate(r):
    t=str(it.get("text") or it.get("content") or it)
    if i<4: print("   %d. %s" % (i+1,t[:120].replace(chr(10)," ")))
    if ("QUETZAL-"+nonce) in t and hit is None: hit=i+1
print()
if hit: print("  PASS - canary QUETZAL-%s recalled at rank %d" % (nonce,hit)); raise SystemExit(0)
print("  FAIL - canary QUETZAL-%s not in recall results" % nonce)
print("  Extraction may still be running; re-run in a minute.")
raise SystemExit(1)
'
