#!/bin/bash
# Creates a company on Relay: its name, email domains, identity provider and
# first admins. Run once per company.
#
#   ./scripts/org-bootstrap.sh kevel "Kevel" kevel.co dhulser@kevel.co
#
# Anything it needs that is not already in the environment is asked for at a
# prompt, hidden when it is a secret, so nothing lands in shell history or in
# `ps`. The bootstrap secret is looked up in your login keychain first:
#
#   security add-generic-password -U -a relay -s relay-bootstrap -w
#
# Arguments: <slug> <name> <domain[,domain…]> [admin-email[,admin-email…]]
# IDP_ISSUER defaults to Google Workspace. For Microsoft Entra use
#   https://login.microsoftonline.com/<tenant-id>/v2.0
set -euo pipefail

SLUG="${1:?usage: org-bootstrap.sh <slug> <name> <domains> [admins]}"
NAME="${2:?usage: org-bootstrap.sh <slug> <name> <domains> [admins]}"
DOMAINS="${3:?usage: org-bootstrap.sh <slug> <name> <domains> [admins]}"
ADMINS="${4:-}"
API="${RELAY_API:-https://api.relay-9cf.workers.dev}"
export IDP_ISSUER="${IDP_ISSUER:-https://accounts.google.com}"

# Read answers from the terminal when there is one, otherwise from stdin, so
# the script can also be driven from a pipe.
if [ -r /dev/tty ] && [ -t 1 ]; then exec 3</dev/tty; else exec 3<&0; fi

# ask <varname> <prompt> [secret] — leaves an already-set variable alone.
ask() {
  local name="$1" prompt="$2" secret="${3:-}" value=""
  [ -n "${!name:-}" ] && return 0
  if [ -n "$secret" ] && [ -t 1 ]; then
    read -rsp "$prompt: " value <&3; echo
  else
    read -rp "$prompt: " value <&3
  fi
  [ -n "$value" ] || { echo "Nothing entered." >&2; exit 1; }
  printf -v "$name" '%s' "$value"
}

: "${BOOTSTRAP_SECRET:=$(security find-generic-password -a relay -s relay-bootstrap -w 2>/dev/null || true)}"
ask BOOTSTRAP_SECRET "Relay bootstrap secret" secret
ask IDP_CLIENT_ID    "Google client ID"
ask IDP_CLIENT_SECRET "Google client secret" secret
export IDP_CLIENT_ID IDP_CLIENT_SECRET

echo "Creating $NAME ($SLUG) for $DOMAINS at ${API}…"

# The body is built from the environment, never from argv, and piped straight
# into curl, so the secret touches neither the process table nor the disk.
# The authorization header goes through a curl config on a file descriptor for
# the same reason.
SLUG="$SLUG" NAME="$NAME" DOMAINS="$DOMAINS" ADMINS="$ADMINS" python3 -c '
import json, os
print(json.dumps({
  "id": os.environ["SLUG"],
  "name": os.environ["NAME"],
  "domains": [d.strip().lower() for d in os.environ["DOMAINS"].split(",") if d.strip()],
  "adminEmails": [a.strip().lower() for a in os.environ["ADMINS"].split(",") if a.strip()],
  "idp": {
    "issuer": os.environ["IDP_ISSUER"].rstrip("/"),
    "clientId": os.environ["IDP_CLIENT_ID"],
    "clientSecret": os.environ["IDP_CLIENT_SECRET"],
  },
}))' | curl -sS --fail-with-body -X POST "$API/admin/bootstrap" \
  --config <(printf 'header = "authorization: Bearer %s"\n' "$BOOTSTRAP_SECRET") \
  -H "content-type: application/json" --data-binary @- || {
  echo >&2
  echo "The API refused that. A 401 means the bootstrap secret is wrong; set a new one with" >&2
  echo "  npx wrangler secret put BOOTSTRAP_SECRET" >&2
  exit 1
}

cat <<OUT

Done. Next:
  1. Open $API/admin/login and sign in with an admin address.
  2. Paste the company's OpenAI key (and Anthropic, for Claude models).
  3. Members: Relay → Settings → Sign in with your company.
OUT
