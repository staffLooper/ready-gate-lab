#!/usr/bin/env bash
# ledger.sh STEP: the check-run ledger and status experiments, E0, E3 and E4 in EXPERIMENT.md.
# Runs in CI only, from lab-ledger.yml. Inputs come from the environment:
#   SHA         the commit the step writes on (each step has its own lab/* branch; see EXPERIMENT.md "Setup")
#   APP_ID      the gate App's id (public; from E0's app.json), for steps that run without the key
#   TARGET_RUN  delete-run: the Actions run that created the check run
#   CHECK_RUN   delete-run: that check run's id
#   PR_HEAD     visibility: the head sha of the lab/vis pull request
#   N           read-after-write: how many rounds (default 100)
# Every call goes to $LOG through lib.sh; the step's files are saved under runs/<step>/<run id>/.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
step=$1
R=$GITHUB_REPOSITORY
OUT="$RUNNER_TEMP/out"; mkdir -p "$OUT"
LOG="$OUT/calls.jsonl"; VERDICTS="$OUT/verdicts.jsonl"; SNAPS="$OUT/snapshots.jsonl"
export LOG VERDICTS
: > "$LOG"; : > "$VERDICTS"; : > "$SNAPS"
echo "## ledger.sh $step (run $GITHUB_RUN_ID)" >> "$GITHUB_STEP_SUMMARY"

gate_ready() { [ -s "$RUNNER_TEMP/gate-token" ]; }
gate_id() { jq -r .app.id "$OUT/app.json"; }

# mkrun LABEL WHO NAME EXTERNAL_ID CONCLUSION SUMMARY: creates a completed check run on $SHA; prints its id or "".
mkrun() {
  local f; f=$(body "$RUNNER_TEMP/mk.json" --arg n "$3" --arg e "$4" --arg c "$5" --arg s "$6" --arg h "$SHA" \
    '{name: $n, head_sha: $h, external_id: $e, status: "completed", conclusion: $c,
      output: {title: ("lab " + $e), summary: $s}}')
  local code; code=$(call "$1" "$2" POST "repos/$R/check-runs" "$f")
  if [ "$code" = 201 ]; then jq -r .id "$RUNNER_TEMP/resp.json"; else echo ""; fi
}

# patch_run LABEL WHO ID CONCLUSION: completes run ID with CONCLUSION; prints the HTTP status.
patch_run() {
  local f; f=$(body "$RUNNER_TEMP/patch.json" --arg c "$4" '{status: "completed", conclusion: $c}')
  call "$1" "$2" PATCH "repos/$R/check-runs/$3" "$f"
}

# snap LABEL ID...: one snapshot line per run: state, and the summary's length and sha256.
snap() {
  local label=$1; shift
  for id in "$@"; do
    call "$label: read run $id" gha GET "repos/$R/check-runs/$id" > /dev/null
    local h; h=$(jq -j '.output.summary // ""' "$RUNNER_TEMP/resp.json" | sha256sum | cut -d' ' -f1)
    jq -c --arg l "$label" --arg h "$h" '{label: $l, kind: "run", id, name, external_id, status, conclusion,
      completed_at, app_id: .app.id, suite: .check_suite.id, title: .output.title,
      summary_length: ((.output.summary // "") | length), summary_sha256: $h}' "$RUNNER_TEMP/resp.json" >> "$SNAPS"
  done
}

# snap_suite LABEL SUITE_ID
snap_suite() {
  call "$1: read suite $2" gha GET "repos/$R/check-suites/$2" > /dev/null
  jq -c --arg l "$1" '{label: $l, kind: "suite", id, status, conclusion, rerequestable, runs_rerequestable,
    latest_check_runs_count, app_id: .app.id, updated_at}' "$RUNNER_TEMP/resp.json" >> "$SNAPS"
}

# read_ledger LABEL WHO NAME [APP_ID]: ADR-0082 decision 3.5's read, paged; leaves the entries in ledger.json.
read_ledger() {
  local q; q="check_name=$(jq -rn --arg n "$3" '$n|@uri')&filter=all&per_page=100"
  [ -n "${4:-}" ] && q="$q&app_id=$4"
  : > "$RUNNER_TEMP/ledger.jsonl"
  local page=1 code n
  while :; do
    code=$(call "$1: ledger read page $page" "$2" GET "repos/$R/commits/$SHA/check-runs?$q&page=$page")
    [ "$code" = 200 ] || { echo "ledger read failed: $code"; break; }
    jq -c '.check_runs[] | {id, name, external_id, status, conclusion, app_id: .app.id, suite: .check_suite.id}' \
      "$RUNNER_TEMP/resp.json" >> "$RUNNER_TEMP/ledger.jsonl"
    n=$(jq '.check_runs | length' "$RUNNER_TEMP/resp.json")
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
  done
  jq -s . "$RUNNER_TEMP/ledger.jsonl" > "$RUNNER_TEMP/ledger.json"
  jq -c --arg l "$1" '{label: $l, kind: "ledger", entries: .}' "$RUNNER_TEMP/ledger.json" >> "$SNAPS"
}

refused() { case "$1" in 2??) return 1 ;; *) return 0 ;; esac; }

case "$step" in

app-readback) # E0
  a="$OUT/app.json"
  owner=$(jq -r .app.owner "$a"); sel=$(jq -r .installation.repository_selection "$a")
  perms=$(jq -cS .installation.permissions "$a"); repos=$(jq -c .installed_repositories "$a")
  events=$(jq -c '.installation.events' "$a")
  want='{"checks":"write","contents":"read","metadata":"read","pull_requests":"read","statuses":"write"}'
  [ "$owner" = staffLooper ] && verdict E0.1 PASS "App owned by staffLooper" || verdict E0.1 FAIL "App owner is $owner"
  [ "$perms" = "$want" ] && verdict E0.2 PASS "installation permissions are exactly $want" || verdict E0.2 FAIL "installation permissions are $perms; want $want"
  [ "$sel" = selected ] && [ "$repos" = '["staffLooper/ready-gate-lab"]' ] \
    && verdict E0.3 PASS "installed on staffLooper/ready-gate-lab only" || verdict E0.3 FAIL "selection $sel, repositories $repos"
  [ "$events" = '[]' ] && verdict E0.4 PASS "subscribed to no webhook events" || verdict E0.4 FAIL "events $events"
  ;;

ownership) # E3.1 (C4), E3.2 (C5), E3.6 (C12)
  gate_ready || { verdict C4 FAIL "no gate token"; exit 1; }
  A=$(mkrun "gate creates A" gate "ready pr-1" "block:red-team:r1" failure '{"kind":"block","state":"open"}')
  [ -n "$A" ] || { verdict C4 FAIL "the gate App could not create a check run"; exit 1; }
  echo "$A" > "$OUT/check-run-A.txt"
  c1=$(patch_run "github.token updates A" gha "$A" success)
  snap "after github.token's update" "$A"
  still=$(jq -r 'select(.id == '"$A"') | .conclusion' "$SNAPS" | tail -1)
  c2=$(patch_run "gate updates A" gate "$A" success)
  B=$(mkrun "github.token creates B with an accept key" gha "ready pr-1" "accept:0000000000000000000000000000000000000000" neutral '{"kind":"accept"}')
  c3=$( [ -n "$B" ] && patch_run "gate updates B" gate "$B" failure || echo none)
  if refused "$c1" && [ "$still" = failure ] && [ "$c2" = 200 ] && refused "$c3"; then
    verdict C4 PASS "github.token's update of A: $c1, A stayed failure; gate's update of A: $c2; gate's update of github.token's B: $c3"
  else
    verdict C4 FAIL "github.token's update of A: $c1 (A now $still); gate's update of A: $c2; gate's update of B: $c3"
  fi
  [ -n "$B" ] && verdict C4b MEASURED "github.token CAN create an entry named 'ready pr-1' on the ledger commit (B=$B): round 4 B1's premise holds" \
              || verdict C4b MEASURED "github.token could NOT create a check run here"
  # C5: no delete.
  d1=$(call "gate deletes A" gate DELETE "repos/$R/check-runs/$A")
  d2=$(call "github.token deletes A" gha DELETE "repos/$R/check-runs/$A")
  suite=$(jq -r "select(.id == $A) | .suite" "$SNAPS" | tail -1)
  d3=$(call "gate deletes A's suite" gate DELETE "repos/$R/check-suites/$suite")
  d4=$(call "github.token deletes A's suite" gha DELETE "repos/$R/check-suites/$suite")
  g=$(call "read A after the deletes" gha GET "repos/$R/check-runs/$A")
  if refused "$d1" && refused "$d2" && refused "$d3" && refused "$d4" && [ "$g" = 200 ]; then
    verdict C5 PASS "DELETE on the run: $d1 (gate), $d2 (github.token); on the suite: $d3, $d4; A still reads $g"
  else
    verdict C5 FAIL "DELETE on the run: $d1, $d2; on the suite: $d3, $d4; A reads $g"
  fi
  # C12: exact names and the app_id filter.
  P4=$(mkrun "gate creates pr-4" gate "ready pr-4" "genesis" neutral '{"kind":"genesis"}')
  P41=$(mkrun "gate creates pr-41" gate "ready pr-41" "genesis" neutral '{"kind":"genesis"}')
  read_ledger "pr-4 read" gha "ready pr-4" "$(gate_id)"
  names=$(jq -c '[.[].name] | unique' "$RUNNER_TEMP/ledger.json")
  [ "$names" = '["ready pr-4"]' ] && verdict C12a PASS "check_name=ready pr-4 returned only ready pr-4 ($P4, not $P41)" \
                                  || verdict C12a FAIL "check_name=ready pr-4 returned $names"
  read_ledger "pr-1 read, gate only" gha "ready pr-1" "$(gate_id)"
  apps=$(jq -c '[.[].app_id] | unique' "$RUNNER_TEMP/ledger.json")
  [ "$apps" = "[$(gate_id)]" ] && verdict C12b PASS "app_id filter returned only the gate App's entries" \
                               || verdict C12b FAIL "app_id filter returned app ids $apps"
  ;;

delete-run) # E3.2 (C5, second half): deleting the Actions run that wrote an entry
  c=$(call "github.token deletes Actions run $TARGET_RUN" gha DELETE "repos/$R/actions/runs/$TARGET_RUN")
  g=$(call "read the entry afterwards" gha GET "repos/$R/check-runs/$CHECK_RUN")
  [ "$g" = 200 ] && verdict C5b PASS "after DELETE actions/runs/$TARGET_RUN ($c), check run $CHECK_RUN still reads 200" \
                 || verdict C5b FAIL "after DELETE actions/runs/$TARGET_RUN ($c), check run $CHECK_RUN reads $g"
  ;;

output-limit) # E3.3 (C6)
  gate_ready || exit 1
  gen() { python3 -c "import sys; sys.stdout.write(sys.argv[1] * int(sys.argv[2]))" "$1" "$2"; }
  rows="$OUT/limits.jsonl"; : > "$rows"
  for spec in "a 65535" "a 65536" "é 32767" "é 32768" "é 65535"; do
    set -- $spec
    gen "$1" "$2" > "$RUNNER_TEMP/s.txt"
    f=$(body "$RUNNER_TEMP/lim.json" --rawfile s "$RUNNER_TEMP/s.txt" --arg h "$SHA" --arg e "limit-$1-$2" \
      '{name: "lab limit", head_sha: $h, external_id: $e, status: "completed", conclusion: "neutral",
        output: {title: $e, summary: $s}}')
    code=$(call "summary of $2 x '$1'" gate POST "repos/$R/check-runs" "$f")
    stored=null
    if [ "$code" = 201 ]; then
      id=$(jq -r .id "$RUNNER_TEMP/resp.json"); call "read back" gha GET "repos/$R/check-runs/$id" > /dev/null
      stored=$(jq '.output.summary | length' "$RUNNER_TEMP/resp.json")
    fi
    jq -c -n --arg ch "$1" --argjson n "$2" --argjson bytes "$(wc -c < "$RUNNER_TEMP/s.txt")" --arg code "$code" --argjson stored "$stored" \
      '{char: $ch, chars: $n, bytes: $bytes, status: ($code | tonumber), stored_chars: $stored}' >> "$rows"
  done
  ok=$(jq -s -c '[.[] | select(.char == "a")] | map({(.chars | tostring): [.status, .stored_chars]}) | add' "$rows")
  if [ "$(jq -s '[.[] | select(.char == "a" and .chars == 65535 and .status == 201 and .stored_chars == 65535)] | length' "$rows")" = 1 ] \
     && [ "$(jq -s '[.[] | select(.char == "a" and .chars == 65536 and .status != 201)] | length' "$rows")" = 1 ]; then
    verdict C6 PASS "65,535 ASCII characters stored whole, 65,536 refused: $ok"
  else
    verdict C6 FAIL "ASCII results: $ok"
  fi
  verdict C6b MEASURED "two-byte characters (chars or bytes?): $(jq -s -c '[.[] | select(.char != "a") | {chars, bytes, status, stored_chars}]' "$rows")"
  ;;

visibility) # E3.4 (C7)
  gate_ready || exit 1
  L=$(mkrun "gate creates an entry on the ledger commit" gate "ready pr-1" "genesis" neutral '{"kind":"genesis"}')
  call "check runs at the PR's head" gha GET "repos/$R/commits/$PR_HEAD/check-runs?filter=all&per_page=100" > /dev/null
  n=$(jq '[.check_runs[] | select(.name | startswith("ready pr-"))] | length' "$RUNNER_TEMP/resp.json")
  [ "$n" = 0 ] && verdict C7 PASS "no ledger entry at the PR head $PR_HEAD; entry $L is on $SHA only" \
               || verdict C7 FAIL "$n ledger entries at the PR head $PR_HEAD"
  ;;

read-after-write) # E3.5 (C8)
  gate_ready || exit 1
  N=${N:-100}; rows="$OUT/raw.jsonl"; : > "$rows"
  ms() { date +%s%3N; }
  seen() { # seen WHAT ARG: 0 if visible now
    case "$1" in
      list) call "list" gha GET "repos/$R/commits/$SHA/check-runs?check_name=$2&app_id=$(gate_id)&filter=all" > /dev/null
            [ "$(jq '.check_runs | length' "$RUNNER_TEMP/resp.json")" -ge 1 ] ;;
      id) [ "$(call "get" gha GET "repos/$R/check-runs/$2")" = 200 ] ;;
      done) call "get" gha GET "repos/$R/check-runs/$2" > /dev/null; [ "$(jq -r .conclusion "$RUNNER_TEMP/resp.json")" = success ] ;;
      status) call "statuses" gha GET "repos/$R/commits/$SHA/statuses?per_page=100" > /dev/null
              [ "$(jq --arg c "$2" '[.[] | select(.context == $c)] | length' "$RUNNER_TEMP/resp.json")" -ge 1 ] ;;
    esac
  }
  lag() { # lag WHAT ARG T0: first-read result and ms until visible (capped at 30 s)
    local first=true; seen "$1" "$2" || first=false
    if [ "$first" = false ]; then
      while ! seen "$1" "$2"; do sleep 0.25; [ $(( $(ms) - $3 )) -gt 30000 ] && break; done
    fi
    printf '%s %s' "$first" $(( $(ms) - $3 ))
  }
  for i in $(seq 1 "$N"); do
    t0=$(ms); id=$(mkrun "raw $i" gate "raw-$i" "raw:$i" failure '{"kind":"raw"}'); t1=$(ms)
    read -r lf ll <<<"$(lag list "raw-$i" "$t1")"
    read -r if_ il <<<"$(lag id "$id" "$t1")"
    patch_run "raw $i complete" gate "$id" success > /dev/null; t2=$(ms)
    read -r pf pl <<<"$(lag done "$id" "$t2")"
    f=$(body "$RUNNER_TEMP/st.json" --arg c "raw/$i" '{state: "failure", context: $c, description: "lab read-after-write"}')
    call "status raw/$i" gate POST "repos/$R/statuses/$SHA" "$f" > /dev/null; t3=$(ms)
    read -r sf sl <<<"$(lag status "raw/$i" "$t3")"
    jq -c -n --argjson i "$i" --argjson w $((t1 - t0)) --argjson lf "$lf" --argjson ll "$ll" --argjson if_ "$if_" --argjson il "$il" \
      --argjson pf "$pf" --argjson pl "$pl" --argjson sf "$sf" --argjson sl "$sl" \
      '{round: $i, write_ms: $w, list: {first: $lf, ms: $ll}, by_id: {first: $if_, ms: $il},
        after_update: {first: $pf, ms: $pl}, status: {first: $sf, ms: $sl}}' >> "$rows"
    sleep 1
    [ $((i % 25)) = 0 ] && wait_rate gha
  done
  miss=$(jq -s '[.[] | select((.list.first and .by_id.first and .after_update.first and .status.first) | not)] | length' "$rows")
  stats=$(jq -s -c '{list_max_ms: (map(.list.ms) | max), update_max_ms: (map(.after_update.ms) | max), status_max_ms: (map(.status.ms) | max)}' "$rows")
  [ "$miss" = 0 ] && verdict C8 PASS "all $N rounds visible on the first read (list, by id, after update, status); $stats" \
                  || verdict C8 MEASURED "$miss of $N rounds not visible on the first read; $stats"
  ;;

rerequest) # E3.6 (C9, C10)
  gate_ready || exit 1
  R1=$(mkrun "gate creates block R1" gate "ready pr-1" "block:red-team:r1" failure '{"kind":"block","state":"open","text":"lab"}')
  R2=$(mkrun "gate creates genesis R2" gate "ready pr-1" "genesis" neutral '{"kind":"genesis"}')
  S=$(jq -r .check_suite.id "$RUNNER_TEMP/resp.json")
  both() { snap "$1" "$R1" "$R2"; snap_suite "$1" "$S"; read_ledger "$1" gha "ready pr-1" "$(gate_id)"; }
  repair() {
    for pair in "$R1 failure" "$R2 neutral"; do
      set -- $pair
      call "repair check $1" gha GET "repos/$R/check-runs/$1" > /dev/null
      if [ "$(jq -r '.status + "/" + (.conclusion // "null")' "$RUNNER_TEMP/resp.json")" != "completed/$2" ]; then
        patch_run "repair $1 to $2" gate "$1" "$2" > /dev/null
      fi
    done
  }
  both "0 created"
  for who in gha gate; do
    c=$(call "$who re-requests run R1" "$who" POST "repos/$R/check-runs/$R1/rerequest")
    sleep 5; both "run re-requested by $who ($c)"; repair; both "repaired after run re-request by $who"
  done
  for who in gha gate; do
    c=$(call "$who re-requests suite" "$who" POST "repos/$R/check-suites/$S/rerequest")
    sleep 5; both "suite re-requested by $who ($c)"; repair; both "repaired after suite re-request by $who"
  done
  changed=$(jq -s -c --arg r1 "$R1" '[.[] | select(.kind == "run" and (.id | tostring) == $r1)] as $s
    | {status: ([$s[].status] | unique), conclusion: ([$s[].conclusion] | unique), summary_sha256: ([$s[].summary_sha256] | unique | length)}' "$SNAPS")
  suite_states=$(jq -s -c '[.[] | select(.kind == "suite") | {label, status, conclusion}]' "$SNAPS")
  verdict C9-C10 MEASURED "R1 across all snapshots: $changed; suite: $suite_states"
  if [ "$(jq -r .summary_sha256 <<<"$changed")" = 1 ]; then
    verdict C9a PASS "R1's output survived every re-request (one summary hash across snapshots)"
  else
    verdict C9a FAIL "R1's output changed across snapshots (round 5 N1: the JSON can be lost)"
  fi
  final=$(jq -s -r --arg r1 "$R1" '[.[] | select(.kind == "run" and (.id | tostring) == $r1)] | last | .status + "/" + (.conclusion // "null")' "$SNAPS")
  [ "$final" = completed/failure ] && verdict C9b PASS "the gate App's repair restores R1 to completed/failure" \
                                   || verdict C9b FAIL "after repair R1 is $final"
  ;;

flood-seed) # E3.7 (C11), before the flood
  gate_ready || exit 1
  mkrun "seed genesis" gate "ready pr-1" "genesis" neutral '{"kind":"genesis"}' > /dev/null
  mkrun "seed block" gate "ready pr-1" "block:red-team:r1" failure '{"kind":"block","state":"open"}' > /dev/null
  mkrun "seed accept" gate "ready pr-1" "accept:$SHA" neutral '{"kind":"accept"}' > /dev/null
  read_ledger "seeded" gha "ready pr-1" "$(gate_id)"
  verdict C11-seed MEASURED "seeded $(jq length "$RUNNER_TEMP/ledger.json") entries in suite $(jq -r '.[0].suite' "$RUNNER_TEMP/ledger.json")"
  ;;

flood-after) # E3.7 (C11), after the flood: does a new write bring the App's suite back into the read?
  gate_ready || exit 1
  read_ledger "after flood, before write" gha "ready pr-1" "$(gate_id)"; before=$(jq length "$RUNNER_TEMP/ledger.json")
  mkrun "write after flood" gate "ready pr-1" "genesis-2" neutral '{"kind":"genesis"}' > /dev/null
  read_ledger "after flood, after write" gha "ready pr-1" "$(gate_id)"; after=$(jq length "$RUNNER_TEMP/ledger.json")
  verdict C11-after MEASURED "entries read before the new write: $before; after it: $after (4 means the suite is back in the read)"
  ;;

cap-gate) # E4 (C13), the gate App's half, after cap-fill
  gate_ready || exit 1
  f=$(body "$RUNNER_TEMP/st.json" '{state: "failure", context: "ready", description: "lab: gate App after the cap"}')
  c1=$(call "gate posts ready after the fill" gate POST "repos/$R/statuses/$SHA" "$f")
  f=$(body "$RUNNER_TEMP/st.json" '{state: "failure", context: "ready-other", description: "lab: another context"}')
  c2=$(call "gate posts another context" gate POST "repos/$R/statuses/$SHA" "$f")
  call "combined status" gha GET "repos/$R/commits/$SHA/status" > /dev/null
  shown=$(jq -c '[.statuses[] | select(.context == "ready") | {state, description, creator: .creator.login}]' "$RUNNER_TEMP/resp.json")
  if refused "$c1" && [ "$c2" = 201 ]; then
    verdict C13b PASS "after the fill, the gate App can't write 'ready' ($c1) but can write another context ($c2): R10's case stands; combined shows $shown"
  else
    verdict C13b MEASURED "gate App 'ready' after the fill: $c1; another context: $c2; combined shows $shown"
  fi
  ;;

gc-reread) # E3.8 (C16): re-read every entry written so far
  read_ledger "re-read pr-1" gha "ready pr-1" "$APP_ID"
  verdict C16 MEASURED "$(jq length "$RUNNER_TEMP/ledger.json") gate entries named 'ready pr-1' on $SHA at $(date -u +%FT%TZ)"
  ;;

*) echo "unknown step $step" >&2; exit 2 ;;
esac

for f in "$OUT"/*; do
  [ -s "$f" ] || continue
  base=$(basename "$f")
  case "$base" in *.jsonl) pretty "$f"; base=${base%.jsonl}.json ;; esac
  "$here/save.sh" "$step/$GITHUB_RUN_ID/$base" "$f"
done
