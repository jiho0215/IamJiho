#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../hooks/scripts"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_CONFIG="$TMP/config.json"

bash "$HOOKS/ensure-config.sh"
[ -f "$DEVFW_CONFIG" ] || { echo "FAIL: config not created at DEVFW_CONFIG path"; exit 1; }

PROFILE=$(jq -r '.pipeline.modelProfile // empty' "$DEVFW_CONFIG")
[ "$PROFILE" = "balanced" ] || { echo "FAIL: modelProfile default != 'balanced' (got '$PROFILE')"; exit 1; }

# Existing valid config with modelProfile set should be preserved
cat > "$DEVFW_CONFIG" <<'JSON'
{"pipeline":{"modelProfile":"trust-model","maxReviewIterations":10}}
JSON
bash "$HOOKS/ensure-config.sh"
KEPT=$(jq -r '.pipeline.modelProfile' "$DEVFW_CONFIG")
[ "$KEPT" = "trust-model" ] || { echo "FAIL: user's modelProfile overwritten (got '$KEPT')"; exit 1; }

echo "PASS: model-profile"
