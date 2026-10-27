# Lyra — upcoming meetings (calendar) design

2026-10-27. Branch `feat/calendar`.

## What Aidan asked for (his answers, 2026-10-27)
- **Sources:**
  - His Google calendar (aidan@example.com). Notion Calendar only shows that same Google account plus two
    Notion task databases, so Google is the one Google source.
  - Later the same day: **Microsoft calendars too, both work (Microsoft 365) and personal (Outlook.com)**.
  - Lyra **signs in to each provider directly**, not through the Mac's Calendar app.
- **Which events:** only real meetings: timed (not all-day), not declined, and either someone else is invited or
  there is a Zoom / Meet / Teams / Webex link. Personal events stay off the list.
- **How far:** the coming week, now to 7 days ahead. A meeting already under way counts as today's.
- **Click:** a meeting with a call link has **Join**, which opens the call.
- **Recording:** this is the one exception to "only Aidan's click starts a recording". After he presses Join in
  Lyra, the meeting app takes the microphone once he is let in. Lyra then records without the Allow panel, titled
  with the calendar event's name. Anywhere else, the Allow panel still asks.

## Join → auto-record rule (`PendingJoin`)
- Join arms the rule only for a meeting starting **within 15 minutes, or under way**. For a meeting further off,
  clicking only opens the link. That row shows a quiet camera icon, and the Join pill appears 15 minutes before
  the start.
- Once armed, the rule stays open for **15 minutes after the click**, and never past the meeting's end.
- Only **the call's own app or a browser** can claim it:
  - Zoom links: `us.zoom…`
  - Teams links: `com.microsoft.teams…`
  - Webex links: Webex
  - Every call link: Chrome, Safari/WebKit, Arc/Dia, Edge, Firefox, Brave, Opera, Vivaldi
- The app is matched on the mic user's bundle ID or its owning app's bundle ID.
- The claiming app records under the event's title, and the rule is then cleared, so it fires only once.
- Any other app taking the mic (dictation, Voice Memos) gets the normal Allow panel, and the join stays armed.
- `AppModel.tick()` clears an expired join. Home shows "Lyra will record … as soon as the call has you in" with a
  **Don't record** button.
- Known limit: Google Meet in a browser uses the mic on its "Ready to join?" screen. Recording may therefore start
  a little before he is admitted. Zoom's and Teams' apps only connect audio once he is let in.

## Sign-in (both providers)
- **Flow:** the standard installed-app flow, PKCE plus a loopback redirect. A one-shot listener runs on 127.0.0.1,
  and on ::1 at the same port when possible. The page opens in his default browser.
- **Scopes (read-only):**
  - Google: `openid email calendar.readonly`.
  - Microsoft: `openid profile email offline_access Calendars.Read`.
  - The ID token in the token answer is read only to label the account with its email.
- **Google:** Aidan made a Cloud "Desktop app" client, published so tokens don't expire after 7 days. Lyra imports
  its downloaded JSON through a file picker that opens on Downloads. Redirect: `http://127.0.0.1:<port>`.
- **Microsoft:**
  - Aidan registers one app in Microsoft Entra:
    - Account types: any organisation's accounts plus personal Microsoft accounts.
    - Platform: Public client/native.
    - Redirect URI: `http://localhost` (Microsoft ignores the port for loopback).
  - Lyra asks for the Application (client) ID once. There is no client secret, and none is sent.
  - Endpoint: `common`. Each sign-in uses `prompt=select_account`, so he can add the work and the personal
    account one after the other.
  - A work organisation may require admin approval (AADSTS65001 / 90094 / 90095). Lyra says so plainly.
- **Storage:** app details and every account's tokens live in one owner-only file,
  `~/Library/Application Support/Lyra/calendars.json` (0600). They are not in the Keychain: the app is ad-hoc
  signed, and the Keychain would ask again after every rebuild. The `CalendarService` actor owns the file, so token
  saves never race.
- **Token refresh:**
  - Access tokens are refreshed before expiry.
  - Microsoft rotates refresh tokens, so the new one is saved each time.
  - A 401 gets one fresh token and a second try. After that, the account shows "Reconnect".
  - `invalid_client` means the app details are wrong. **Change Google sign-in file… / Change Microsoft app ID…** in
    the Coming up menu replaces them.

## Fetch
- **Google:** `calendars/primary/events`, with `singleEvents`, ordered by start time.
- **Microsoft:** Graph `me/calendarView`, with times in UTC (`Prefer: outlook.timezone="UTC"`) and plain-text
  bodies, so Zoom links in the body can be found. Lyra follows `@odata.nextLink` for up to 5 pages of 100.
- Each account is fetched on its own:
  - If one fails, the others still show.
  - If an account can't be reached, its last list stays up.
  - If an account was signed out, its meetings are dropped and a Reconnect banner appears.
- **Duplicates:** the same meeting in two calendars (same title and start) shows once. The copy with a call link
  is kept.
- **When:** when home appears or the window comes forward, at most once a minute. Lyra also re-groups every minute
  and fetches again every 5 minutes while home is open.

## Home page
- "Coming up" sits under New note, grouped Today / Tomorrow / weekday. Each row shows:
  - time (or a green "Now")
  - title
  - "· N people"
  - Join pill, or a quiet camera icon
- **Rows:** the same style as Recent (`RowButtonStyle`, 14 pt, tertiary time).
- **Not connected:** two quiet rows, "Connect Google Calendar" and "Connect Microsoft calendar".
- **Connected:** a "…" menu lists the accounts (each can be removed). It also has Add Google / Add Microsoft
  account, and Change app details.
- "No meetings in the next week." only shows after the first fetch.

## Code
- **`LyraCore/Calendar/`** (Foundation + CryptoKit, all tested):
  - `CalendarEvent` and `CalendarError`
  - `OAuth`: providers, PKCE, requests, token answers, ID-token email
  - `CalendarStore`: settings and the accounts file
  - `GoogleEvents`, `MicrosoftEvents`, `JoinLink`
  - `UpcomingMeetings`: merge, filter, group by day, and `PendingJoin`
  - `CalendarService`: the actor
- **`Lyra/`:**
  - `CalendarModel`: fetch and refresh, sign-in, the Microsoft ID alert
  - `LoopbackListener`, with a real-socket test in `LyraAppTests`
  - `UpcomingSection`
  - `HomePage` gets one line; `AppModel` gets `pendingJoin` and the tick hook.
