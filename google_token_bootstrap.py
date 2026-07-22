#!/usr/bin/env python3
"""Mint a Google OAuth token for the syncer's Google Calendar access.

Run on your Mac (needs a browser). Reads client_id/secret from ./secrets/,
opens the Google consent screen, and writes ./state/google.token in the
oauthlib JSON format the syncer reads. Then prints your calendars so you can
copy the target calendar id into docker-compose.yml (GCAL_ID).

Deps (host):  pip install google-auth-oauthlib requests
Proxy: honored automatically from HTTPS_PROXY env (the browser handles consent).
"""
import pathlib
import requests
from google_auth_oauthlib.flow import InstalledAppFlow

SCOPES = ["https://www.googleapis.com/auth/calendar"]
base = pathlib.Path(__file__).parent
cid = (base / "secrets/google_client_id").read_text().strip()
csec = (base / "secrets/google_client_secret").read_text().strip()

cfg = {
    "installed": {
        "client_id": cid,
        "client_secret": csec,
        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        "token_uri": "https://oauth2.googleapis.com/token",
        "redirect_uris": ["http://localhost"],
    }
}

flow = InstalledAppFlow.from_client_config(cfg, SCOPES)
creds = flow.run_local_server(port=0)  # opens browser, does the code exchange

# the syncer's Google Calendar access expects an oauthlib token dict
# (access_token / refresh_token / expires_at), NOT google-auth's token/expiry.
import calendar as _cal, json as _json
exp = 0
if creds.expiry:
    exp = _cal.timegm(creds.expiry.timetuple())
oauth_tok = {
    "access_token": creds.token,
    "refresh_token": creds.refresh_token,
    "token_type": "Bearer",
    "scope": list(SCOPES),
    "expires_at": exp - 60,  # force a refresh on first use
}
(base / "state").mkdir(exist_ok=True)
(base / "state/google.token").write_text(_json.dumps(oauth_tok))
print("\nWrote state/google.token (oauthlib format for the syncer)")

print("\nYour Google calendars (copy the target id into docker-compose.yml GCAL_ID):")
r = requests.get(
    "https://www.googleapis.com/calendar/v3/users/me/calendarList",
    headers={"Authorization": f"Bearer {creds.token}"},
    timeout=30,
)
for c in r.json().get("items", []):
    mark = "  <-- target" if c.get("summary") in ("MTS Exchange", "MTS Work") else ""
    print(f"  {c['summary']!r:40} {c['id']}{mark}")
