#!/usr/bin/env bash
# Check the platform's access controls end to end. No GPU or Cohere key needed: every check runs
# before a model is called. Run on lab-cp from the repo root after `terraform apply`, ingest and
# create-teams-and-keys.sh. Exits non-zero if any control fails.
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
PY="${PYTHON:-.venv/bin/python}"
fails=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

kubectl -n platform port-forward svc/litellm 4000:4000 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 3

# The MCP server's audit log records each query's SHA-256; checks 3 and 7 look for it.
digest() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
audit() { kubectl -n mcp logs deploy/kb-dept-a --since=10m | grep '"event":"mcp.tool_call"'; }

echo "1. Retrieval works through the gateway (dept-a key -> its own MCP server -> Qdrant)"
q1="deadline for applications to reach the grants office"
out=$("$PY" demo/ask.py --dept dept-a --force-tool kb_dept_a-search_kb "$q1" 2>&1)
grep -q '^ALLOWED' <<<"$out" && grep -q '01-internal-deadlines.md' <<<"$out" && pass "dept-a retrieves its own policy with a source id" || fail "dept-a retrieval: $out"

echo "2. Each key sees only its own department's tool"
for d in dept-a dept-b; do
  out=$("$PY" demo/ask.py --dept "$d" --force-tool "kb_${d/-/_}-search_kb" "test" 2>&1 | head -1)
  [[ $out == "[$d] tools visible to this key: ['kb_${d/-/_}-search_kb']" ]] && pass "$d sees only kb_${d/-/_}-search_kb" || fail "$d tools: $out"
done

echo "3. Cross-department call is refused by the gateway"
q3="overhead rate on direct costs"
out=$("$PY" demo/ask.py --dept dept-b --force-tool kb_dept_a-search_kb "$q3" 2>&1)
# Any error prints REFUSED, so also require LiteLLM's permission message, and check that dept-a's
# server never logged the query.
log=$(audit)   # captured first: with pipefail, grep -q exiting early would fail the kubectl pipe
if grep -q '^REFUSED.*not allowed' <<<"$out" && ! grep -q "\"query_sha256\":\"$(digest "$q3")\"" <<<"$log"; then
  pass "dept-b cannot call dept-a's tool, and dept-a's server never saw the request"
else
  fail "cross-department call: $out"
fi

echo "4. Confidential tier cannot use the cloud model"
key_a=$("$PY" -c 'import json; print(json.load(open("demo/keys.json"))["dept-a"])')
code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $key_a" -H "Content-Type: application/json" \
  -d '{"model":"cloud-general","messages":[{"role":"user","content":"hi"}]}')
[[ $code == 401 || $code == 403 ]] && pass "dept-a -> cloud-general refused (HTTP $code)" || fail "dept-a -> cloud-general returned HTTP $code"

echo "5. Network policy: only the gateway is reachable from an unrelated namespace"
np=$(kubectl run "np-check-$$" --rm -i --restart=Never --quiet --image=busybox:1.37.0 -- sh -c '
  for t in kb-dept-a.mcp:8080 qdrant.data:6333 embeddings.data:80 postgres.platform:5432 litellm.platform:4000; do
    if nc -z -w 3 "${t%%:*}.svc.cluster.local" "${t##*:}" 2>/dev/null; then echo "$t open"; else echo "$t blocked"; fi
  done' 2>/dev/null)
for t in kb-dept-a.mcp:8080 qdrant.data:6333 embeddings.data:80 postgres.platform:5432; do
  grep -q "^$t blocked" <<<"$np" && pass "$t blocked" || fail "$t reachable: $np"
done
grep -q "^litellm.platform:4000 open" <<<"$np" && pass "litellm.platform:4000 reachable (the only entry point)" || fail "gateway not reachable: $np"

echo "6. MCP server refuses requests without its bearer token"
code=$(kubectl -n platform exec deploy/litellm -- python3 -c '
import urllib.request, urllib.error
req = urllib.request.Request("http://kb-dept-a.mcp.svc.cluster.local:8080/mcp", data=b"{}",
                             headers={"content-type": "application/json"})
try:
    print(urllib.request.urlopen(req, timeout=5).status)
except urllib.error.HTTPError as e:
    print(e.code)' 2>/dev/null)
[[ $code == 401 ]] && pass "no token -> 401" || fail "no token -> $code"

echo "7. Audit log names the caller and stores a query digest, not the query"
# Find check 1's line by its digest. Its query contains "grants office", so the text test can fail.
line=$(audit | grep "\"query_sha256\":\"$(digest "$q1")\"" | tail -1)
[[ -n $line ]] && grep -q '"caller":"demo-user-dept-a"' <<<"$line" && ! grep -q 'grants office' <<<"$line" \
  && pass "audit line has caller + SHA-256 digest, no query text" || fail "audit line for check 1: ${line:-none found}"

echo
if (( fails )); then echo "$fails check(s) FAILED"; exit 1; fi
echo "All checks passed."
