#!/usr/bin/env bash
# Verify gate: can we authenticate to corporate Exchange EWS (NTLM) and read the calendar?
# Credentials are read locally, sent ONLY to $EXCHANGE_HOST over HTTPS via NTLM. Never logged.
set -u

# Config from .env (gitignored) — see .env.example. No host or login in git.
[ -f "$(dirname "$0")/.env" ] && . "$(dirname "$0")/.env"
: "${EXCHANGE_HOST:?set EXCHANGE_HOST in .env}"

EWS="https://${EXCHANGE_HOST}/EWS/Exchange.asmx"

echo "Corporate Exchange EWS verify gate"
echo "Endpoint: $EWS"
echo
echo "Username format to try (pick what Apple Calendar uses):"
echo "  - DOMAIN\\login          (down-level logon name)"
echo "  - login@${EXCHANGE_HOST}  (UPN)"
echo
read -r -p "Username: " USER_IN
read -r -s -p "Password: " PASS_IN
echo
echo

# 1) Authenticated GET on the .asmx — returns 200 (WSDL) when auth succeeds.
echo "[1/2] NTLM auth check (GET WSDL)..."
CODE=$(curl -s -o /dev/null -m 20 --ntlm -u "${USER_IN}:${PASS_IN}" -w "%{http_code}" "$EWS")
echo "    HTTP $CODE  (200 = auth OK, 401 = bad creds/username format)"

if [ "$CODE" != "200" ]; then
  echo
  echo "AUTH FAILED. Try the other username format, or check VPN/proxy."
  unset PASS_IN
  exit 1
fi

# 2) Minimal EWS SOAP: resolve the default Calendar folder to prove calendar access.
echo "[2/2] EWS GetFolder(calendar)..."
REQ=$(cat <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
 xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"
 xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
 <soap:Header><t:RequestServerVersion Version="Exchange2013"/></soap:Header>
 <soap:Body>
  <m:GetFolder>
   <m:FolderShape><t:BaseShape>Default</t:BaseShape></m:FolderShape>
   <m:FolderIds><t:DistinguishedFolderId Id="calendar"/></m:FolderIds>
  </m:GetFolder>
 </soap:Body>
</soap:Envelope>
XML
)
RESP=$(curl -s -m 25 --ntlm -u "${USER_IN}:${PASS_IN}" \
  -H 'Content-Type: text/xml; charset=utf-8' \
  --data "$REQ" "$EWS")
unset PASS_IN

if echo "$RESP" | grep -q "NoError"; then
  COUNT=$(echo "$RESP" | grep -o '<t:TotalCount>[0-9]*</t:TotalCount>' | grep -o '[0-9]*' | head -1)
  echo "    SUCCESS. Calendar folder reachable. Items in calendar: ${COUNT:-?}"
  echo
  echo "GATE PASSED. DavMail (EWS + NTLM) should work. Note the username format that worked."
else
  echo "    Auth OK but GetFolder failed. Response head:"
  echo "$RESP" | head -c 600
  echo
  echo "GATE PARTIAL: authenticated, but calendar access needs a closer look."
fi
