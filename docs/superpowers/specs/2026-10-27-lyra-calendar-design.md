# Lyra — upcoming meetings (calendar) design

2026-10-27. Branch `feat/calendar`.

## What Aidan asked for (his answers, 2026-10-27)
- **Source:** his Google calendar (aidan@example.com). Notion Calendar only shows that same Google account
  plus two Notion task databases, so Google is the one source. **Lyra signs in to Google directly**, not through
  the Mac's Calendar app.
- **Which events:** only real meetings: timed (not all-day), not declined, and either someone else is invited or
  there is a Zoom / Meet / Teams / Webex link. Personal events stay off the list.
- **How far:** the whole coming week. That covers today (including a meeting already under way) plus the next 7 days.
- **Click:** a meeting with a call link has a **Join** button that opens the call.
- **Recording:** this is the one exception to "only Aidan's click starts a recording". After he presses Join in
  Lyra, the meeting app takes the microphone once he is let in. Lyra then starts recording without the Allow
  panel, titled with the calendar event's name. Anywhere else, the Allow panel still asks.

## Google sign-in
- Aidan creates a Google Cloud "Desktop app" OAuth client once and downloads its JSON. Lyra imports it
  ("Connect Google Calendar…" picks the file, or it finds `client_secret*.json` in Downloads).
- Sign-in uses the standard installed-app flow: PKCE plus a loopback redirect (`http://127.0.0.1:<port>`). The
  page opens in his default browser. Scope: `calendar.readonly` only.
- The client JSON and tokens live in an owner-only file, `~/Library/Application Support/Lyra/google.json` (0600),
  like the voice fingerprints. They are not kept in the Keychain, because the app is ad-hoc signed and the
  Keychain would ask again after every rebuild.
- Access tokens are refreshed with the refresh token. If Google revokes the token, the home page shows "Reconnect
  Google Calendar". Any failure appears as one plain-English line, never a crash.
- The app is "published" in Cloud Console, so the refresh token doesn't expire after 7 days. The "unverified app"
  warning is expected, because it is his own app.

## Fetch
- `GET calendar/v3/calendars/primary/events?singleEvents=true&orderBy=startTime&timeMin=<start of today>&timeMax=<+7 days>`.
  Primary calendar only (the Family/Leo/holiday calendars are not meetings).
- Refreshed when the home page appears or the window comes forward, at most once a minute, and every 5 minutes
  while the home page is open.

## Home page
- A "Coming up" section sits under New note, grouped Today / Tomorrow / weekday. Each row shows the time, title,
  "· N people", and a Join pill if there is a link. A meeting under way shows a green dot.
- Not connected: one quiet row, "Connect Google Calendar", which runs the sign-in.
- Same row style as Recent (`RowButtonStyle`, 14 pt, tertiary time).

## Code
- `LyraCore/Calendar/` (Foundation + CryptoKit, all tested): `CalendarEvent`, `GoogleEvents` (parse the API's
  JSON), `JoinLink` (find the call URL), `UpcomingMeetings` (filter and group by day), `GoogleAuth` (PKCE, auth
  URL, token exchange and refresh requests and parsing, credentials file), `PendingJoin` (the join → auto-record
  window).
- `Lyra/`: `CalendarModel` (fetch and refresh, plus the loopback listener for sign-in), `UpcomingSection` (view).
  `HomePage` gets one added line. `AppModel.tick()` checks `PendingJoin` before showing the Allow panel.

## Join → auto-record rule (`PendingJoin`)
- Join records `{title, until: event end}`. The first `meetingStarted` from any non-ignored app before `until`
  claims it and starts recording titled with the event. Claiming clears it, so it fires only once.
- Known limit: Google Meet in a browser uses the mic on its "Ready to join?" screen. Recording may therefore start
  a little before he is admitted. Zoom's app only connects audio once he is let in.
