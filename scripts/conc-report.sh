#!/usr/bin/env bash
# conc-report.sh: E5's report, in CI from lab-conc-report.yml (github.token, read-only except for the save).
# Reads every lab-conc-{a,b,c,d} run created at or after $SINCE whose title starts "[burst]", with its jobs,
# joins them to the burst log the session committed at runs/e5/burst-log.json on lab/results, and counts,
# per setup, mix and spacing: cancelled evaluations, lost payloads, and whether each burst's last event
# was evaluated.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
R=$GITHUB_REPOSITORY
OUT="$RUNNER_TEMP/out"; mkdir -p "$OUT"
LOG="$OUT/calls.jsonl"; VERDICTS="$OUT/verdicts.jsonl"; ROWS="$OUT/runs.jsonl"
export LOG VERDICTS
: > "$LOG"; : > "$VERDICTS"; : > "$ROWS"
: "${SINCE:?SINCE is required, for example 2026-11-27T14:00:00Z}"

call "burst log" gha GET "repos/$R/contents/runs/e5/burst-log.json?ref=${RESULTS_BRANCH:-lab/results}" > /dev/null
jq -r .content "$RUNNER_TEMP/resp.json" | base64 -d > "$OUT/burst-log.json"

for w in a b c d; do
  page=1
  while :; do
    call "lab-conc-$w runs page $page" gha GET "repos/$R/actions/workflows/lab-conc-$w.yml/runs?created=%3E%3D$SINCE&per_page=100&page=$page" > /dev/null
    cp "$RUNNER_TEMP/resp.json" "$RUNNER_TEMP/runs-page.json"
    n=$(jq '.workflow_runs | length' "$RUNNER_TEMP/runs-page.json")
    for id in $(jq -r '.workflow_runs[] | select(.display_title | startswith("[burst]")) | .id' "$RUNNER_TEMP/runs-page.json"); do
      call "jobs of $id" gha GET "repos/$R/actions/runs/$id/jobs?filter=all" > /dev/null
      jq -c --arg w "$w" --argjson id "$id" --slurpfile page "$RUNNER_TEMP/runs-page.json" '
        ($page[0].workflow_runs[] | select(.id == $id)) as $run
        | {setup: $w, run_id: $id, event: $run.event, title: $run.display_title, created_at: $run.created_at,
           conclusion: $run.conclusion,
           jobs: [.jobs[] | {name, conclusion, started_at, completed_at}]}' "$RUNNER_TEMP/resp.json" >> "$ROWS"
    done
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
    [ $((page % 5)) = 0 ] && wait_rate gha
  done
done

jq -S -n --slurpfile rows "$ROWS" --slurpfile log "$OUT/burst-log.json" '
  def ms: if . == null then null else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 * 1000) end;
  ($log[0] | sort_by(.events[0].sent_at_ms)) as $bursts
  | [$rows[] | . + {created_ms: (.created_at | ms)}
      | . as $r
      | . + {burst: ([$bursts[] | select(.events[0].sent_at_ms - 5000 <= $r.created_ms)] | last)}] as $runs
  | [$runs[] | select(.burst != null)]
  | group_by([.setup, .burst.burst])
  | map(
      (.[0].setup) as $s | (.[0].burst) as $b
      | ([.[] | select(.event != "workflow_run")] | max_by(.created_ms)) as $last
      | ([.[] | .jobs[] | select(.name | startswith("evaluate"))]) as $ev
      | {setup: $s, burst: $b.burst, mix: $b.mix, spacing_s: $b.spacing, events_sent: ($b.events | length),
         runs: length,
         ingest_not_success: ([.[] | .jobs[] | select(.name == "ingest" and .conclusion != "success")] | length),
         evaluate_success: ([$ev[] | select(.conclusion == "success")] | length),
         evaluate_cancelled: ([$ev[] | select(.conclusion == "cancelled")] | length),
         cancelled_after_start: ([$ev[] | select(.conclusion == "cancelled" and .started_at != null and .completed_at != null
                                  and ((.completed_at | ms) - (.started_at | ms)) > 2000)] | length),
         payload_lost: (if $s == "a"
                        then [.[] | select(any(.jobs[]; .name == "ingest" and .conclusion != "success"))] | length
                        else [.[] | select(.event != "workflow_run" and any(.jobs[]; (.name | startswith("evaluate")) and .conclusion == "cancelled"))] | length end),
         last_event_evaluated: (if $last == null then null else
           any($ev[]; .conclusion == "success" and (.started_at | ms) >= $last.created_ms) end),
         newest_survived: (if $last == null then null else
           any($last.jobs[]; (.name | startswith("evaluate")) and .conclusion == "success") end),
         group_none: ([$ev[] | select(.name | endswith("-none"))] | length)})
  | {per_burst: .,
     per_setup: (group_by([.setup, .mix, .spacing_s]) | map({setup: .[0].setup, mix: .[0].mix, spacing_s: .[0].spacing_s,
        bursts: length, events_sent: (map(.events_sent) | add), evaluate_cancelled: (map(.evaluate_cancelled) | add),
        cancelled_after_start: (map(.cancelled_after_start) | add), payload_lost: (map(.payload_lost) | add), bursts_last_event_not_evaluated: (map(select(.last_event_evaluated != true)) | length),
        bursts_newest_cancelled: (map(select(.newest_survived != true)) | length), group_none: (map(.group_none) | add)}))}
' > "$OUT/report.json"

a_lost=$(jq '[.per_setup[] | select(.setup == "a") | .payload_lost] | add // 0' "$OUT/report.json")
a_unev=$(jq '[.per_setup[] | select(.setup == "a") | .bursts_last_event_not_evaluated] | add // 0' "$OUT/report.json")
a_bursts=$(jq '[.per_setup[] | select(.setup == "a") | .bursts] | add // 0' "$OUT/report.json")
if [ "$a_bursts" -gt 0 ] && [ "$a_lost" = 0 ] && [ "$a_unev" = 0 ]; then
  verdict C14-A PASS "setup A (the ADR's shape): over $a_bursts bursts, no ingest lost, and every burst's last event was evaluated"
else
  verdict C14-A FAIL "setup A: $a_lost payloads lost, $a_unev of $a_bursts bursts whose last event wasn't evaluated"
fi
for s in b c d; do
  verdict "C14-$s" MEASURED "$(jq -c --arg s "$s" '[.per_setup[] | select(.setup == $s) | {mix, spacing_s, bursts, evaluate_cancelled, cancelled_after_start, payload_lost, bursts_last_event_not_evaluated}]' "$OUT/report.json")"
done
ab_running=$(jq '[.per_setup[] | select(.setup == "a" or .setup == "b") | .cancelled_after_start] | add // 0' "$OUT/report.json")
ab_newest=$(jq '[.per_setup[] | select(.setup == "a" or .setup == "b") | .bursts_newest_cancelled] | add // 0' "$OUT/report.json")
if [ "$ab_running" = 0 ] && [ "$ab_newest" = 0 ]; then
  verdict C14-rule PASS "with cancel-in-progress false (A, B), no running evaluation was cancelled and no burst's newest run was cancelled: the older waiting run is the one replaced"
else
  verdict C14-rule FAIL "with cancel-in-progress false: $ab_running running evaluations cancelled; $ab_newest bursts whose newest run was cancelled"
fi
verdict C15 MEASURED "evaluations grouped as 'none' (workflow_run with no pull request number): $(jq '[.per_setup[].group_none] | add // 0' "$OUT/report.json")"

for f in "$OUT"/*; do
  [ -s "$f" ] || continue
  base=$(basename "$f")
  case "$base" in burst-log.json) continue ;; *.jsonl) pretty "$f"; base=${base%.jsonl}.json ;; esac
  "$here/save.sh" "e5/report/$GITHUB_RUN_ID/$base" "$f"
done
