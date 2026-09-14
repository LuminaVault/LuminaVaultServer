# Device data — Health, Calendar, Reminders, Photos, Location, Files

What Lumina may read from your devices, and how you grant it.

---

## Two layers of permission

Turning a source on takes **both**, and they are independent:

1. **iOS permission** — the system prompt. Apple controls it; you manage it in
   iOS Settings ▸ Privacy & Security.
2. **LuminaVault consent** — the per-domain toggle in the app. Turning a source
   off here stops syncing, hides it from Hermes, **and deletes the synced copy**.

Granting the iOS permission does not switch on the LuminaVault toggle, and the
toggle cannot override a denied iOS permission. If a source looks connected but
no data arrives, check the other layer.

---

## The domains

| Domain | What it covers | Lumina can write |
|---|---|---|
| **Health** | Sleep, activity, heart rate | no |
| **Calendar** | Your events | **yes** |
| **Reminders** | Reminders & tasks | **yes** |
| **Photos** | On-device analysis (text, labels) | no |
| **Location** | Recent places & visits | no |
| **Files** | Documents you choose | no |

Write access is a second, separate toggle — **Allow Hermes to make changes** —
and it only appears for Calendar and Reminders.

---

## On iOS

### Consent toggles

1. Tab bar → **More** → **Settings**.
2. **Account & Data** → **Data Access**.
3. Turn on the domains you want.
4. For Calendar or Reminders, optionally also turn on **Allow Hermes to make
   changes**.

Each row shows *"Synced \<time ago\>"* once data has flowed.

### Apple Health specifically

HealthKit is **not** in Settings. It lives on the Dashboard:

1. Tab bar → **More** → **Dashboard**.
2. In the Command Deck, tap **Health** (row 06).
3. Tap **Connect HealthKit**.
4. Approve in the system sheet.

The app requests **read-only** access and never asks for permission to write
health data.

The prompt is deliberately never fired at launch or at sign-in — it only appears
when you tap **Connect HealthKit**. If you previously denied it, the screen says
*"HealthKit access denied"* and you must re-enable it in iOS Settings; the app
cannot re-ask.

Once granted but before samples arrive you will see *"No samples yet — your
dashboard fills in as new samples sync from Apple Health."*

---

## On the web

Sidebar → **Settings** → **Data access** (group *Data*). Tick **Allow read**
per domain; **Allow writes** stays disabled until read is allowed.

This is **consent only**. The browser has no access to HealthKit, EventKit or
your photo library, so nothing syncs from the web — the toggles govern what the
server and Hermes may use from data your *phone* has already sent. Use the web
to revoke access; use iOS to grant and sync it.

---

## Other permissions with no settings screen

Speech recognition (voice mode), the photo library picker, and EventKit
reminders access prompt at the point of use and have no pane of their own. They
are governed by the Data Access toggles above.

**Push notifications** are asked for twice, both deliberate: during onboarding
on a priming screen (**Enable nudges** / **Not now**), and again after the SOUL
quiz for anyone who skipped it. Denial is silent. Categories are then managed at
Settings → **Automation & Alerts** → **Notifications** — *Daily digest*,
*Nudges*, *Chat replies*, plus Hermes run *Approval requests* and *Run results*.
Turning a category off suppresses the push; the underlying skill still runs.

---

## Verifying

- **Health**: Dashboard → Health shows Sleep, Heart Rate, HRV, Steps.
- **Calendar / Reminders**: the Data Access row shows a recent *Synced* time.
- Ask in chat for something only that source knows.

---

## Known limits

- **Web grants nothing.** It is a revoke-and-review surface; syncing is iOS-only.
- **The web page lists Location, the sidebar description does not** — a copy
  mismatch, not a functional difference.
- **Turning a domain off deletes the synced copy.** Not a pause. Re-enabling
  starts collection again from that point.
- **A denied iOS permission cannot be re-requested from inside the app.** The
  user has to go to iOS Settings ▸ Privacy & Security.
- **Device calendar ≠ Google Calendar.** They are separate integrations with
  separate consent; see [linked-accounts.md](linked-accounts.md).
