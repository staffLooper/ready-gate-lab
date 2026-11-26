#!/usr/bin/env bash
# Shared helpers for the chunk 0 experiment (EXPERIMENT.md). Sourced by the other scripts; runs in CI.
#
# call LABEL WHO METHOD PATH [BODY_FILE]
#   Makes one REST call as WHO (gate = the gate App's installation token, gha = github.token, anon = no token),
#   appends one record to $LOG (label, who, method, path, HTTP status, time, response) and prints the status.
#   Long `summary` and `text` strings in a response are replaced in the log by their length.
#   Tokens are never written anywhere but $RUNNER_TEMP/gate-token (mode 600, made by app-token.sh).
set -euo pipefail

: "${LOG:=$RUNNER_TEMP/calls.jsonl}"
: "${VERDICTS:=$RUNNER_TEMP/verdicts.jsonl}"
API=${API:-https://api.github.com}

token_for() {
  case "$1" in
    gate) cat "$RUNNER_TEMP/gate-token" ;;
    gha) printf '%s' "${GHA_TOKEN:?GHA_TOKEN is not set}" ;;
    anon) printf '' ;;
    *) echo "unknown caller $1" >&2; return 1 ;;
  esac
}

call() {
  local label=$1 who=$2 method=$3 path=$4 body=${5:-}
  local tok; tok=$(token_for "$who")
  local args=(-sS -o "$RUNNER_TEMP/resp" -D "$RUNNER_TEMP/headers" -w '%{http_code}' -X "$method"
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  [ -n "$tok" ] && args+=(-H "Authorization: Bearer $tok")
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data-binary "@$body")
  local code; code=$(curl "${args[@]}" "$API/$path") || code=0
  [ -s "$RUNNER_TEMP/resp" ] || echo 'null' > "$RUNNER_TEMP/resp"
  jq -c . "$RUNNER_TEMP/resp" > "$RUNNER_TEMP/resp.json" 2>/dev/null || jq -n --rawfile r "$RUNNER_TEMP/resp" '{unparsed: $r}' > "$RUNNER_TEMP/resp.json"
  local limit; limit=$(grep -i '^x-ratelimit-remaining:' "$RUNNER_TEMP/headers" | tr -dc '0-9' || true)
  jq -c -n --arg label "$label" --arg who "$who" --arg method "$method" --arg path "$path" \
    --arg code "$code" --arg at "$(date -u +%FT%T.%3NZ)" --arg limit "${limit:-}" \
    --slurpfile resp "$RUNNER_TEMP/resp.json" '
    def shorten: walk(if type == "object" then with_entries(
        if (.key == "summary" or .key == "text") and (.value | type) == "string" and (.value | length) > 400
        then .value = {length: (.value | length), note: "shortened in the log; steps that need it hash it"}
        else . end) else . end);
    {$label, $who, $method, $path, status: ($code | tonumber), $at, ratelimit_remaining: $limit,
     response: ($resp[0] | shorten)}' >> "$LOG"
  echo "$code"
}

# body FILE JQ_FILTER [jq args...]: writes a JSON request body built by jq.
body() { local f=$1; shift; jq -n "$@" > "$f"; echo "$f"; }

# last_response: the full response of the most recent call.
last_response() { cat "$RUNNER_TEMP/resp.json"; }

# wait_rate WHO: sleeps until the caller's primary rate limit resets if fewer than 20 requests remain.
wait_rate() {
  local tok; tok=$(token_for "$1")
  local r; r=$(curl -sS -H "Authorization: Bearer $tok" "$API/rate_limit")
  local left reset; left=$(jq -r .resources.core.remaining <<<"$r"); reset=$(jq -r .resources.core.reset <<<"$r")
  if [ "$left" -lt 20 ]; then
    local s=$(( reset - $(date +%s) + 5 )); echo "rate limit: $left left; sleeping ${s}s"; sleep "$s"
  fi
}

# verdict ID PASS|FAIL|MEASURED TEXT: one reading line, kept in $VERDICTS and the job summary.
verdict() {
  jq -c -n --arg id "$1" --arg reading "$2" --arg text "$3" '{id: $id, reading: $reading, text: $text}' >> "$VERDICTS"
  echo "- **$1: $2.** $3" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

# pretty FILE: rewrites a JSON or JSON-lines file as one pretty-printed, key-sorted JSON array (chat rule 13).
pretty() { jq -S -s . "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
