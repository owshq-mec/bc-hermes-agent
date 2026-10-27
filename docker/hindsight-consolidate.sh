#!/usr/bin/env bash
# ==============================================================================
# Trigger a consolidation round and report whether it actually produced writes.
#
# Consolidation asks the LLM for a strict JSON object
#   {"creates":[...],"updates":[...],"deletes":[...]}
# A model that returns a bare LIST instead fails every batch with:
#   ValidationError: 1 validation error for _ConstrainedConsolidationBatchResponse
#   Input should be a valid dictionary ... input_type=list
#
# That is MODEL-specific, not provider-wide. Pin a capable model via
# HINDSIGHT_API_CONSOLIDATION_LLM_MODEL (see .env.example).
#
# Usage: make hindsight-consolidate
# ==============================================================================
set -uo pipefail

C="${CONTAINER_NAME:-hermes-agent}"
BANK="${HINDSIGHT_BANK_ID:-hermes-course}"
API="http://hindsight:8888/v1/default/banks/${BANK}"

echo "=== consolidation model in use ==="
docker exec "$C"-hindsight printenv HINDSIGHT_API_CONSOLIDATION_LLM_MODEL 2>/dev/null \
  | sed 's/^/  model: /' || echo "  (unset - falls back to HINDSIGHT_API_LLM_MODEL)"

before="$(docker compose logs hindsight 2>&1 | grep -cE '_ConstrainedConsolidationBatchResponse' || true)"
echo "  ValidationErrors in log before: ${before}"

# Facts a previous failed round marked `consolidation_failed_at` are EXCLUDED
# from future rounds, so after fixing the cause a plain /consolidate reports
# "completed: 0 processed" and looks like nothing is wrong. /consolidation/recover
# re-queues them. Set RECOVER=0 to skip.
if [ "${RECOVER:-1}" = "1" ]; then
  echo "=== re-queueing previously failed facts (/consolidation/recover) ==="
  docker exec "$C" curl -s -m 180 -X POST "${API}/consolidation/recover" \
    -H 'Content-Type: application/json' -d '{}' | head -c 200
  echo
fi

echo "=== triggering consolidation ==="
docker exec "$C" curl -s -m 900 -X POST "${API}/consolidate" \
  -H 'Content-Type: application/json' -d '{}' | head -c 300
echo

echo "=== waiting for the batch summary (up to 15 min) ==="
for i in $(seq 1 90); do
  line="$(docker compose logs --since 20m hindsight 2>&1 \
    | grep -oE '\[CONSOLIDATION\] bank='"${BANK}"'.*created=[0-9]+ updated=[0-9]+ skipped=[0-9]+ failed=[0-9]+' | tail -1)"
  [ -n "$line" ] && break
  sleep 10
done

if [ -z "${line:-}" ]; then
  echo "  no summary within the window - check 'make hindsight-logs'"
  exit 1
fi
echo "  ${line}"

after="$(docker compose logs hindsight 2>&1 | grep -cE '_ConstrainedConsolidationBatchResponse' || true)"
echo
echo "=== verdict ==="
echo "  ValidationErrors after: ${after} (before: ${before})"
created="$(printf '%s' "$line" | grep -oE 'created=[0-9]+' | cut -d= -f2)"
updated="$(printf '%s' "$line" | grep -oE 'updated=[0-9]+' | cut -d= -f2)"
failed="$(printf '%s' "$line" | grep -oE 'failed=[0-9]+'  | cut -d= -f2)"
if [ "${after}" -gt "${before}" ]; then
  echo "  FAIL - new ValidationErrors. The consolidation model is returning a bare list."
  echo "         Pin a capable one: HINDSIGHT_API_CONSOLIDATION_LLM_MODEL=cfp/openai/gpt-oss-120b"
  exit 1
fi
if [ "${created:-0}" -gt 0 ] || [ "${updated:-0}" -gt 0 ]; then
  echo "  PASS - consolidation produced writes (created=${created} updated=${updated}) with no schema errors."
  exit 0
fi
echo "  INCONCLUSIVE - no schema errors, but created=0 updated=0 failed=${failed:-?}."
echo "  That is legitimate when the bank holds nothing left to merge; add near-duplicate"
echo "  facts and re-run, or check 'make hindsight-logs' for skipped= reasons."
exit 0
