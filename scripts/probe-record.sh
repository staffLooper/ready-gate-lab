#!/usr/bin/env bash
# probe-record.sh: E2 in EXPERIMENT.md. The `record` job of lab-key-probe.yml (and of probes/pr-probe.yml) runs
# this after the probe jobs, in a job that names no environment. It reads this run's jobs, their annotations
# and logs, and records whether the job that named staff-gate ran and saw the key. Logs carry only
# "key_present=true|false"; the key's value is never printed (and GitHub masks it).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
R=$GITHUB_REPOSITORY
OUT="$RUNNER_TEMP/out"; mkdir -p "$OUT"
LOG="$OUT/calls.jsonl"; VERDICTS="$OUT/verdicts.jsonl"; JOBS="$OUT/jobs.jsonl"
export LOG VERDICTS
: > "$LOG"; : > "$VERDICTS"; : > "$JOBS"
echo "## probe-record.sh: $GITHUB_EVENT_NAME on $GITHUB_REF (run $GITHUB_RUN_ID)" >> "$GITHUB_STEP_SUMMARY"

call "this run's jobs" gha GET "repos/$R/actions/runs/$GITHUB_RUN_ID/jobs" > /dev/null
jq -c '.jobs[] | select(.name != "record")' "$RUNNER_TEMP/resp.json" > "$RUNNER_TEMP/jobs.jsonl"
while read -r job; do
  id=$(jq -r .id <<<"$job"); name=$(jq -r .name <<<"$job")
  call "annotations of $name" gha GET "repos/$R/check-runs/$id/annotations" > /dev/null
  notes=$(jq -c '[.[]? | {level: .annotation_level, message}]' "$RUNNER_TEMP/resp.json")
  logs=$(curl -sSL -H "Authorization: Bearer $GHA_TOKEN" "$API/repos/$R/actions/jobs/$id/logs" \
    | grep -Eo '(key_present|app_id_present)=(true|false)' | sort -u | paste -sd, - || true)
  jq -c --argjson notes "$notes" --arg logs "$logs" '{name, conclusion, steps: [.steps[]? | {name, conclusion}],
    started_at, completed_at, annotations: $notes, log_facts: $logs}' <<<"$job" >> "$JOBS"
done < "$RUNNER_TEMP/jobs.jsonl"
call "staff-gate deployments" gha GET "repos/$R/deployments?environment=staff-gate&per_page=10" > /dev/null
jq -c '[.[] | {id, ref, sha, created_at, creator: .creator.login}]' "$RUNNER_TEMP/resp.json" > "$OUT/deployments.json"

jq -S -n --arg ev "$GITHUB_EVENT_NAME" --arg ref "$GITHUB_REF" --arg head "${GITHUB_HEAD_REF:-}" --arg base "${GITHUB_BASE_REF:-}" \
  --arg action "${EVENT_ACTION:-}" --argjson changes "${EVENT_CHANGES:-null}" \
  '{event: $ev, action: $action, ref: $ref, head_ref: $head, base_ref: $base, changes: $changes}' > "$OUT/event.json"

with=$(jq -r 'select(.name == "with-environment") | .log_facts' "$JOBS" | head -1)
withc=$(jq -r 'select(.name == "with-environment") | .conclusion' "$JOBS" | head -1)
without=$(jq -r 'select(.name == "without-environment") | .log_facts' "$JOBS" | head -1)
case_id="$GITHUB_EVENT_NAME:$GITHUB_REF"
admitted_by_design=false
if { [ "$GITHUB_EVENT_NAME" = workflow_dispatch ] || [ "$GITHUB_EVENT_NAME" = pull_request_target ]; } && [ "$GITHUB_REF" = refs/heads/main ]; then
  admitted_by_design=true
fi
if [ "$admitted_by_design" = true ]; then
  [[ "$with" == *key_present=true* ]] && verdict "E2 control $case_id" PASS "the job on main got the key ($with)" \
                                       || verdict "E2 control $case_id" FAIL "the job on main did not get the key ($withc, $with): every refusal below proves nothing"
else
  if [[ "$with" != *key_present=true* ]] && [ "$withc" != success ]; then
    verdict "E2 refused $case_id" PASS "the job naming staff-gate was refused ($withc; annotations in jobs.json)"
  else
    verdict "E2 refused $case_id" FAIL "the job naming staff-gate ran ($withc, $with)"
  fi
fi
[[ "$without" == *key_present=false* ]] && verdict "E2 no-env $case_id" PASS "a job naming no environment sees no STAFF_GATE_PRIVATE_KEY (no repository or organization secret by that name)" \
                                        || verdict "E2 no-env $case_id" FAIL "a job naming no environment saw: ${without:-nothing recorded}"

slug=$(printf '%s' "$case_id" | tr -c 'A-Za-z0-9._-' '-')
for f in "$OUT"/*; do
  [ -s "$f" ] || continue
  base=$(basename "$f")
  case "$base" in *.jsonl) pretty "$f"; base=${base%.jsonl}.json ;; esac
  "$here/save.sh" "e2/$slug/$GITHUB_RUN_ID/$base" "$f"
done
