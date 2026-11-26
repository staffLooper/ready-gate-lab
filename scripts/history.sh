#!/usr/bin/env bash
# history.sh [DAYS]: E5.4, how often GitHub cancelled runs in staffLooper/stafflooper's real history.
# The SESSION runs this from its machine, read-only, with its own `gh` login. stafflooper is private and
# this lab is public, so it writes COUNTS ONLY: per workflow name, event and conclusion. No titles,
# branches, actors, shas or run ids leave stafflooper.
set -euo pipefail
days=${1:-30}
since=$(date -u -d "-$days days" +%F)
repo=staffLooper/stafflooper
tmp=$(mktemp); : > "$tmp"
page=1
while :; do
  gh api "repos/$repo/actions/runs?created=%3E%3D$since&per_page=100&page=$page" \
    --jq '.workflow_runs[] | {name, event, conclusion}' > "$tmp.page"
  cat "$tmp.page" >> "$tmp"
  [ "$(wc -l < "$tmp.page")" -lt 100 ] && break
  page=$((page + 1))
done
jq -S -s --arg since "$since" --arg repo "$repo" '{
  repository: $repo, since: $since, runs: length,
  by_workflow: (group_by(.name) | map({workflow: .[0].name, runs: length,
    cancelled: (map(select(.conclusion == "cancelled")) | length),
    cancelled_by_event: (map(select(.conclusion == "cancelled")) | group_by(.event) | map({(.[0].event): length}) | add // {})}))
}' "$tmp" > history.json
echo "wrote history.json: $(jq .runs history.json) runs since $since"
