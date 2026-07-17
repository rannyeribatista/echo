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
- **Reproducible & open-source.** Clone it, follow the steps below, and you get
  the same working app. No secrets in git; the Xcode project is generated from a
  spec. Pairs with the Mac-side sender in the `core` repo.

## Status

**v0 — proof it ducks.** A one-button app: tap → music ducks → a test clip plays
→ music restores. Networking to the Mac lands in v1. Full design in
[`docs/architecture.md`](docs/architecture.md).

## Build & run (reproducible)

Requirements: macOS + Xcode, an iOS device, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
# 1. Generate the Xcode project from project.yml (identical on any machine)
brew install xcodegen        # once
xcodegen                     # creates Echo.xcodeproj

# 2. Add a test clip the app will play (v0). Any short .wav named test.wav:
#    e.g. render one from the Kokoro pipeline in the core repo, or use `say`:
say -o Resources/test.aiff "Echo test — you should still hear your music under this"
#    then convert to wav (or just drop any short test.wav into Resources/)

# 3. Open, sign, run
open Echo.xcodeproj
#    In Xcode: select the Echo target → Signing & Capabilities →
#    set your Team (free Apple ID is fine) → pick your iPhone → ⌘R.
#    Free cert = re-sign every ~7 days, same as Pulso.
```

## Config (v1, when networking lands)

Copy the template and fill in your own values — the real file is gitignored:

```sh
cp echo.conf.example echo.conf
```

## License

MIT — see [LICENSE](LICENSE).
