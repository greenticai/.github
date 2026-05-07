#!/usr/bin/env bash
# train-stall-monitor.sh — Detect long-running pre-release lanes
#
# For each non-archived repo in REPO_MANIFEST.toml, reads develop's Cargo.toml.
# If the package version has a pre-release suffix (-dev.N / -alpha / -beta /
# -rc) AND the "chore: start X.Y pre-release lane" PR that introduced it is
# older than STALL_THRESHOLD_DAYS, add the repo to the stall list.
#
# Non-zero stall list → emit a Slack alert (via webhook). Zero stalls → noop.
#
# Environment:
#   GH_TOKEN_GREENTICAI       — App token scoped to greenticai org installation
#   GH_TOKEN_GREENTIC_BIZ     — App token scoped to greentic-biz org installation
#   GH_TOKEN                  — Fallback when per-org tokens aren't set (e.g. local runs)
#   SLACK_WEBHOOK_RELEASE_ALERTS — webhook URL (optional; if unset, log only)
#   STALL_THRESHOLD_DAYS      — (optional) stall threshold, default 30
#   INPUT_DRY_RUN             — (optional) "true" skips webhook POST

set -euo pipefail

MANIFEST="toolchain/REPO_MANIFEST.toml"
THRESHOLD_DAYS="${STALL_THRESHOLD_DAYS:-30}"
DRY_RUN="${INPUT_DRY_RUN:-false}"

# Per-org tokens, with single-token fallback for local invocation.
GH_TOKEN_GREENTICAI="${GH_TOKEN_GREENTICAI:-${GH_TOKEN:-}}"
GH_TOKEN_GREENTIC_BIZ="${GH_TOKEN_GREENTIC_BIZ:-${GH_TOKEN:-}}"

log()  { echo "$1"; }
warn() { echo "::warning::$1"; }
err()  { echo "::error::$1"; }

token_for_org() {
  case "$1" in
    greenticai)   echo "$GH_TOKEN_GREENTICAI" ;;
    greentic-biz) echo "$GH_TOKEN_GREENTIC_BIZ" ;;
    *)            echo "::error::Unknown org '$1' — no token available" >&2; return 1 ;;
  esac
}

# Reachability precheck. Catches token-scope or App-installation gaps so we
# don't silently mis-skip a whole org as "no version on develop".
repo_reachable() {
  local repo="$1"
  gh api "repos/$repo" --silent 2>/dev/null
}

# ── Parse manifest — emit "org\tname" for every non-archived repo ─
get_repos() {
  python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
for name, entry in m.get('repos', {}).items():
    if entry.get('archived', False):
        continue
    print(f\"{entry['org']}\t{name}\")
"
}

# ── Read develop's Cargo.toml version via API ────────────────────
get_develop_version() {
  local repo="$1"
  gh api "repos/$repo/contents/Cargo.toml?ref=develop" --jq '.content' 2>/dev/null \
    | base64 -d 2>/dev/null \
    | python3 -c "
import sys, tomllib
try:
    data = tomllib.load(sys.stdin.buffer)
except Exception:
    sys.exit(1)
ws = data.get('workspace', {}).get('package', {})
pkg = data.get('package', {})
ver = ws.get('version') or pkg.get('version')
if ver:
    print(ver)
else:
    sys.exit(1)
" 2>/dev/null
}

# ── Pre-release detection ────────────────────────────────────────
is_pre_release() {
  [[ "$1" == *-dev.* || "$1" == *-alpha.* || "$1" == *-beta.* || "$1" == *-rc.* ]]
}

# ── Find start-next-minor.sh PR merge date ───────────────────────
# Searches merged PRs whose title matches "chore: start <major>.<minor> pre-release lane".
# Outputs ISO-8601 mergedAt, or empty if not found.
find_start_lane_pr_date() {
  local repo="$1"
  local version="$2"
  # Extract the X.Y prefix (e.g., "0.6.0-dev.0" → "0.6")
  local mm
  mm=$(echo "$version" | python3 -c "
import re, sys
v = sys.stdin.read().strip()
m = re.match(r'(\d+)\.(\d+)\.', v)
if m:
    print(f'{m.group(1)}.{m.group(2)}')
")
  [[ -z "$mm" ]] && return 0

  gh pr list --repo "$repo" --state merged --base develop \
    --search "chore: start ${mm} pre-release in:title" \
    --json mergedAt --jq '.[0].mergedAt // empty' 2>/dev/null
}

# ── Compute days-since given an ISO-8601 timestamp ───────────────
days_since() {
  local iso_date="$1"
  python3 -c "
from datetime import datetime, timezone
d = datetime.fromisoformat('$iso_date'.replace('Z', '+00:00'))
delta = datetime.now(timezone.utc) - d
print(delta.days)
"
}

# ── Main ─────────────────────────────────────────────────────────

log "Train Stall Monitor — $(date -u '+%Y-%m-%d %H:%M UTC')"
log "Threshold: ${THRESHOLD_DAYS} days"
log "Dry run: $DRY_RUN"
log ""

if [[ ! -f "$MANIFEST" ]]; then
  err "Missing manifest: $MANIFEST"
  exit 1
fi

stall_list=""
stall_count=0
prerelease_count=0
checked=0

while IFS=$'\t' read -r org name; do
  full="$org/$name"
  ((checked++)) || true

  # Per-org App token for `gh api` calls below.
  GH_TOKEN="$(token_for_org "$org")" || continue
  if [[ -z "$GH_TOKEN" ]]; then
    warn "$name — no token available for org '$org', skipping"
    continue
  fi
  export GH_TOKEN

  if ! repo_reachable "$full"; then
    warn "$name — repo unreachable (token scope or App not installed in '$org'?), skipping"
    continue
  fi

  ver=$(get_develop_version "$full" 2>/dev/null || echo "")
  [[ -z "$ver" ]] && continue

  if ! is_pre_release "$ver"; then
    continue
  fi
  ((prerelease_count++)) || true

  # Repo IS on a pre-release. Check how old.
  start_date=$(find_start_lane_pr_date "$full" "$ver")
  if [[ -z "$start_date" ]]; then
    warn "$name — on pre-release $ver but could not find start-lane PR (age unknown)"
    continue
  fi

  days=$(days_since "$start_date")
  if (( days > THRESHOLD_DAYS )); then
    log "  ⚠ $name — on $ver for $days days (start: $start_date)"
    stall_list="${stall_list:+$stall_list\n}• *$name* — \`$ver\` for ${days} days (started $start_date)"
    ((stall_count++)) || true
  else
    log "  ✓ $name — on $ver for $days days (within threshold)"
  fi
done < <(get_repos)

log ""
log "━━━ Summary ━━━"
log "  Repos checked:           $checked"
log "  On pre-release:          $prerelease_count"
log "  Stalled (> ${THRESHOLD_DAYS} d):  $stall_count"
log ""

# GitHub Actions step summary
cat >> "${GITHUB_STEP_SUMMARY:-/dev/null}" <<EOF
## Train Stall Monitor — $(date -u '+%Y-%m-%d')

| Metric | Count |
|--------|-------|
| Repos checked | $checked |
| On pre-release lane | $prerelease_count |
| Stalled (> ${THRESHOLD_DAYS} days) | $stall_count |
EOF

if [[ "$stall_count" -eq 0 ]]; then
  log "No stalled pre-release lanes. All good."
  exit 0
fi

# Emit Slack alert when stalls exist. Skip in dry-run or when webhook unset.
if [[ "$DRY_RUN" == "true" ]]; then
  log "[dry-run] Would post to Slack:"
  echo -e "$stall_list" | sed 's/^/    /'
  exit 0
fi

if [[ -z "${SLACK_WEBHOOK_RELEASE_ALERTS:-}" ]]; then
  warn "SLACK_WEBHOOK_RELEASE_ALERTS unset; skipping Slack post (stalls logged above)"
  exit 0
fi

# Slack payload (block kit — matches existing notify-* workflows' style).
payload=$(python3 -c "
import json, os
stall_md = '''$(echo -e "$stall_list")'''
threshold = os.environ.get('THRESHOLD_DAYS', '30')
count = '$stall_count'
print(json.dumps({
    'blocks': [
        {
            'type': 'header',
            'text': {
                'type': 'plain_text',
                'text': f'🚉 Pre-release train stall detected ({count} repo(s))'
            }
        },
        {
            'type': 'section',
            'text': {
                'type': 'mrkdwn',
                'text': f'These repos have been on a pre-release lane for more than {threshold} days. Either cut a minor (merge the next weekly-stable-prepare PR) or revert develop to stable.\n\n{stall_md}'
            }
        },
        {
            'type': 'context',
            'elements': [{
                'type': 'mrkdwn',
                'text': 'Source: train-stall-monitor.yml · See plans/pre-release-minor-bump-lane.md Phase 4'
            }]
        }
    ]
}))
")

if curl -sS -X POST \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$SLACK_WEBHOOK_RELEASE_ALERTS" \
    >/dev/null; then
  log "Slack alert posted."
else
  err "Slack webhook POST failed"
  exit 1
fi
