# poh-scheduller — calendar sync (Exchange → Google, reclaim-friendly)

One-way, **notification-safe** sync of the corporate Exchange calendar into Google,
staged so it plays nicely with reclaim.io.

## Flow

```
Corporate Exchange (<EXCHANGE_HOST>, EWS/NTLM)
  → DavMail            gateway, exposes Exchange as CalDAV (reliable Exchange access)
  → syncer/sync.py     reads events, STRIPS attendees into the description,
                       writes via Google Calendar API with sendUpdates=none
  → Google calendar "MTS Exchange"   (we own it; reclaim does NOT touch it)
  → [reclaim.io Sync Policy: MTS Exchange → MTS-WORK]   (you configure this)
  → MTS-WORK           reclaim-managed; events arrive via reclaim, not us
```

### Why this shape

- **Notification-safe.** vdirsyncer (the first attempt) uploaded structured ATTENDEE
  properties to Google, and Google emailed invitations to those attendees — this
  spammed colleagues. The custom syncer instead puts the attendee list as **text at
  the top of the description**, keeps **no** structured attendees, and writes with
  `sendUpdates=none`. Nothing is ever emailed.
- **reclaim coexistence.** reclaim.io *manages* MTS-WORK and deletes any event it
  didn't create (our direct writes were cancelled within ~3s). So we never write to
  MTS-WORK. We write to our own **"MTS Exchange"** calendar and let reclaim sync it
  into MTS-WORK via its own policy — reclaim owns those copies, no deletion war.

## Setup

1. **Secrets** (gitignored) in `secrets/`:
   - `exchange_password` — corporate Exchange password (single line, no trailing newline)
   - `google_client_id`, `google_client_secret` — from a Google Cloud OAuth Desktop client
2. **Google token**: `python3 google_token_bootstrap.py` (once, on a machine with a
   browser) → writes `state/google.token`. Enable **Calendar API** *and* **CalDAV API**
   in the Cloud project; add your Google account as an OAuth test user.
3. **Target calendar**: the syncer writes to the calendar in `GCAL_ID`
   (docker-compose.yml) — currently the dedicated **"MTS Exchange"** calendar.
4. **Run**: `docker compose up -d` — starts DavMail + the syncer loop (every 120 s).
   One-shot: `docker compose run --rm syncer`.
5. **reclaim.io** (you, in the reclaim UI): create a Sync Policy
   **source = "MTS Exchange" → destination = "MTS-WORK"**, details visible. From then
   on, Exchange meetings land in MTS-WORK (and onward wherever MTS-WORK feeds).

## Notes

- `WINDOW_PAST_DAYS` / `WINDOW_FUTURE_DAYS` bound the sync window (default −7…+90).
- Idempotent: matches by the Exchange UID stored in each Google event's
  `extendedProperties.private.exchangeUid`; recurring events carry their RRULE.
- **Never writes to Exchange** (read-only source). One-way by construction.
- Local Mac dev reaches Exchange + Google only via the host proxy (127.0.0.1:2080 →
  `host.docker.internal:2080` in containers). On the deploy VM, drop all proxy config.
- `verify_ews.sh`, `phase1_ews.sh`, `phase2_caldav.sh` are the incremental validation
  scripts used to de-risk each leg (see `docs/superpowers/specs/`).
