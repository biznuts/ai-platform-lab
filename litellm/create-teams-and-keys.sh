#!/usr/bin/env bash
# Create one LiteLLM team + virtual key per department. Run against a port-forward:
#   kubectl -n platform port-forward svc/litellm 4000:4000
#   LITELLM_MASTER_KEY="$(cat terraform/secrets/litellm_master_key)" ./litellm/create-teams-and-keys.sh
# Writes the generated keys to demo/keys.json (gitignored). Not idempotent: re-running makes new keys.
set -euo pipefail

BASE="${LITELLM_URL:-http://localhost:4000}"
: "${LITELLM_MASTER_KEY:?export LITELLM_MASTER_KEY first}"
OUT="$(dirname "$0")/../demo/keys.json"

api() { # method path json
  curl -fsS -X "$1" "$BASE$2" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" -d "$3"
}

# team_alias | models allowed (by classification) | MCP server | monthly budget (USD)
make_team() {
  local alias="$1" models="$2" mcp="$3" budget="$4"
  # object_permission.mcp_servers takes the server_id set in litellm/config.yaml.
  local team_id
  team_id=$(api POST /team/new "{
      \"team_alias\": \"$alias\",
      \"models\": $models,
      \"max_budget\": $budget,
      \"budget_duration\": \"30d\",
      \"object_permission\": {\"mcp_servers\": [\"$mcp\"]}
    }" | python3 -c 'import json,sys; print(json.load(sys.stdin)["team_id"])')
  api POST /key/generate "{
      \"team_id\": \"$team_id\",
      \"key_alias\": \"$alias-demo\",
      \"models\": $models,
      \"object_permission\": {\"mcp_servers\": [\"$mcp\"]}
    }" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])'
}

KEY_A=$(make_team dept-a '["local-private"]'                  kb_dept_a 5)   # confidential tier
KEY_B=$(make_team dept-b '["local-private","cloud-general"]'  kb_dept_b 5)   # public tier

umask 077
printf '{"dept-a": "%s", "dept-b": "%s"}\n' "$KEY_A" "$KEY_B" > "$OUT"
echo "wrote $OUT (gitignored). Verify: dept-a must NOT be able to call cloud-general or kb_dept_b."
