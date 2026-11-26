#!/usr/bin/env bash
# burst.sh PR CLONE_DIR: E5's event generator. The SESSION runs this from its machine, after the sponsor's go,
# because events made with github.token start no workflows. It uses the session's own `gh` login; it needs
# no App and no key. CLONE_DIR is a clone of the lab with branch lab/burst checked out (the head of PR).
#
# For each mix x spacing x repetition it sends 3 events to the PR, SPACING seconds apart, then waits GAP
# seconds so every concurrency group drains. It writes burst-log.json (pretty-printed) and commits it to
# lab/results at runs/e5/burst-log.json, where conc-report.sh reads it.
set -euo pipefail
pr=$1; clone=$2
repo=staffLooper/ready-gate-lab
MIXES=${MIXES:-"comments push-first labels"}
SPACINGS=${SPACINGS:-"0 2 5 15"}
REPS=${REPS:-5}
GAP=${GAP:-120}
log=$(mktemp); : > "$log"
ms() { date +%s%3N; }

send() { # send KIND N: one event; prints {kind, sent_at_ms, ref}
  local t ref
  case "$1" in
    comment) t=$(ms); ref=$(gh api "repos/$repo/issues/$pr/comments" -f body="burst event $2" --jq .id) ;;
    push) git -C "$clone" commit -q --allow-empty -m "burst event $2"; t=$(ms); git -C "$clone" push -q origin HEAD:lab/burst; ref=$(git -C "$clone" rev-parse HEAD) ;;
    label) t=$(ms); gh api "repos/$repo/issues/$pr/labels" -f "labels[]=burst-label" > /dev/null; ref=labeled ;;
    unlabel) t=$(ms); gh api -X DELETE "repos/$repo/issues/$pr/labels/burst-label" > /dev/null; ref=unlabeled ;;
  esac
  jq -c -n --arg k "$1" --argjson t "$t" --arg r "$ref" '{kind: $k, sent_at_ms: $t, ref: $r}'
}

n=0; b=0
for mix in $MIXES; do
  case "$mix" in
    comments) kinds="comment comment comment" ;;
    push-first) kinds="push comment comment" ;;
    labels) kinds="label unlabel comment" ;;
  esac
  for spacing in $SPACINGS; do
    for rep in $(seq 1 "$REPS"); do
      b=$((b + 1)); events=()
      for kind in $kinds; do
        n=$((n + 1)); events+=("$(send "$kind" "$n")"); sleep "$spacing"
      done
      printf '%s\n' "${events[@]}" | jq -c -s --argjson b "$b" --arg m "$mix" --argjson s "$spacing" --argjson r "$rep" \
        '{burst: $b, mix: $m, spacing: $s, rep: $r, events: .}' >> "$log"
      echo "burst $b ($mix, ${spacing}s, rep $rep) sent; waiting ${GAP}s"
      sleep "$GAP"
    done
  done
done

jq -S -s . "$log" > burst-log.json
sha=$(gh api "repos/$repo/contents/runs/e5/burst-log.json?ref=lab/results" --jq .sha 2>/dev/null || true)
jq -n --rawfile c <(base64 -w0 < burst-log.json) --arg s "$sha" \
  '{message: "lab: runs/e5/burst-log.json (burst.sh)", content: $c, branch: "lab/results"} + (if $s == "" then {} else {sha: $s} end)' \
  | gh api -X PUT "repos/$repo/contents/runs/e5/burst-log.json" --input - > /dev/null
echo "burst log committed: $b bursts, $n events"
