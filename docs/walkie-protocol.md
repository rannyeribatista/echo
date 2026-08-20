# Walkie streaming — the v2 delivery protocol (2026-08-20)

> Why: a perf investigation (2026-08-20) measured text→first-audio at
> ≈5s + 0.04s/char, because app mode in `core/voice/nic-tts.py` pushed nothing
> to the outbox until ALL chunks were synthesized and concatenated. Delivery
> itself was innocent (long-poll + Tailscale ≤2s). And `EchoClient.play()`
> superseded the current clip, so consecutive messages cut each other off.
> Ranny's walkie-talkie design fixes both: Echo evolves from auto-player into a
> gated comms interface.

## The contract in five lines

1. The Mac writes each message as `outbox/stream/<msgid>/` — a `manifest.json`
   (full text + every chunk's text up front, per-chunk `pending|ready|failed`,
   `final` flag) plus `chunk-NNN.wav` files that appear AS THEY RENDER.
2. Clients long-poll `GET /v2/next?since=<msgid>` for the oldest message newer
   than their cursor (a partial manifest answers immediately — that's the
   streaming win), then `GET /v2/manifest/<id>?have=<n>` to follow its growth,
   fetching audio via `GET /v2/chunk/<id>/<seq>`; all calls token-gated
   (`X-Echo-Token`), ids digits-only.
3. Chunk 1 is the message's first sentence (≈80 chars — first audio in ~5-8s
   regardless of length); later chunks are paragraphs (sentence-split when
   giant). The app plays chunk 1 then PAUSES; Continue advances; at true end it
   plays the shared "Over" clip (`GET /v2/over`, rendered once, cached).
4. Clients keep their own `since` cursor (ids are the Mac's ms timestamps), so
   broadcast to N players needs no server state; the stream store sweeps by
   TTL (`ECHO_TTL`, default 1h).
5. Backwards compatible both ways: `/next` is untouched and still serves the
   concatenated clip nic-tts writes after the last chunk (`ECHO_LEGACY_CLIP=on`
   in voice.conf — flip off once both apps are rebuilt); an old server answers
   `/v2/*` with 404, which new apps read as "fall back to /next".

## Who does what

- **`core/voice/nic-tts.py`** — app mode + `ECHO_STREAM=on` (voice.conf):
  computes walkie chunks from the ORIGINAL text (paragraph boundaries survive;
  each chunk still synthesizes as ~260-char sub-chunks for Kokoro prosody,
  concatenated per chunk), writes the manifest before the model loads (visible
  in ~0.1s), streams chunks via `.part`→rename, renders `over.wav` once
  (before the final flag flips, so a client that sees `final` can fetch it),
  then writes the legacy clip. Direct mode is byte-identical to before.
- **`core/voice/echo-server.py`** — serves the four `/v2` endpoints above,
  long-poll aware (55s hold, 0.4s ticks), plus the unchanged legacy `/next`.
- **`Sources/Shared/EchoClient.swift`** (both apps) — v2 loop with legacy
  fallback; a manifest becomes a `Clip` with a chunk list the moment it lands
  (full text visible at once); chunks download as they render; playback gates
  at each boundary (`walkieMode`, default on — off restores continuous
  auto-play); arriving messages QUEUE behind the one playing instead of
  superseding it (a message parked silent at a gate is superseded — cutting
  silence is fine, cutting audio was the bug); "Over" plays at message end.

## Failure shape

- Chunk synthesis fails on the Mac → manifest marks it `failed`; the app skips
  it. Message swept or stalled (>3min without progress) → the client
  force-finals it: keeps what arrived, marks the rest failed, moves on.
- Server without `/v2` (not yet redeployed) → new apps poll `/next` exactly as
  today. Old apps against the new server → `/next` unchanged.

## Deliberately deferred (protocol questions for the next sit)

- **Voice "continue"** — advancing the gate by talking (VoiceFlow is the
  natural inbound half). Today Continue is a tap.
- **Lock-screen / headset Continue** — mapping the gate to MPRemoteCommand
  (play/next-track) so a run doesn't need the screen.
- **Re-listen control** — "say again" for the last chunk at a gate.
- **Chunk-size tuning** — first-sentence + paragraph is the starting point;
  real use will say whether gates land at the right places
  (`NIC_WALKIE_FIRST` / `NIC_WALKIE_PARA` env knobs exist).
- **Per-voice Over** — over.wav renders once in the default English voice;
  delete `~/.claude/voice/echo/over.wav` to re-render.
- **Warm TTS daemon** — the ~2s import+model tax per message still stands
  (first audio ~4-6s measured). A unix-socket daemon with idle timeout was
  sketched and deliberately skipped to keep this diff reviewable.
