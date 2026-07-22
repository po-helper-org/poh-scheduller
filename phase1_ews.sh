#!/usr/bin/env bash
# Phase 1 verify: EWS read + write capability, isolated, via curl+NTLM.
# Creates ONLY throwaway self-only events, SendToNone (no mail sent), then deletes them.
# Password read locally, sent only to $EXCHANGE_HOST. Never logged.
set -u

# Config from .env (gitignored) — see .env.example. No host or login in git.
[ -f "$(dirname "$0")/.env" ] && . "$(dirname "$0")/.env"
: "${EXCHANGE_HOST:?set EXCHANGE_HOST in .env}"

EWS="https://${EXCHANGE_HOST}/EWS/Exchange.asmx"
NS='xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"'
HDR='<soap:Header><t:RequestServerVersion Version="Exchange2013"/></soap:Header>'

read -r -p "Username, bare and no domain [${EXCHANGE_USER:-}]: " U
U="${U:-${EXCHANGE_USER:-}}"
: "${U:?username required}"
read -r -s -p "Password: " P; echo; echo
AUTH=(--ntlm -u "${U}:${P}")
CT='-H Content-Type:text/xml;charset=utf-8'

soap () { # $1 = inner body xml -> prints response
  curl -s -m 30 "${AUTH[@]}" -H 'Content-Type: text/xml; charset=utf-8' \
    --data "<?xml version=\"1.0\" encoding=\"utf-8\"?><soap:Envelope $NS>$HDR<soap:Body>$1</soap:Body></soap:Envelope>" "$EWS"
}

pass () { echo "  PASS: $1"; }
fail () { echo "  FAIL: $1"; }

echo "=== T0: ResolveNames (find own primary SMTP) ==="
R=$(soap "<m:ResolveNames ReturnFullContactData=\"false\"><m:UnresolvedEntry>${U}</m:UnresolvedEntry></m:ResolveNames>")
SMTP=$(echo "$R" | grep -o '<t:EmailAddress>[^<]*</t:EmailAddress>' | head -1 | sed 's/<[^>]*>//g')
if [ -n "$SMTP" ]; then pass "own SMTP = $SMTP"; else fail "could not resolve SMTP; using ${U}@${EXCHANGE_HOST}"; SMTP="${U}@${EXCHANGE_HOST}"; fi
echo

echo "=== T1: read a real calendar event (attendees/description/time) ==="
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ); FUT=$(date -u -v+30d +%Y-%m-%dT%H:%M:%SZ)
FI=$(soap "<m:FindItem Traversal=\"Shallow\"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape><m:CalendarView StartDate=\"$NOW\" EndDate=\"$FUT\" MaxEntriesReturned=\"1\"/><m:ParentFolderIds><t:DistinguishedFolderId Id=\"calendar\"/></m:ParentFolderIds></m:FindItem>")
ID=$(echo "$FI" | grep -o 'ItemId Id="[^"]*"' | head -1 | sed 's/.*Id="\([^"]*\)".*/\1/')
if [ -z "$ID" ]; then fail "no events in next 30 days to read"; else
  GI=$(soap "<m:GetItem><m:ItemShape><t:BaseShape>AllProperties</t:BaseShape></m:ItemShape><m:ItemIds><t:ItemId Id=\"$ID\"/></m:ItemIds></m:GetItem>")
  SUBJ=$(echo "$GI" | grep -o '<t:Subject>[^<]*' | head -1 | sed 's/<[^>]*>//')
  ST=$(echo "$GI" | grep -o '<t:Start>[^<]*' | head -1 | sed 's/<[^>]*>//')
  EN=$(echo "$GI" | grep -o '<t:End>[^<]*' | head -1 | sed 's/<[^>]*>//')
  NA=$(echo "$GI" | grep -c '<t:Attendee>')
  HASBODY=$(echo "$GI" | grep -c '<t:Body')
  echo "  Subject: ${SUBJ:-<none>}"; echo "  Start:   ${ST:-<none>}"; echo "  End:     ${EN:-<none>}"
  echo "  Attendees found: $NA   Body present: $([ "$HASBODY" -gt 0 ] && echo yes || echo no)"
  { [ -n "$SUBJ" ] && [ -n "$ST" ]; } && pass "read fidelity OK (demo 4 source)" || fail "some fields missing"
fi
echo

echo "=== T2: create throwaway self-only event (0 attendees, SendToNone) ==="
S=$(date -u -v+1d +%Y-%m-%dT12:00:00Z); E=$(date -u -v+1d +%Y-%m-%dT12:30:00Z)
CR=$(soap "<m:CreateItem SendMeetingInvitations=\"SendToNone\"><m:Items><t:CalendarItem><t:Subject>SYNCTEST-phase1</t:Subject><t:Start>$S</t:Start><t:End>$E</t:End></t:CalendarItem></m:Items></m:CreateItem>")
T2ID=$(echo "$CR" | grep -o 'ItemId Id="[^"]*" ChangeKey="[^"]*"' | head -1)
IID=$(echo "$T2ID" | sed 's/.*Id="\([^"]*\)".*/\1/'); CK=$(echo "$T2ID" | sed 's/.*ChangeKey="\([^"]*\)".*/\1/')
if echo "$CR" | grep -q NoError && [ -n "$IID" ]; then pass "created SYNCTEST at $S (demo 1 source)"; else fail "create failed"; echo "$CR" | head -c 400; fi
echo

echo "=== T3: move that event +1h (UpdateItem, SendToNone) ==="
if [ -n "${IID:-}" ]; then
  S2=$(date -u -v+1d +%Y-%m-%dT13:00:00Z); E2=$(date -u -v+1d +%Y-%m-%dT13:30:00Z)
  UP=$(soap "<m:UpdateItem ConflictResolution=\"AutoResolve\" SendMeetingInvitationsOrCancellations=\"SendToNone\"><m:ItemChanges><t:ItemChange><t:ItemId Id=\"$IID\" ChangeKey=\"$CK\"/><t:Updates><t:SetItemField><t:FieldURI FieldURI=\"calendar:Start\"/><t:CalendarItem><t:Start>$S2</t:Start></t:CalendarItem></t:SetItemField><t:SetItemField><t:FieldURI FieldURI=\"calendar:End\"/><t:CalendarItem><t:End>$E2</t:End></t:CalendarItem></t:SetItemField></t:Updates></t:ItemChange></m:ItemChanges></m:UpdateItem>")
  NCK=$(echo "$UP" | grep -o 'ItemId Id="[^"]*" ChangeKey="[^"]*"' | head -1 | sed 's/.*ChangeKey="\([^"]*\)".*/\1/')
  if echo "$UP" | grep -q NoError; then CK="${NCK:-$CK}"; pass "time write-back to Exchange works (demo 6 source)"; else fail "update failed"; echo "$UP" | head -c 400; fi
else fail "skipped (no T2 id)"; fi
echo

echo "=== T4: create event with SELF as required attendee (SendToNone) ==="
S3=$(date -u -v+2d +%Y-%m-%dT12:00:00Z); E3=$(date -u -v+2d +%Y-%m-%dT12:30:00Z)
CR4=$(soap "<m:CreateItem SendMeetingInvitations=\"SendToNone\"><m:Items><t:CalendarItem><t:Subject>SYNCTEST-attendee</t:Subject><t:Start>$S3</t:Start><t:End>$E3</t:End><t:RequiredAttendees><t:Attendee><t:Mailbox><t:EmailAddress>$SMTP</t:EmailAddress></t:Mailbox></t:Attendee></t:RequiredAttendees></t:CalendarItem></m:Items></m:CreateItem>")
T4=$(echo "$CR4" | grep -o 'ItemId Id="[^"]*" ChangeKey="[^"]*"' | head -1)
IID4=$(echo "$T4" | sed 's/.*Id="\([^"]*\)".*/\1/'); CK4=$(echo "$T4" | sed 's/.*ChangeKey="\([^"]*\)".*/\1/')
if echo "$CR4" | grep -q NoError && [ -n "$IID4" ]; then pass "attendee event accepted (demo 5 source; no mail sent)"; else fail "create-with-attendee failed"; echo "$CR4" | head -c 400; fi
echo

echo "=== cleanup: delete both throwaway events ==="
for pair in "${IID:-}|${CK:-}" "${IID4:-}|${CK4:-}"; do
  I="${pair%%|*}"; K="${pair##*|}"
  [ -z "$I" ] && continue
  D=$(soap "<m:DeleteItem DeleteType=\"HardDelete\" SendMeetingCancellations=\"SendToNone\"><m:ItemIds><t:ItemId Id=\"$I\" ChangeKey=\"$K\"/></m:ItemIds></m:DeleteItem>")
  echo "$D" | grep -q NoError && echo "  deleted 1" || { echo "  delete failed:"; echo "$D" | head -c 300; }
done
unset P
echo; echo "Phase 1 done. Report the PASS/FAIL lines above (no secrets)."
