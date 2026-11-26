#!/usr/bin/env bash
# save.sh DEST FILE: commits FILE to the results branch (default lab/results) at runs/DEST, with github.token.
# Every captured output goes through here, so the results PR (practice 3.8) holds exactly what the runs saw.
# github.token's pushes start no workflows, so saving never triggers another run.
set -euo pipefail
dest="runs/$1"; src="$2"
branch="${RESULTS_BRANCH:-lab/results}"
repo="$GITHUB_REPOSITORY"
export GH_TOKEN="${GHA_TOKEN:?GHA_TOKEN is not set}"
req="$RUNNER_TEMP/save-body.json"
for try in 1 2 3 4 5 6; do
  sha=$(gh api "repos/$repo/contents/$dest?ref=$branch" --jq .sha 2>/dev/null || true)
  jq -n --rawfile c <(base64 -w0 < "$src") --arg m "lab: $dest (run $GITHUB_RUN_ID)" --arg b "$branch" --arg s "$sha" \
    '{message: $m, content: $c, branch: $b} + (if $s == "" then {} else {sha: $s} end)' > "$req"
  if gh api -X PUT "repos/$repo/contents/$dest" --input "$req" > /dev/null; then
    echo "saved $dest to $branch"; exit 0
  fi
  sleep $(( try * 4 ))
done
echo "::error::could not save $dest to $branch"; exit 1
