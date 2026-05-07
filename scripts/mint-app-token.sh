#!/usr/bin/env bash
# mint-app-token.sh — Mint a fresh GitHub App installation access token.
#
# Usage: mint-app-token.sh <owner>
#   <owner>  org login: "greenticai" or "greentic-biz"
#
# Env (required):
#   GREENTIC_CI_APP_ID           — numeric App ID
#   GREENTIC_CI_APP_PRIVATE_KEY  — PEM-encoded RS256 private key
#
# Why this exists:
#   actions/create-github-app-token@v2 mints once per workflow step. App
#   installation tokens have a 1-hour TTL. Long-running orchestration scripts
#   (e.g. nightly-develop-orchestrate.sh) outlive the token and stall on 401s
#   in `gh api`/`gh run view` polls. This script lets a script re-mint
#   on demand from the App credentials, which we already pass as secrets.
#
#   It also gives scripts the per-org tokens they need (one App, two
#   installations) without the calling workflow having to mint two upfront.
#
# Output: prints the installation access token to stdout. Exits non-zero on
# failure with an error message on stderr.

set -euo pipefail

owner="${1:-}"
if [[ -z "$owner" ]]; then
  echo "Usage: $0 <owner>" >&2
  exit 2
fi

: "${GREENTIC_CI_APP_ID:?GREENTIC_CI_APP_ID not set}"
: "${GREENTIC_CI_APP_PRIVATE_KEY:?GREENTIC_CI_APP_PRIVATE_KEY not set}"

# Persist private key to a chmod-600 temp file for openssl signing.
key_file=$(mktemp)
trap 'rm -f "$key_file"' EXIT
printf '%s' "$GREENTIC_CI_APP_PRIVATE_KEY" >"$key_file"
chmod 600 "$key_file"

# base64url-encode stdin (RFC 7515): standard base64, strip padding, +/ → -_
b64url() { openssl base64 -e -A | tr -d '=' | tr '/+' '_-'; }

now=$(date +%s)
header='{"alg":"RS256","typ":"JWT"}'
# iat-60s for clock-skew slack; exp+540s = 9-min JWT (max allowed is 10 min).
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
  "$((now - 60))" "$((now + 540))" "$GREENTIC_CI_APP_ID")

h=$(printf '%s' "$header"  | b64url)
p=$(printf '%s' "$payload" | b64url)
sig=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$key_file" -binary | b64url)
jwt="$h.$p.$sig"

# Resolve installation id for this org.
installation_id=$(curl -fsS \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/orgs/$owner/installation" \
  | jq -r '.id // empty')

if [[ -z "$installation_id" ]]; then
  echo "::error::App is not installed on org '$owner' (or installation lookup failed)" >&2
  exit 1
fi

# Mint the installation access token.
token=$(curl -fsS -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/$installation_id/access_tokens" \
  | jq -r '.token // empty')

if [[ -z "$token" ]]; then
  echo "::error::Failed to mint installation access token for '$owner'" >&2
  exit 1
fi

printf '%s' "$token"
