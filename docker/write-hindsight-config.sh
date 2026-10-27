#!/usr/bin/env bash
# ==============================================================================
# Render $DATA_DIR/hindsight/config.json for the Hermes Hindsight plugin.
#
# The plugin reads, in order: $HERMES_HOME/hindsight/config.json (this file),
# then ~/.hindsight/config.json, then HINDSIGHT_* env vars. Because the profile
# file wins, a stale file here silently overrides everything you set in .env --
# which is exactly how a demo ends up pointing at the wrong server. So we
# generate it from .env instead of hand-editing it.
#
# Usage: make hindsight-config      (or: DATA_DIR=./data ./docker/write-hindsight-config.sh)
# ==============================================================================
set -euo pipefail

DATA_DIR="${DATA_DIR:-./data}"
MODE="${HINDSIGHT_MODE:-local_external}"
BANK_ID="${HINDSIGHT_BANK_ID:-hermes-course}"
TIMEOUT="${HINDSIGHT_TIMEOUT:-120}"
MEMORY_MODE="${HINDSIGHT_MEMORY_MODE:-hybrid}"
RECALL_BUDGET="${HINDSIGHT_BUDGET:-mid}"
# Default is "observation" only, which hides raw facts from recall. The demo
# wants to see them, so include world + experience.
RECALL_TYPES="${HINDSIGHT_RECALL_TYPES:-observation,world,experience}"
AUTO_RETAIN="${HINDSIGHT_AUTO_RETAIN:-true}"
API_KEY="${HINDSIGHT_API_KEY:-}"

# Mode-appropriate default URL. In local_external the plugin runs INSIDE the
# hermes container, so the hostname is the compose service name, not localhost.
case "$MODE" in
  cloud)          DEFAULT_URL="https://api.hindsight.vectorize.io" ;;
  local_external) DEFAULT_URL="http://hindsight:8888" ;;
  local_embedded) DEFAULT_URL="" ;;
  *) echo "write-hindsight-config: unknown HINDSIGHT_MODE='$MODE'" >&2
     echo "  expected one of: cloud | local_external | local_embedded" >&2
     exit 1 ;;
esac
API_URL="${HINDSIGHT_API_URL:-$DEFAULT_URL}"

if [ "$MODE" = "cloud" ] && [ -z "$API_KEY" ]; then
  echo "write-hindsight-config: WARNING - mode is 'cloud' but HINDSIGHT_API_KEY is empty." >&2
  echo "  Set it in .env or the plugin cannot authenticate to Vectorize cloud." >&2
fi

TARGET_DIR="$DATA_DIR/hindsight"
TARGET="$TARGET_DIR/config.json"
mkdir -p "$TARGET_DIR"

# Never silently discard a config that may point somewhere the user cares about.
if [ -f "$TARGET" ]; then
  BACKUP="$TARGET.bak-$(date +%Y%m%d%H%M%S)"
  cp "$TARGET" "$BACKUP"
  echo "Backed up existing config to $BACKUP"
fi

{
  printf '{\n'
  printf '  "mode": "%s",\n' "$MODE"
  if [ -n "$API_URL" ]; then printf '  "api_url": "%s",\n' "$API_URL"; fi
  if [ -n "$API_KEY" ]; then printf '  "api_key": "%s",\n' "$API_KEY"; fi
  printf '  "bank_id": "%s",\n' "$BANK_ID"
  printf '  "timeout": %s,\n' "$TIMEOUT"
  printf '  "memory_mode": "%s",\n' "$MEMORY_MODE"
  printf '  "recall_budget": "%s",\n' "$RECALL_BUDGET"
  printf '  "recall_types": "%s",\n' "$RECALL_TYPES"
  printf '  "auto_retain": %s\n' "$AUTO_RETAIN"
  printf '}\n'
} > "$TARGET"

chmod 600 "$TARGET" 2>/dev/null || true

echo "Wrote $TARGET:"
sed -E 's/("api_key": ")[^"]*/\1<redacted>/' "$TARGET"
echo
echo "Next: make hindsight-enable   (sets memory.provider=hindsight and restarts Hermes)"
