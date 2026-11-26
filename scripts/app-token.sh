#!/usr/bin/env bash
# app-token.sh OUT_DIR: mints an installation token for the gate App, inside a job that declares
# `environment: staff-gate` (the only place STAFF_GATE_APP_ID and STAFF_GATE_PRIVATE_KEY exist).
#
# Writes OUT_DIR/app.json: the App, its installation, the token's permissions and the repositories it
# reaches. No key, JWT or token is written there or printed. The token goes to $RUNNER_TEMP/gate-token
# (mode 600) for lib.sh's `call gate ...`; the key file is deleted as soon as the JWT is signed.
#
# This mints its own JWT instead of using actions/create-github-app-token because E0 needs the App-level
# read-back (GET /app, GET /repos/{repo}/installation), which needs the JWT.
set -euo pipefail
out="$1"; mkdir -p "$out"
: "${STAFF_GATE_APP_ID:?STAFF_GATE_APP_ID is empty: the job has no staff-gate environment, or the variable is missing}"
: "${STAFF_GATE_PRIVATE_KEY:?STAFF_GATE_PRIVATE_KEY is empty: the job has no staff-gate environment, or the secret is missing}"
umask 077
key="$RUNNER_TEMP/gate.pem"
printf '%s\n' "$STAFF_GATE_PRIVATE_KEY" > "$key"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$STAFF_GATE_APP_ID" | b64url)
s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$key" -binary | b64url)
rm -f "$key"
jwt="$h.$p.$s"
echo "::add-mask::$jwt"
api() { curl -fsS -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }
api https://api.github.com/app > "$RUNNER_TEMP/app.raw"
api "https://api.github.com/repos/$GITHUB_REPOSITORY/installation" > "$RUNNER_TEMP/inst.raw"
inst=$(jq -r .id "$RUNNER_TEMP/inst.raw")
api -X POST "https://api.github.com/app/installations/$inst/access_tokens" > "$RUNNER_TEMP/tok.raw"
tok=$(jq -r .token "$RUNNER_TEMP/tok.raw")
echo "::add-mask::$tok"
printf '%s' "$tok" > "$RUNNER_TEMP/gate-token"
jq '{permissions, repository_selection, expires_at}' "$RUNNER_TEMP/tok.raw" > "$RUNNER_TEMP/tok.json"
rm -f "$RUNNER_TEMP/tok.raw"
curl -fsS -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/installation/repositories?per_page=100" | jq '[.repositories[].full_name]' > "$RUNNER_TEMP/repos.json"
jq -S -n --slurpfile app "$RUNNER_TEMP/app.raw" --slurpfile inst "$RUNNER_TEMP/inst.raw" \
  --slurpfile tok "$RUNNER_TEMP/tok.json" --slurpfile repos "$RUNNER_TEMP/repos.json" '{
    app: ($app[0] | {id, slug, name, owner: .owner.login, permissions, events}),
    installation: ($inst[0] | {id, app_id, repository_selection, permissions, events, target_type, account: .account.login}),
    token: $tok[0],
    installed_repositories: $repos[0]
  }' > "$out/app.json"
echo "gate App $(jq -r .app.slug "$out/app.json") (id $(jq -r .app.id "$out/app.json")): token minted"
