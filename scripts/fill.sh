#!/usr/bin/env bash
# fill.sh STEP: the two long-running fills, with github.token only (no gate key). Runs in CI from lab-fill.yml.
#   cap    E4 (C13): post `ready` statuses on $SHA until GitHub refuses one, or 1,005 attempts.
#          Resumable: it counts the `ready` statuses already there first.
#   flood  E3.7 (C11): dispatch lab-flood.yml on $FLOOD_REF until the check suites on $SHA reach each
#          checkpoint in $CHECKPOINTS, and run the ledger reads at each checkpoint. Needs $APP_ID.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
step=$1
R=$GITHUB_REPOSITORY
OUT="$RUNNER_TEMP/out"; mkdir -p "$OUT"
LOG="$OUT/calls.jsonl"; VERDICTS="$OUT/verdicts.jsonl"; ROWS="$OUT/rows.jsonl"
export LOG VERDICTS
: > "$LOG"; : > "$VERDICTS"; : > "$ROWS"
echo "## fill.sh $step (run $GITHUB_RUN_ID)" >> "$GITHUB_STEP_SUMMARY"

# backoff: after a 403 or 429, wait for retry-after (secondary limit) or the primary reset.
backoff() {
  local ra; ra=$(grep -i '^retry-after:' "$RUNNER_TEMP/headers" | tr -dc '0-9' || true)
  if [ -n "$ra" ]; then sleep "$ra"; else wait_rate gha; sleep 60; fi
}

case "$step" in

cap)
  count=0; page=1
  while :; do
    call "count ready statuses page $page" gha GET "repos/$R/commits/$SHA/statuses?per_page=100&page=$page" > /dev/null
    n=$(jq 'length' "$RUNNER_TEMP/resp.json"); count=$(( count + $(jq '[.[] | select(.context == "ready")] | length' "$RUNNER_TEMP/resp.json") ))
    [ "$n" -lt 100 ] && break; page=$((page + 1))
  done
  echo "already there: $count"
  attempts=$count; first_refusal=""
  while [ "$attempts" -lt 1005 ]; do
    f=$(body "$RUNNER_TEMP/st.json" --arg d "lab fill $((attempts + 1))" '{state: "success", context: "ready", description: $d}')
    code=$(call "fill $((attempts + 1))" gha POST "repos/$R/statuses/$SHA" "$f")
    case "$code" in
      201) attempts=$((attempts + 1)) ;;
      403|429) backoff; continue ;;
      *) first_refusal=$code; jq -c --argjson n "$((attempts + 1))" --arg code "$code" --slurpfile r "$RUNNER_TEMP/resp.json" \
           '{attempt: $n, status: ($code | tonumber), response: $r[0]}' >> "$ROWS"; break ;;
    esac
    sleep 1
    [ $((attempts % 50)) = 0 ] && wait_rate gha
  done
  if [ "$first_refusal" = 422 ] && [ "$attempts" = 1000 ]; then
    verdict C13 PASS "1,000 'ready' statuses accepted on $SHA; attempt 1,001 refused with 422: $(jq -c '.message' "$RUNNER_TEMP/resp.json")"
  else
    verdict C13 MEASURED "accepted $attempts 'ready' statuses; first refusal: ${first_refusal:-none within 1,005}"
  fi
  ;;

flood)
  : "${APP_ID:?APP_ID is required}" "${FLOOD_REF:?FLOOD_REF is required}"
  suites() { call "count suites" gha GET "repos/$R/commits/$SHA/check-suites?per_page=1" > /dev/null; jq .total_count "$RUNNER_TEMP/resp.json"; }
  entries() { # entries QUERY: count of 'ready pr-1' entries the query returns, paged
    local page=1 total=0 n
    while :; do
      call "read $1 page $page" gha GET "repos/$R/commits/$SHA/check-runs?check_name=ready%20pr-1&filter=all&per_page=100&page=$page$1" > /dev/null
      n=$(jq '.check_runs | length' "$RUNNER_TEMP/resp.json"); total=$((total + n))
      [ "$n" -lt 100 ] && break; page=$((page + 1))
    done
    echo "$total"
  }
  checkpoint() {
    local s a b c d e suite
    s=$(suites)
    a=$(entries "&app_id=$APP_ID")
    b=$(entries "")
    call "gate suites for ref" gha GET "repos/$R/commits/$SHA/check-suites?app_id=$APP_ID" > /dev/null
    c=$(jq .total_count "$RUNNER_TEMP/resp.json"); suite=$(jq -r '.check_suites[0].id // empty' "$RUNNER_TEMP/resp.json")
    d=null
    if [ -n "$suite" ]; then
      call "runs in the gate suite" gha GET "repos/$R/check-suites/$suite/check-runs?check_name=ready%20pr-1&filter=all&per_page=100" > /dev/null
      d=$(jq '.check_runs | length' "$RUNNER_TEMP/resp.json")
    fi
    call "all runs for ref" gha GET "repos/$R/commits/$SHA/check-runs?filter=all&per_page=1" > /dev/null
    e=$(jq .total_count "$RUNNER_TEMP/resp.json")
    jq -c -n --arg l "$1" --argjson s "$s" --argjson a "$a" --argjson b "$b" --argjson c "$c" --argjson d "$d" --argjson e "$e" --arg at "$(date -u +%FT%TZ)" \
      '{checkpoint: $l, at: $at, suites_on_commit: $s, read_with_app_id: $a, read_without_app_id: $b,
        gate_suites_listed: $c, runs_via_gate_suite: $d, all_runs_total_count: $e}' >> "$ROWS"
    echo "checkpoint $1: suites $s, ledger read $a, via suite $d"
  }
  checkpoint start
  for target in ${CHECKPOINTS:-500 990 1000 1010 1100 1300}; do
    stall=0
    while :; do
      cur=$(suites); [ "$cur" -ge "$target" ] && break
      batch=$(( target - cur < 25 ? target - cur : 25 ))
      f=$(body "$RUNNER_TEMP/d.json" --arg r "$FLOOD_REF" '{ref: $r}')
      for _ in $(seq 1 "$batch"); do
        code=$(call "dispatch" gha POST "repos/$R/actions/workflows/lab-flood.yml/dispatches" "$f")
        case "$code" in 204) ;; 403|429) backoff ;; *) echo "::warning::dispatch returned $code" ;; esac
        sleep 1
      done
      sleep 20; wait_rate gha
      now=$(suites)
      if [ "$now" -le "$cur" ]; then stall=$((stall + 1)); else stall=0; fi
      if [ "$stall" -ge 3 ]; then
        verdict C11 MEASURED "suites stopped growing at $now: dispatches with github.token created no suites (fallback in EXPERIMENT.md E3.7)"
        break 2
      fi
    done
    checkpoint "at $target"
  done
  first_cut=$(jq -s -r '[.[] | select(.read_with_app_id < 3)] | first | .suites_on_commit // "none"' "$ROWS")
  via=$(jq -s -c '[.[] | .runs_via_gate_suite] | unique' "$ROWS")
  verdict C11 MEASURED "first checkpoint where the ledger read returned fewer than 3 seeded entries: $first_cut suites; reads through the gate suite returned $via"
  ;;

*) echo "unknown step $step" >&2; exit 2 ;;
esac

for f in "$OUT"/*.jsonl; do
  [ -s "$f" ] || continue
  pretty "$f"; base=$(basename "$f" .jsonl)
  "$here/save.sh" "$step/$GITHUB_RUN_ID/$base.json" "$f"
done
