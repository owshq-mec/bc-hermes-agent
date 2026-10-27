#!/usr/bin/env bash
# ==============================================================================
# Does the model behind a given OmniRoute model ID support STRUCTURED tool
# calling? This is the single most important capability check for agent work.
#
# Why it matters: the keyless cloudflare-playground provider that backs the FREE
# combos scrapes a browser playground. It returns the model's prose, never an
# OpenAI `tool_calls` array. Hermes therefore records "0 tool calls" while the
# model's intended call leaks into the message body as plain text like
#   tool_calls: [{"name": "hindsight_recall", ...}]
# Agents silently cannot use ANY tool on such a model.
#
# Usage: make tool-call-check [FREE_MODEL=auto/best-free]
# ==============================================================================
set -uo pipefail

PORT="${OMNIROUTE_PORT:-20128}"
BASE="http://localhost:${PORT}"
KEY="${GTW_API_KEY:-omniroute-local}"
MODEL="${FREE_MODEL:-auto/best-free}"

echo "=== Structured tool-calling probe: model=${MODEL} ==="
resp="$(curl -s -m 180 -X POST "${BASE}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' \
  -d '{
    "model": "'"${MODEL}"'",
    "messages": [{"role":"user","content":"What is the weather in Paris? Use the tool."}],
    "tools": [{"type":"function","function":{
      "name":"get_weather",
      "description":"Get current weather for a city",
      "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
    "tool_choice": "auto",
    "max_tokens": 256
  }' 2>/dev/null)"

printf '%s' "$resp" | python3 -I -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print("  no response (timeout?)"); raise SystemExit(2)
try: d=json.loads(raw)
except Exception:
    print("  non-JSON:",raw[:300]); raise SystemExit(2)
if "error" in d:
    print("  request FAILED:",str(d["error"].get("message",""))[:300]); raise SystemExit(2)
msg=(d.get("choices") or [{}])[0].get("message",{}) or {}
served=d.get("model")
tc=msg.get("tool_calls")
content=msg.get("content") or ""
print("  served by:",served)
if tc:
    print("  RESULT: structured tool_calls PRESENT ->",[c.get("function",{}).get("name") for c in tc])
    print("  This model CAN drive Hermes tools (hindsight_recall/retain/reflect).")
    raise SystemExit(0)
leaked = any(s in content for s in ("tool_calls","get_weather("))
print("  RESULT: NO structured tool_calls field.")
if leaked:
    print("  The call LEAKED INTO TEXT:",repr(content[:160]))
print("  => Hermes will record 0 tool calls. Use HINDSIGHT_MEMORY_MODE=context")
print("     (injection only) on this model, and switch to a provider with real")
print("     function calling for any tool-using demo.")
raise SystemExit(1)
'
