#!/bin/bash
# Creates a company on Relay: its name, email domains, identity provider and
# first admins. Run once per company, from your own terminal, with the values
# in the environment so none of them land in a file or in shell history
# beyond this line.
#
#   BOOTSTRAP_SECRET=… IDP_CLIENT_ID=… IDP_CLIENT_SECRET=… \
#     ./scripts/org-bootstrap.sh kevel "Kevel" kevel.co dhulser@kevel.co
#
# Arguments: <slug> <name> <domain[,domain…]> [admin-email[,admin-email…]]
# IDP_ISSUER defaults to Google Workspace. For Microsoft Entra use
#   https://login.microsoftonline.com/<tenant-id>/v2.0
set -euo pipefail
: "${BOOTSTRAP_SECRET:?}" "${IDP_CLIENT_ID:?}" "${IDP_CLIENT_SECRET:?}"
SLUG="${1:?slug}"; NAME="${2:?name}"; DOMAINS="${3:?domains}"; ADMINS="${4:-}"
API="${RELAY_API:-https://relay-api.onethreefive.workers.dev}"
ISSUER="${IDP_ISSUER:-https://accounts.google.com}"

python3 - "$SLUG" "$NAME" "$DOMAINS" "$ADMINS" "$ISSUER" "$IDP_CLIENT_ID" "$IDP_CLIENT_SECRET" <<'PY' > /tmp/relay-org.json
import json, sys
slug, name, domains, admins, issuer, cid, secret = sys.argv[1:]
print(json.dumps({
  "id": slug, "name": name,
  "domains": [d.strip() for d in domains.split(",") if d.strip()],
  "adminEmails": [a.strip() for a in admins.split(",") if a.strip()],
  "idp": {"issuer": issuer, "clientId": cid, "clientSecret": secret},
}))
PY
curl -fsS -X POST "$API/admin/bootstrap" -H "authorization: Bearer $BOOTSTRAP_SECRET" \
  -H "content-type: application/json" --data-binary @/tmp/relay-org.json
rm -f /tmp/relay-org.json
echo
echo "Now open $API/admin/login and sign in with an admin address to add the provider key."
