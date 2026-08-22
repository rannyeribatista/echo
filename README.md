# Echo

A tiny iOS app that lets **Nic** talk to you through your headphones *without
stopping your music*. When a message comes in, Echo dims whatever you're
listening to, speaks in Nic's voice, then lets the music swell back — the way a
navigation app reads a turn without killing your playlist.

The name is a companion to **Pulso** (a HealthKit-sync app). Pulso is a pun on
*pulse* — a heartbeat and the sync-pulse of data. **Echo** is the voice coming
back to you: what Nic says on the Mac, echoed into your ear on the move.

- **Voice stays Kokoro.** Echo does not do the talking — the Mac renders the
  audio in the Kokoro voice and hands Echo a ready-made clip to play.
- **Music-friendly.** Echo *ducks* other audio (Spotify, podcasts) instead of
  fighting it for the channel — the thing VLC can't do.
- **Two modes.** *Always-on* auto-ducks and plays each message as it arrives.
  Turn it off and messages queue in the app until you tap play.
- **Reproducible & open-source.** Clone it, follow the steps below, and you get
  the same app. No secrets in git; the Xcode project is generated from a spec.
  Pairs with the Mac-side sender in the `core` repo.

## How it works

The Mac renders Nic's voice and streams it; Echo (open on your phone) holds
a long-poll to the Mac over your private **Tailscale** network, pulls each
message, and ducks + plays it. Long messages arrive **walkie-style**: the full
text shows at once, the first chunk plays within seconds of the text existing
(while later chunks still render), playback pauses at each paragraph break
until you tap **Continue**, and a spoken *"Over"* marks the true end. A toggle
restores continuous auto-play. No push, no cloud, no account — audio never
leaves your devices. Full design in [`docs/architecture.md`](docs/architecture.md);
the streaming protocol in [`docs/walkie-protocol.md`](docs/walkie-protocol.md);
where this is headed — the whole pipeline folded into the app — in
[`docs/unification-design.md`](docs/unification-design.md).

## Build & run (reproducible)

Requirements: macOS + Xcode, an iPhone, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen        # once
xcodegen                     # generates Echo.xcodeproj from project.yml
open Echo.xcodeproj
# In Xcode: Echo target → Signing & Capabilities → set your Team (free Apple ID
# is fine) → pick your iPhone → ⌘R. Free cert = re-sign every ~7 days.
```

Then:

1. On the Mac, start the delivery server: `core/voice/echo-send.sh start`.
2. On the iPhone, open **Settings → Echo** (the system Settings app, not the
   app itself — there is no gear inside Echo) and enter your Mac's Tailscale
   host, port, and the shared token (they live in `core/voice/echo.conf`).
3. Open Echo. It comes up listening — opening the app IS the intent, so there
   is no "Start listening" button to press.
4. Test it: `core/voice/echo-send.sh test` — your music should duck and you
   should hear the clip.

### EchoMac — the desktop half (macOS)

The same project builds a desktop app: a regular window you place and size
wherever you want (a menu-bar panel in its first life), showing the same
message list as the phone, and ducking whatever the Mac is playing (Spotify,
Music, a YouTube tab — anything audible) via a Core Audio process tap while
Nic speaks. Unplayed messages badge the Dock icon; closing the window keeps
it listening. Design + spike measurements in
[`docs/desktop-design.md`](docs/desktop-design.md).

```sh
xcodegen
open Echo.xcodeproj   # EchoMac scheme → My Mac → ⌘R
```

First run: **Echo menu → Settings (⌘,)** → set the shared token (host defaults
to `127.0.0.1`; the server runs on the same machine) → **Test duck** with
music playing. macOS asks once for *System Audio Recording* —
deny it and the tap "works" while capturing silence, which is exactly what
the test detects and reports. An AppleScript Spotify/Music volume dip is
selectable as fallback. Unlike the phone, no 7-day re-sign: a locally
signed macOS app keeps running.

It comes up already listening, and starts at login once you install the agent:

```sh
scripts/echomac-login.sh install     # uninstall / status also available
```

That points at whatever `EchoMac.app` it finds — `/Applications` first, else
the Xcode build inside the gitignored `build/`, which a Clean removes. Override
with `ECHOMAC_APP=/path/to/EchoMac.app`.

Every listening player receives every message: legacy clips broadcast until
each active client has fetched them (2026-08-08), and walkie messages are
cursor-based per client by design.

## License

MIT — see [LICENSE](LICENSE).
