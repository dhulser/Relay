#!/bin/bash
# What we can know about Relay's reach without putting anything in the app.
#
#   Relay.dmg downloads   people who fetched the installer (per release)
#   appcast.xml fetches   update checks: every install asks about once a day,
#                         so day-over-day growth in this number is roughly the
#                         count of active installs
#   repo traffic          GitHub's own 14-day view/clone counts and referrers
#
# Nothing here comes from the app. It sends no telemetry, and this script only
# reads counters GitHub keeps for every public repository.
set -euo pipefail
REPO="dhulser/Relay"

printf "\033[1mReleases\033[0m\n"
gh api "repos/$REPO/releases" --jq '
  .[] | "  \(.tag_name)  (\(.published_at[:10]))",
        (.assets[] | select(.name == "Relay.dmg")   | "      downloads       \(.download_count)"),
        (.assets[] | select(.name == "appcast.xml") | "      update checks   \(.download_count)")'

printf "\n\033[1mSite and repo, last 14 days\033[0m\n"
gh api "repos/$REPO/traffic/views"  --jq '"  repo views      \(.count)  (\(.uniques) people)"'
gh api "repos/$REPO/traffic/clones" --jq '"  clones          \(.count)  (\(.uniques) people)"'
REFERRERS="$(gh api "repos/$REPO/traffic/popular/referrers" --jq '.[] | "  \(.referrer): \(.count)"' 2>/dev/null || true)"
[ -n "$REFERRERS" ] && { printf "  referrers\n"; printf '%s\n' "$REFERRERS" | sed 's/^/  /'; }

printf "\n\033[1mHomebrew\033[0m\n"
echo "  brew's public analytics cover core casks only; a third-party tap is not counted."
