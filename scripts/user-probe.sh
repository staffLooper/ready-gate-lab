#!/usr/bin/env bash
# user-probe.sh RUN_ID SUITE_ID: the user-token half of C4, C5, C9 and C10. The SESSION runs this from its
# machine, after the sponsor's go, with its own `gh` login (the sponsor's account, practice 9.5's interim).
# It tries, against a gate-App check run and its suite: update, delete, re-request the run, re-request the
# suite, reading the run and suite after each. It writes user-probe.json (pretty-printed). A refusal by the
# session's proxy is recorded as "not measured", not as GitHub's answer.
set -euo pipefail
run=$1; suite=$2
repo=staffLooper/ready-gate-lab
out=$(mktemp); : > "$out"
try() { # try LABEL METHOD PATH [BODY_JSON]
  local resp code
  if [ -n "${4:-}" ]; then resp=$(gh api -i -X "$2" "$3" --input - <<<"$4" 2>&1 || true)
  else resp=$(gh api -i -X "$2" "$3" 2>&1 || true); fi
  code=$(printf '%s\n' "$resp" | awk 'NR==1 && /^HTTP/ {print $2}')
  local proxy=false; grep -q 'not permitted through this proxy\|not available: sessions are bound' <<<"$resp" && proxy=true
  local st; st=$(gh api "repos/$repo/check-runs/$run" --jq '{status, conclusion, summary_length: ((.output.summary // "") | length)}' 2>/dev/null || echo null)
  local ss; ss=$(gh api "repos/$repo/check-suites/$suite" --jq '{status, conclusion}' 2>/dev/null || echo null)
  jq -c -n --arg l "$1" --arg m "$2" --arg p "$3" --arg code "${code:-0}" --argjson proxy "$proxy" --argjson st "$st" --argjson ss "$ss" \
    '{label: $l, method: $m, path: $p, status: ($code | tonumber), proxy_refused: $proxy,
      measured: ($proxy | not), run_after: $st, suite_after: $ss}' >> "$out"
}
try "user updates the run" PATCH "repos/$repo/check-runs/$run" '{"status":"completed","conclusion":"success"}'
try "user deletes the run" DELETE "repos/$repo/check-runs/$run"
try "user re-requests the run" POST "repos/$repo/check-runs/$run/rerequest"
try "user re-requests the suite" POST "repos/$repo/check-suites/$suite/rerequest"
jq -S -s . "$out" > user-probe.json
echo "wrote user-probe.json"
