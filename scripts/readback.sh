#!/usr/bin/env bash
# readback.sh STEP: E1 in EXPERIMENT.md. Runs in CI from lab-readback.yml, in a job that names no environment.
#   staff-gate  C1: read staff-gate back, as ADR-0082 decision 2.2 says, with github.token and with no token.
#   missing     C1b: read back lab-never-created after lab-readback.yml's `touch` job has named it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
step=$1
R=$GITHUB_REPOSITORY
OUT="$RUNNER_TEMP/out"; mkdir -p "$OUT"
LOG="$OUT/calls.jsonl"; VERDICTS="$OUT/verdicts.jsonl"
export LOG VERDICTS
: > "$LOG"; : > "$VERDICTS"
echo "## readback.sh $step (run $GITHUB_RUN_ID)" >> "$GITHUB_STEP_SUMMARY"
default=$(curl -fsS "$API/repos/$R" | jq -r .default_branch)

case "$step" in
staff-gate)
  for who in gha anon; do
    e=$(call "environment as $who" "$who" GET "repos/$R/environments/staff-gate")
    policy=$(jq -cS '.deployment_branch_policy' "$RUNNER_TEMP/resp.json")
    rules=$(jq -c '[.protection_rules[]? | .type]' "$RUNNER_TEMP/resp.json")
    p=$(call "branch policies as $who" "$who" GET "repos/$R/environments/staff-gate/deployment-branch-policies")
    pols=$(jq -c '[.branch_policies[]? | {type, name}]' "$RUNNER_TEMP/resp.json")
    if [ "$e" = 200 ] && [ "$p" = 200 ] \
       && [ "$policy" = '{"custom_branch_policies":true,"protected_branches":false}' ] \
       && [ "$pols" = "[{\"type\":\"branch\",\"name\":\"$default\"}]" ]; then
      verdict "C1 ($who)" PASS "deployment_branch_policy $policy; policies $pols; protection rules $rules"
    else
      verdict "C1 ($who)" FAIL "HTTP $e/$p; deployment_branch_policy $policy; policies $pols; protection rules $rules; want one branch policy named $default"
    fi
  done
  ;;
missing)
  e=$(call "lab-never-created as gha" gha GET "repos/$R/environments/lab-never-created")
  policy=$(jq -cS '.deployment_branch_policy' "$RUNNER_TEMP/resp.json")
  if [ "$e" = 200 ] && [ "$policy" = null ]; then
    verdict C1b PASS "naming a missing environment created it, with no branch rule (deployment_branch_policy null): the read-back is needed"
  else
    verdict C1b MEASURED "HTTP $e; deployment_branch_policy $policy"
  fi
  ;;
*) echo "unknown step $step" >&2; exit 2 ;;
esac

for f in "$OUT"/*.jsonl; do
  [ -s "$f" ] || continue
  pretty "$f"; base=$(basename "$f" .jsonl)
  "$here/save.sh" "readback-$step/$GITHUB_RUN_ID/$base.json" "$f"
done
