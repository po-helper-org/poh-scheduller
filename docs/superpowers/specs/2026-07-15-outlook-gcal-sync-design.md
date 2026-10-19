# poh-scheduller — corporate Outlook ↔ Google Calendar (DavMail + vdirsyncer)

**Date:** 2026-07-15
**Status:** **DONE (2026-07-15)** — working, idempotent, notification-safe.

> **FINAL ARCHITECTURE (supersedes the vdirsyncer sections below).**
> vdirsyncer was dropped: it uploads structured ATTENDEE to Google, which emails
> invitations to attendees (spammed colleagues), and it offers no `sendUpdates`
> control. Also reclaim.io *manages* the WORK-CAL calendar and deletes any event it
> didn't create — so we cannot write to WORK-CAL directly.
>
> Final flow: **Exchange → DavMail → `syncer/sync.py` → Google "Work Exchange" calendar
> → (reclaim.io Sync Policy) → WORK-CAL.** The custom syncer strips attendees into the
> description, keeps no structured attendees, writes via Calendar API with
> `sendUpdates=none`, is idempotent (match by exchangeUid), handles recurring (RRULE)
> and non-IANA timezones (→ UTC). "Work Exchange" id:
> `<GCAL_ID>`.
> See top-level `README.md`. The DavMail + verify-gate + phase-test history below still
> applies; only the Google-write leg changed from vdirsyncer to the custom syncer.
**Scope:** Calendar sync. Corporate-messenger Tasks → Google Tasks is a separate later spec.

## Goal

Consolidate the corporate Outlook calendar (`<EXCHANGE_HOST>`, Exchange/O365) into
Google Calendar. Primary goal is aggregation *into* Google. Two-way for events the
user organizes (edit time/attendees in Google → back to Outlook). Runs unattended
on a small always-on host.

## Chosen approach: ready-made OSS stack (no custom sync engine)

```
Corporate Exchange / O365
        ↑ EWS / Graph (modern auth)
   ┌────┴─────┐
   │ DavMail  │  Java gateway, headless daemon — exposes Exchange as CalDAV
   └────┬─────┘
        │ CalDAV (localhost)
   ┌────┴───────┐
   │ vdirsyncer │  Python CLI, stateful, true 2-way sync + conflict resolution
   └────┬───────┘
        │ Google Calendar API (native google_calendar storage)
   ┌────┴─────────┐
   │ Google Cal   │  dedicated calendar "Work Calendar"
   └──────────────┘
```

We write **no sync code** — this is configuration + deployment of two mature OSS
tools. That satisfies "предельно просто": the moving parts are config files and a
systemd timer, not a bespoke engine.

## Hosting — NOT Yandex Cloud Functions

Cloud Functions are ephemeral and stateless; this stack is neither:

- **DavMail** is a long-running daemon holding the Exchange session.
- **vdirsyncer** is **stateful** — it keeps a `status/` directory to diff changes
  between runs. Lose it and every run re-evaluates from scratch (or duplicates).

Therefore: a small **always-on host** — Yandex Compute Cloud VM (smallest tier) or
a container on a managed instance. Two systemd units:

- `davmail.service` — runs DavMail continuously.
- `vdirsyncer-sync.timer` → `vdirsyncer sync` every 2–5 min (meets "<5 min" demo).

State (`~/.vdirsyncer/status/`, DavMail config, OAuth token) lives on the VM disk.

## Components & configuration

1. **DavMail** (`.davmail.properties`) — **verified params:**
   - `davmail.mode` = `EWS`.
   - `davmail.url` = `https://<EXCHANGE_HOST>/EWS/Exchange.asmx` (fixed, no autodiscover).
   - Auth = **NTLM**; username = bare **`<EXCHANGE_USER>`** (no domain prefix, no UPN) —
     this exact form authenticated in the gate.
   - Exchange 2019 on-prem (`X-OWA-Version 15.2.1544.33`), reached via corp proxy/VPN.
   - Enable CalDAV, bind to localhost only.

2. **vdirsyncer** (`~/.vdirsyncer/config`)
   - Storage A: `caldav`, url = DavMail CalDAV endpoint, the corporate calendar
     collection.
   - Storage B: `google_calendar`, `client_id` / `client_secret` from our **own**
     Google Cloud project (Google ToS forbids shipping shared creds); token file
     obtained once via device/installed-app flow, then headless.
   - Target Google calendar id = the dedicated **"Work Calendar"** calendar.
   - `pair`: `conflict_resolution = "b wins"` (Outlook/Exchange as source of truth)
     — chosen so a corporate master edit always wins over a stray Google edit;
     revisit once two-way behaviour is validated.

3. **Google** — one Cloud project, Calendar API enabled, OAuth "Desktop app"
   client. Create the "Work Calendar" calendar manually; put its id in vdirsyncer config.

## What the demo maps to

| Demo step | Mechanism | Confidence |
|---|---|---|
| 1-2. Create in Outlook, <5 min | vdirsyncer timer pulls via DavMail CalDAV | High |
| 3. Appears in Google "Work Calendar" | vdirsyncer writes to google_calendar storage | High |
| 4. Full info (attendees, description, time) | carried in the iCalendar object | Medium — attendee fidelity via CalDAV/DavMail needs verification |
| 5. Edit attendees in Google → Outlook | vdirsyncer 2-way push back through DavMail | **Low / risky** — see below |
| 6. Edit time in Google → Outlook | same | **Low / risky** |

## Verify-first gate (do BEFORE any deployment work)

The make-or-break unknown is whether **DavMail can authenticate to corporate
`<EXCHANGE_HOST>` at all**. Large enterprises often block third-party EWS clients or
enforce Conditional Access / modern auth that DavMail must be configured for.

**RESULT — PASSED (2026-07-15).** Direct NTLM auth to
`https://<EXCHANGE_HOST>/EWS/Exchange.asmx` succeeded with bare username
`<EXCHANGE_USER>`; `GetFolder(calendar)` returned `NoError`, 405 items. Exchange 2019,
NTLM/Negotiate, `X-OAuth-Enabled: True`. DavMail EWS+NTLM path is viable — no need
for the Graph fallback. Verified with [`verify_ews.sh`](../../verify_ews.sh).

## Two-way write-back risks (steps 5-6) — must be tested carefully

Writing back to Exchange is where damage happens:

- **Organizer-only.** Time/attendee edits only propagate for events the user
  **organizes**. For invited meetings Exchange rejects master edits — steps 5-6
  simply won't apply there.
- **Invitation side-effects.** Changing attendees/time on an organized event makes
  Exchange **send real invites/updates/cancellations to coworkers**. A sync glitch
  = spam to real people.
- **Mitigation:** first validate two-way with a **throwaway event the user
  organizes with only themselves as attendee**. Only after that behaves, consider
  enabling it for real meetings — or keep write-back disabled and run one-way if
  the risk isn't worth it.

## Error handling & idempotency

- vdirsyncer's `status/` gives idempotent diffing; a failed run retries next timer
  tick without duplicating.
- DavMail session drop → `vdirsyncer sync` errors, logged, retried next tick.
- Keep a backup of `status/`; losing it forces a full re-sync (safe but noisy).

## Deployment outline (README)

1. **Verify gate**: DavMail ↔ corporate Exchange auth locally. Stop if it fails.
2. Provision smallest Yandex Compute VM (Linux).
3. Install Java + DavMail; write `.davmail.properties`; `davmail.service`.
4. Create Google Cloud project + OAuth client; create "Work Calendar" calendar.
5. Install vdirsyncer; write config; run `vdirsyncer discover` + first
   `vdirsyncer sync` interactively to authorize Google and seed `status/`.
6. Add `vdirsyncer-sync.timer` (every 2–5 min). Validate two-way with a
   self-only throwaway event before trusting steps 5-6.

## Incremental test plan (de-risk each demo step before full deployment)

Each phase gates the next; failures caught before any deployment work.

| # | Test | Demo step | Proves | Cost |
|---|---|---|---|---|
| **Ph0** | EWS auth + GetFolder | — | calendar access | ✅ passed |
| **Ph1 — EWS only, curl, no installs** (`phase1_ews.sh`) ||||
| T1 | FindItem+GetItem real event | 4 src | attendees/desc/time readable from Exchange | ✅ passed |
| T2 | CreateItem throwaway, 0 attendees | 1 src | EWS write works, no mail | ✅ passed |
| T3 | UpdateItem move time of T2 | 6 src | time write-back to Exchange | ✅ passed |
| T4 | CreateItem with self as attendee | 5 src | attendee write accepted; invite mechanics on self | ✅ passed |

**Ph1 RESULT (2026-07-15):** all passed via `phase1_ews.sh`. Own SMTP =
`<EXCHANGE_UPN>`. Read returns attendees + body. **EWS write (create/update-time/
attendee-create/delete) all work** — write-back to Exchange is viable at the API
level; remaining risk is DavMail/CalDAV fidelity (T6) and end-to-end (Ph4).
| **Ph2 — DavMail in Docker (`docker-compose.yml`)** ||||
| T5 | DavMail up → CalDAV REPORT | 1-3 | gateway works, returns events | ✅ passed |
| T6 | attendee/desc fidelity via CalDAV | **4 (key risk)** | attendees/desc/time survive iCalendar via DavMail | ✅ passed |
| T7 | CalDAV PUT → confirm in Exchange (EWS) | 5-6 mid | CalDAV write reaches Outlook | ✅ passed |
| T8 | time a full CalDAV report | 2 | <5 min latency realistic | ✅ ok (fast) |

**Ph2 RESULT (2026-07-15):** DavMail 6.8.1 runs headless in Docker (built from the
platform-independent Java zip, not the Debian pkg which hard-depends on JavaFX/arm64).
Local Mac reaches Exchange only via host proxy `127.0.0.1:2080` → configured as
`host.docker.internal:2080` in both build args and `davmail.proxyHost` (drop on VM).
**T6 attendee fidelity excellent:** 53 events/30d, 565 ATTENDEE lines with CN + mailto,
plus ORGANIZER / DESCRIPTION / LOCATION intact. Demo-4 attendee risk cleared.
**T7 write-through confirmed:** CalDAV PUT → HTTP 201 → the event was then found via EWS
in the real Exchange mailbox; CalDAV DELETE removed it. So the Google→CalDAV→Exchange
write leg (demo 5-6 middle) works. (Note: a mistyped password makes DavMail return
"Invalid credentials"/503 — not a lockout; just retry.)
| **Ph3 — Google (own OAuth client)** — scaffolding ready, needs user creds ||||
| T9 | create "Work Calendar" calendar | 3 | target exists | ⏳ user (Google Cloud) |
| T10 | vdirsyncer discover + read back | 3,4 sink | Google side holds fields | ⏳ pending creds |
| **Ph4 — vdirsyncer manual (not systemd yet)** — service scaffolded ||||
| T11 | one `vdirsyncer sync`: Outlook → "WORK-CAL" full info | 1-4 e2e | whole read path | ✅ passed |
| T12 | edit time in Google → sync → Outlook | 6 e2e | time write-back through full stack | ⏳ |
| T13 | edit attendee in Google (self-only) → sync → Outlook | 5 e2e | attendee write-back + invite side-effects | ⏳ |

**Ph4 T11 RESULT (2026-07-15):** first `vdirsyncer sync` uploaded the Exchange
calendar into Google "WORK-CAL": **421 events, 377 with attendees, 367 with
descriptions**, times with timezone. Full Outlook→Google read path proven e2e with
fidelity. Token had to be converted to oauthlib format (`access_token`/`expires_at`);
required enabling BOTH Google **Calendar API** and **CalDAV API** in the Cloud project.
Remaining: T12/T13 two-way write-back (risky), and a 2–5 min sync timer for demo-2 latency.

**Ph3/Ph4 scaffolding (2026-07-15):** vdirsyncer added to `docker-compose.yml`
(profile `sync`, run via `docker compose run --rm vdirsyncer …`). Config pairs the
DavMail CalDAV calendar with the Google "Work Calendar" calendar; secrets via `fetch`
from `secrets/` (gitignored). Google OAuth is browserless-hostile, so `google_token_
bootstrap.py` mints `state/google.token` on the Mac once (own OAuth Desktop client),
and the container reuses it via the `./state:/data` bind mount. Blocked on the user
creating the Google Cloud OAuth client + "Work Calendar" calendar.

**Two highest unknowns the tests target:** T6 (attendee fidelity through CalDAV/DavMail)
and T3/T4/T13 (write to Exchange + invitation side-effects — organizer-only, may spam
coworkers; always tested on self-only throwaway events first).

**Gate logic:** T3 fails → demo 5-6 impossible regardless of DavMail (known at Ph1).
T6 truncates attendees → demo 4 degrades; decide trade-off before deploying.

## CRITICAL: one-way safety via `read_only` (incident 2026-07-15)

vdirsyncer is inherently **two-way**. Running a continuous sync without guarding the
Exchange side caused it to push Google-normalized events **back into Exchange**
(~90 of the user's own events "Overwritten" by DavMail before it was stopped). No
invitations were sent (no scheduling activity in DavMail logs; the user is an
attendee, not organizer, on those), and the changes were cosmetic iCal
reformatting — but it must never happen.

**Fix:** `read_only = true` on the `exchange` storage. vdirsyncer then physically
never writes to Exchange — a pure one-way Exchange→Google mirror, matching the
primary aggregation goal. Two-way write-back (demo 5-6) stays OFF; revisit only
deliberately, scoped to self-organized throwaway events.

**Churn — resolved:** after a one-time re-normalization pass, sync **converges to
zero** changes (verified 3 consecutive cycles: exchange=0, google=0, errors=0).
Stable, idempotent one-way mirror. (One event once returned 403 on a Google PUT;
self-cleared.)

## Out of scope (this spec)

- Corporate-messenger Tasks → Google Tasks (no confirmed public Tasks API; separate spec).
- Real-time push (Graph subscriptions) — polling every 2–5 min is enough.
- Contacts/mail sync (DavMail can, we don't need it).
