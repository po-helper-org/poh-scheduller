#!/usr/bin/env python3
"""Notification-safe one-way sync: corporate Exchange -> Google Calendar "WORK-CAL".

Why custom (not vdirsyncer): vdirsyncer uploads structured ATTENDEE properties to
Google, and Google emails invitations to those attendees on create/update — this
spammed the user's colleagues. It also offers no `sendUpdates` control. This syncer
instead:

  * reads Exchange events via DavMail CalDAV (reliable Exchange access),
  * STRIPS ATTENDEE/ORGANIZER and writes the attendee list as TEXT at the top of the
    description,
  * writes to Google via the Calendar API with sendUpdates="none",

so the Google events are notification-inert — nothing is ever emailed to anyone.

One-way, idempotent. Never writes to Exchange. Matches events by the Exchange UID
stored in each Google event's extendedProperties.private.exchangeUid.
"""
import hashlib
import os
import sys
from datetime import datetime, timedelta, timezone

import requests
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from icalendar import Calendar

# ---- config (env) ----
DAVMAIL_URL = os.environ["DAVMAIL_URL"]  # required, see .env.example
EXCHANGE_USER = os.environ["EXCHANGE_USER"]  # required, bare username (no domain)
EXCHANGE_PASSWORD_FILE = os.environ.get("EXCHANGE_PASSWORD_FILE", "/secrets/exchange_password")
GOOGLE_TOKEN_FILE = os.environ.get("GOOGLE_TOKEN_FILE", "/data/google.token")
GOOGLE_CLIENT_ID_FILE = os.environ.get("GOOGLE_CLIENT_ID_FILE", "/secrets/google_client_id")
GOOGLE_CLIENT_SECRET_FILE = os.environ.get("GOOGLE_CLIENT_SECRET_FILE", "/secrets/google_client_secret")
GCAL_ID = os.environ["GCAL_ID"]  # required
WINDOW_PAST_DAYS = int(os.environ.get("WINDOW_PAST_DAYS", "7"))
WINDOW_FUTURE_DAYS = int(os.environ.get("WINDOW_FUTURE_DAYS", "90"))
SCOPES = ["https://www.googleapis.com/auth/calendar"]
GAPI = "https://www.googleapis.com/calendar/v3"


def _read(path):
    with open(path) as f:
        return f.read().strip()


# ---- Google auth ----
def google_creds():
    import json
    tok = json.load(open(GOOGLE_TOKEN_FILE))
    c = Credentials(
        token=tok.get("access_token"),
        refresh_token=tok["refresh_token"],
        token_uri="https://oauth2.googleapis.com/token",
        client_id=_read(GOOGLE_CLIENT_ID_FILE),
        client_secret=_read(GOOGLE_CLIENT_SECRET_FILE),
        scopes=SCOPES,
    )
    c.refresh(Request())
    return c


# ---- Exchange read (via DavMail CalDAV) ----
def fetch_exchange_events(start, end):
    """Return list of icalendar VEVENT components in [start, end] from DavMail."""
    body = f"""<?xml version="1.0" encoding="utf-8"?>
<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:prop><C:calendar-data/></D:prop>
  <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">
    <C:time-range start="{start:%Y%m%dT%H%M%SZ}" end="{end:%Y%m%dT%H%M%SZ}"/>
  </C:comp-filter></C:comp-filter></C:filter>
</C:calendar-query>"""
    r = requests.request(
        "REPORT", DAVMAIL_URL,
        auth=(EXCHANGE_USER, _read(EXCHANGE_PASSWORD_FILE)),
        headers={"Depth": "1", "Content-Type": "application/xml; charset=utf-8"},
        data=body, timeout=120,
    )
    r.raise_for_status()
    # The multistatus body embeds one VCALENDAR per event inside <calendar-data>.
    events = []
    import re
    for chunk in re.findall(r"BEGIN:VCALENDAR.*?END:VCALENDAR", r.text, re.S):
        chunk = chunk.replace("&#13;", "").replace("&#10;", "")
        try:
            cal = Calendar.from_ical(chunk)
        except Exception as e:
            print(f"  skip unparseable event: {e}", file=sys.stderr)
            continue
        for comp in cal.walk("VEVENT"):
            events.append(comp)
    return events


# ---- transform: strip attendees -> description text ----
def _person(prop):
    """Format an ATTENDEE/ORGANIZER ical property as 'Name <email>'."""
    cn = prop.params.get("CN") if hasattr(prop, "params") else None
    val = str(prop)
    email = val.split(":", 1)[1] if ":" in val else val  # strip mailto:
    if cn and email:
        return f"{cn} <{email}>"
    return cn or email


from zoneinfo import available_timezones
_VALID_TZ = available_timezones()


def _ical_dt_to_google(comp, key):
    """Map an ical DTSTART/DTEND to a Google date/dateTime dict.

    Exchange/DavMail sometimes emits a non-IANA TZID ("Customized Time Zone"),
    which Google rejects (400). In that case fall back to the absolute UTC instant.
    """
    v = comp.get(key)
    dt = v.dt
    if isinstance(dt, datetime):
        tzname = getattr(dt.tzinfo, "key", None) or (str(dt.tzinfo) if dt.tzinfo else None)
        if tzname in _VALID_TZ:
            return {"dateTime": dt.isoformat(), "timeZone": tzname}
        if dt.tzinfo is not None:
            dt = dt.astimezone(timezone.utc)
            return {"dateTime": dt.isoformat().replace("+00:00", "Z"), "timeZone": "UTC"}
        return {"dateTime": dt.isoformat()}
    # date only -> all-day
    return {"date": dt.isoformat()}


def transform(comp):
    """Build a notification-inert Google event dict from an Exchange VEVENT."""
    uid = str(comp.get("UID"))
    summary = str(comp.get("SUMMARY", "(без темы)"))
    location = str(comp.get("LOCATION")) if comp.get("LOCATION") else None
    orig_desc = str(comp.get("DESCRIPTION")) if comp.get("DESCRIPTION") else ""

    # attendees / organizer -> text block (NO structured attendees in Google)
    attendees = comp.get("ATTENDEE")
    if attendees and not isinstance(attendees, list):
        attendees = [attendees]
    organizer = comp.get("ORGANIZER")

    lines = []
    if organizer is not None:
        lines.append(f"Организатор: {_person(organizer)}")
    if attendees:
        lines.append(f"Участники ({len(attendees)}):")
        for a in attendees:
            lines.append(f"  • {_person(a)}")
    header = ("\n".join(lines) + "\n———\n") if lines else ""
    description = header + orig_desc

    ev = {
        "summary": summary,
        "description": description,
        "start": _ical_dt_to_google(comp, "DTSTART"),
        "end": _ical_dt_to_google(comp, "DTEND"),
        "extendedProperties": {"private": {"exchangeUid": uid}},
        # deliberately NO "attendees", NO "organizer"
    }
    if location:
        ev["location"] = location
    # recurring events: propagate the RRULE so Google generates the occurrences.
    rrule = comp.get("RRULE")
    if rrule is not None:
        ev["recurrence"] = ["RRULE:" + rrule.to_ical().decode()]
    # content hash for idempotency
    h = hashlib.sha256(
        repr((summary, description, ev["start"], ev["end"], location, ev.get("recurrence"))).encode()
    ).hexdigest()[:16]
    ev["extendedProperties"]["private"]["pohHash"] = h
    return uid, h, ev


# ---- Google upsert / reconcile ----
def list_managed(creds, start, end):
    """Return {exchangeUid: (google_event_id, pohHash)} for events we manage.

    Lists recurring *masters* (singleEvents=false) with no time bounds, so a
    recurring event whose DTSTART is outside the sync window is still matched by
    its exchangeUid — otherwise it would be re-inserted (duplicated) every run.
    """
    out = {}
    page = None
    while True:
        params = {
            "maxResults": 250,
            "singleEvents": "false",
            "showDeleted": "false",
        }
        if page:
            params["pageToken"] = page
        r = requests.get(
            f"{GAPI}/calendars/{GCAL_ID}/events",
            headers={"Authorization": f"Bearer {creds.token}"},
            params=params, timeout=60,
        ).json()
        for e in r.get("items", []):
            priv = (e.get("extendedProperties") or {}).get("private") or {}
            uid = priv.get("exchangeUid")
            if uid:
                out[uid] = (e["id"], priv.get("pohHash"))
        page = r.get("nextPageToken")
        if not page:
            break
    return out


def upsert(creds, ev, existing):
    uid = ev["extendedProperties"]["private"]["exchangeUid"]
    h = ev["extendedProperties"]["private"]["pohHash"]
    headers = {"Authorization": f"Bearer {creds.token}", "Content-Type": "application/json"}
    if uid in existing:
        gid, old_h = existing[uid]
        if old_h == h:
            return "skip"
        requests.put(
            f"{GAPI}/calendars/{GCAL_ID}/events/{gid}",
            headers=headers, params={"sendUpdates": "none"}, json=ev, timeout=60,
        ).raise_for_status()
        return "update"
    requests.post(
        f"{GAPI}/calendars/{GCAL_ID}/events",
        headers=headers, params={"sendUpdates": "none"}, json=ev, timeout=60,
    ).raise_for_status()
    return "insert"


def main():
    now = datetime.now(timezone.utc)
    start = now - timedelta(days=WINDOW_PAST_DAYS)
    end = now + timedelta(days=WINDOW_FUTURE_DAYS)

    dry = os.environ.get("DRY_RUN") == "1"
    creds = google_creds()
    ex_events = fetch_exchange_events(start, end)
    existing = {} if dry else list_managed(creds, start, end)

    seen = set()
    counts = {"insert": 0, "update": 0, "skip": 0}
    sample_shown = 0
    for comp in ex_events:
        try:
            uid, h, ev = transform(comp)
        except Exception as e:
            print(f"  transform failed: {e}", file=sys.stderr)
            continue
        if uid in seen:
            continue  # dedup: same UID returned more than once (recurring master/instances)
        seen.add(uid)
        if dry:
            assert "attendees" not in ev and "organizer" not in ev
            if sample_shown < 2 and ev["description"].strip():
                import json as _j
                print("--- SAMPLE google payload ---")
                print(_j.dumps(ev, ensure_ascii=False, indent=2)[:900])
                sample_shown += 1
            continue
        try:
            counts[upsert(creds, ev, existing)] += 1
        except requests.HTTPError as e:
            print(f"  upsert failed for {uid}: {e}", file=sys.stderr)

    if dry:
        print(f"DRY_RUN: {len(ex_events)} exchange events, all attendee-stripped. No writes.")
        return

    # reconcile: delete managed Google events whose Exchange source is gone
    deleted = 0
    for uid, (gid, _h) in existing.items():
        if uid not in seen:
            requests.delete(
                f"{GAPI}/calendars/{GCAL_ID}/events/{gid}",
                headers={"Authorization": f"Bearer {creds.token}"},
                params={"sendUpdates": "none"}, timeout=60,
            )
            deleted += 1

    print(
        f"exchange={len(ex_events)} inserted={counts['insert']} "
        f"updated={counts['update']} skipped={counts['skip']} deleted={deleted}"
    )


if __name__ == "__main__":
    main()
