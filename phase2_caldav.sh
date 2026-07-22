#!/usr/bin/env bash
# Phase 2 verify: DavMail CalDAV gateway fidelity + write-through to Exchange.
# DavMail runs in docker (localhost:1080). Password read locally, used for CalDAV
# Basic auth (DavMail forwards to Exchange via NTLM). Never logged.
set -u

# Config from .env (gitignored) — see .env.example. No host or login in git.
[ -f "$(dirname "$0")/.env" ] && . "$(dirname "$0")/.env"
: "${EXCHANGE_HOST:?set EXCHANGE_HOST in .env}"
: "${EXCHANGE_UPN:?set EXCHANGE_UPN in .env}"

CAL="http://127.0.0.1:1080/users/${EXCHANGE_UPN}/calendar/"
EWS="https://${EXCHANGE_HOST}/EWS/Exchange.asmx"

read -r -p "CalDAV/EWS username [${EXCHANGE_USER:-}]: " U
U="${U:-${EXCHANGE_USER:-}}"
: "${U:?username required}"
read -r -s -p "Password: " P; echo; echo
CA=(-u "${U}:${P}")           # CalDAV Basic
EA=(--ntlm -u "${U}:${P}")    # EWS NTLM

pass(){ echo "  PASS: $1"; }
fail(){ echo "  FAIL: $1"; }

echo "=== T5+T6: CalDAV REPORT (count + attendee/description fidelity) ==="
NOW=$(date -u +%Y%m%dT%H%M%SZ); FUT=$(date -u -v+30d +%Y%m%dT%H%M%SZ)
REPORT=$(cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:prop><D:getetag/><C:calendar-data/></D:prop>
  <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">
    <C:time-range start="$NOW" end="$FUT"/>
  </C:comp-filter></C:comp-filter></C:filter>
</C:calendar-query>
XML
)
R=$(curl -s -m 60 "${CA[@]}" -X REPORT -H 'Depth: 1' -H 'Content-Type: application/xml' --data "$REPORT" "$CAL")
NEV=$(echo "$R" | grep -c "BEGIN:VEVENT")
echo "  events in next 30d via CalDAV: $NEV"
NAT=$(echo "$R" | grep -c "ATTENDEE")
NDESC=$(echo "$R" | grep -c -E "DESCRIPTION|X-ALT-DESC")
NORG=$(echo "$R" | grep -c "ORGANIZER")
NLOC=$(echo "$R" | grep -c "LOCATION")
echo "  ATTENDEE lines: $NAT   DESCRIPTION: $NDESC   ORGANIZER: $NORG   LOCATION: $NLOC"
[ "$NEV" -gt 0 ] && pass "CalDAV returns events (demo 1-3 read path)" || { fail "no events via CalDAV"; echo "$R" | head -c 500; }
[ "$NAT" -gt 0 ] && pass "attendees survive DavMail->CalDAV (demo 4 KEY)" || fail "no ATTENDEE in any event — demo 4 attendee fidelity at risk"
echo
echo "  --- sample event (first VEVENT, trimmed) ---"
echo "$R" | awk '/BEGIN:VEVENT/{f=1} f{print} /END:VEVENT/{if(f)exit}' | grep -E "SUMMARY|DTSTART|DTEND|ORGANIZER|ATTENDEE|LOCATION|DESCRIPTION" | head -12
echo

echo "=== T7: CalDAV write -> confirm it lands in Exchange (via EWS) ==="
TS=$(date +%s); EVUID="pohtest-$TS@poh"; SUBJ="SYNCTEST-caldav-$TS"
S=$(date -u -v+3d +%Y%m%dT120000Z); E=$(date -u -v+3d +%Y%m%dT123000Z); DT=$(date -u +%Y%m%dT%H%M%SZ)
ICS="BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//poh//test//EN\r\nBEGIN:VEVENT\r\nUID:$EVUID\r\nDTSTAMP:$DT\r\nDTSTART:$S\r\nDTEND:$E\r\nSUMMARY:$SUBJ\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
PUTC=$(curl -s -m 30 -o /dev/null -w "%{http_code}" "${CA[@]}" -X PUT -H 'Content-Type: text/calendar; charset=utf-8' --data-binary "$(printf "$ICS")" "${CAL}${EVUID}.ics")
echo "  CalDAV PUT -> HTTP $PUTC (201/204 = created)"
# Confirm via EWS FindItem that the event actually exists in the Exchange mailbox
NS='xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"'
ES=$(date -u +%Y-%m-%dT%H:%M:%SZ); EE=$(date -u -v+10d +%Y-%m-%dT%H:%M:%SZ)
FI=$(curl -s -m 30 "${EA[@]}" -H 'Content-Type: text/xml; charset=utf-8' --data "<?xml version=\"1.0\"?><soap:Envelope $NS><soap:Header><t:RequestServerVersion Version=\"Exchange2013\"/></soap:Header><soap:Body><m:FindItem Traversal=\"Shallow\"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties><t:FieldURI FieldURI=\"item:Subject\"/></t:AdditionalProperties></m:ItemShape><m:CalendarView StartDate=\"$ES\" EndDate=\"$EE\"/><m:ParentFolderIds><t:DistinguishedFolderId Id=\"calendar\"/></m:ParentFolderIds></m:FindItem></soap:Body></soap:Envelope>" "$EWS")
if echo "$FI" | grep -q "$SUBJ"; then pass "CalDAV write reached Exchange mailbox (demo 6/5 write path)"; else fail "PUT ok but not visible via EWS yet (cache/delay?)"; fi
echo

echo "=== cleanup: delete test event via CalDAV ==="
DC=$(curl -s -m 30 -o /dev/null -w "%{http_code}" "${CA[@]}" -X DELETE "${CAL}${EVUID}.ics")
echo "  CalDAV DELETE -> HTTP $DC (204 = gone)"
echo

echo "=== T8: latency — time a full 30d CalDAV REPORT ==="
T0=$(python3 -c 'import time;print(int(time.time()*1000))')
curl -s -m 90 "${CA[@]}" -X REPORT -H 'Depth: 1' -H 'Content-Type: application/xml' --data "$REPORT" "$CAL" >/dev/null
T1=$(python3 -c 'import time;print(int(time.time()*1000))')
echo "  full REPORT took $(( T1-T0 )) ms  (sync interval 2-5 min >> this)"
unset P
echo; echo "Phase 2 done. Report PASS/FAIL + the sample event block."
