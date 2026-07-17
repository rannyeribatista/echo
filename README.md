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

The Mac renders Nic's voice and queues the clip; Echo (open on your phone) holds
a long-poll to the Mac over your private **Tailscale** network, pulls each clip,
and ducks + plays it. No push, no cloud, no account — audio never leaves your
devices. Full design in [`docs/architecture.md`](docs/architecture.md).

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
2. In the app, tap the gear → enter your Mac's Tailscale host, port, and the
   shared token (they live in `core/voice/echo.conf`).
3. Choose **Always-on** or leave it off, then **Start listening**.
4. Test it: `core/voice/echo-send.sh test` — your music should duck and you
   should hear the clip.

## License

MIT — see [LICENSE](LICENSE).
