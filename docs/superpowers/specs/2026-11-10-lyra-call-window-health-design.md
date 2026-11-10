# Lyra — say when the call window can't be seen

**Status:** approved by Aidan and built, 10 Nov 2026. Replaces "live speakers, option B" for now (see Why).

## Why

Live speakers (option B) leaned on names read off the lit call tile. Checked first: in both real call recordings
on Aidan's Mac (one in Chrome, one in Zoom) Lyra read **nothing** off the call window. No tile names, and no
screen text either, which it reads every minute from the same picture. So no picture of the window was ever taken.
Hand-offs ("over to you, Sam") are already handled after the meeting by heard-names
(`2026-11-10-lyra-heard-names-design.md`), so B would have added little.

## What went wrong (measured)

- Every look at the call window starts with `CGPreflightScreenCaptureAccess()` and quietly gives up without
  the Screen Recording permission. Nothing is written to the note or `meeting.json`.
- Lyra asks for that permission once, ever (`askedScreenCaptureAccess` is set). It was asked on 27 Oct, before
  Lyra had its steady "Lyra Local" signature, so any grant then belonged to a build that no longer exists.
- The Chrome call's folder is named "Google Chrome", the app name. The window title is read at Allow and needs
  the same permission, so that permission was missing then.
- Signing is now steady ("Lyra Local"), so a grant made today stays across reinstalls.

## What changes

1. **Aidan turns it on once** (System Settings → Privacy & Security → Screen & System Audio Recording → Lyra).
   This one step is the whole fix for tile names; the rest makes sure a silent failure can't happen again.
2. **The note says so.** Each call recording counts its looks at the call window by outcome: no permission,
   no window titled as the call, window on another desktop or minimised, capture failed, seen. Only the counts are
   kept (in `callwindow.json`, filed with its part on Resume; never window titles). If the window was never seen,
   the note gets one plain warning (no permission comes first, as the one Aidan can fix), for example
   "Lyra couldn't see the call window (Screen Recording is off for Lyra), so speakers are named by voice and
   conversation only." or "...couldn't find the call window (it may have been full screen or on another desktop)".
3. **Another desktop.** Lyra now also looks for the call window when it isn't on this desktop (full screen on
   its own desktop, or minimised) and tries to take it; one on this desktop still wins. Only windows the existing
   rule calls a call window are ever taken.
4. **A way back to the setting.** When a call recording starts without the permission, the recording capsule
   in the bottom bar gets a small "Let Lyra see the call" button that opens that page of System Settings. Lyra
   never shows the system prompt again by itself.

## Not done here

- Live names in the transcript drawer (option B/C). Revisit once real calls produce tile names.
- Calendar invite names as candidates for heard-names.

## Files

- `LyraCore`: a small `CallWatchHealth` (counts by outcome, and the warning text). Unit tested.
- `LyraAudio/CallWindow.swift`: `frame` reports why it returned nothing.
- `LyraAudio/CallWatcher.swift`: keeps and saves the counts. `Lyra/MeetingSession.swift`: the warning at Stop.
- `Lyra/BottomBar.swift` + `Lyra/ScreenAccess.swift`: the settings button (`LYRA_DEBUG_NO_SCREEN=1` shows it).
