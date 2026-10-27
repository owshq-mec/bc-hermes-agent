#!/usr/bin/env bash
# ==============================================================================
# Recover consolidation tasks orphaned by a stale worker lease.
#
# THE TRAP: Hindsight's background worker claims queued tasks under a lease
# keyed to its worker id. Recreating or replacing the container (docker compose
# up -d after an env change, --force-recreate, an image bump) kills that worker
# while the lease still points at it. A NEW worker will not steal the task, so
# the queue sits like this forever:
#
#   global: pending=1 ... others: 9454be36ad5d:1 ... my_active: none
#   [PENDING_BREAKDOWN] consolidation: total=1 payload_null=0 retry_blocked=0 assigned=0
#
# Nothing progresses and no error is logged - consolidation simply never runs.
# Worse, POSTing /consolidate again returns {"deduplicated": true} and folds
# into the SAME stuck task, so retrying looks like it worked and does nothing.
#
# THE RECOVERY: a restart runs the startup consolidation reconcile, which
# reclaims tasks whose worker is gone. Verified: pending went 1 -> 0.
#
# Usage: make hindsight-unstick
# ==============================================================================
set -uo pipefail

pending_line() {
  docker compose logs --since 2m hindsight 2>&1 \
    | grep -oE 'global: pending=[0-9]+[^|]*\| others: [^|]*' | tail -1
}

echo "=== queue state before ==="
before="$(pending_line)"
if [ -n "$before" ]; then
  echo "  ${before}"
else
  echo "  (no WORKER_STATS line in the last 2m; the worker polls every ~30s)"
fi

echo "=== restarting hindsight to run the startup reconcile ==="
docker compose restart hindsight >/dev/null 2>&1

for i in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER_NAME:-hermes-agent}-hindsight" 2>/dev/null)" = "healthy" ] && break
  sleep 5
done
echo "  healthy"

echo "=== waiting for a fresh WORKER_STATS poll (up to 90s) ==="
for i in $(seq 1 18); do
  line="$(pending_line)"
  [ -n "$line" ] && { echo "  ${line}"; break; }
  sleep 5
done

echo
echo "If 'others:' is now 'none' and pending=0, the orphan is cleared."
echo "Re-trigger the work with:  make hindsight-consolidate"
