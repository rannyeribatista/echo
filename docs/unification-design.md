# One Echo — the unification design (record of the 2026-08-20 sit)

> Design sit run live over the walkie prototype, canvas at
> https://claude.ai/code/artifact/5e1eb319-0e84-45ab-8217-4c5e0f1f5816 (the
> session record; this file is the durable repo-side record). Personas: Ranny
> (listener & operator), Nic (coordinator), Wren (a silent worker lane).

## Thesis

Fold the voice pipeline's moving parts — say-hook, queue/serialization,
Kokoro render, delivery server — into the Echo app as **one package with one
lifecycle**. Claude keeps exactly two responsibilities: composing the words
and curating what gets spoken (coordinator role). Everything repeatable
becomes the app. Motivation is empirical: every voice outage to date was a
seam failure between separately-living pieces (unrestarted server 2026-08-14,
stale login build, un-exported `ECHO_PORT` 2026-08-08, hush-blind app found
live 2026-08-20), never a logic bug inside one piece.

## The three calls (resolved 2026-08-20, Ranny's words quoted)

1. **Quit means quiet.** "If the app is closed, nothing should reproduce —
   sometimes if I want to have it quiet, I can just quit the app." Closing
   Echo is the sanctioned mute gesture; finished turns spool to disk and
   surface as unplayed dots when Echo returns. This **overturns the oldest
   invariant** ("the voice never dies", 2026-07-20): never-silent assumed
   silence was a failure; under One Echo silence is a lifecycle choice. The
   hook shim has no speaking path; the `say`/afplay fallbacks die and must
   not creep back.
2. **Echo owns the voice core; core owns none of it.** "Core shouldn't have
   anything to do with echo — echo is a tool to interact with Claude CLI;
   core is the Obsidian organization that stores my life, used as context for
   LLMs." That sentence is the repo boundary definition. Personal values stay
   in gitignored conf (existing pattern; the public repo carries no secrets).
3. **Native Swift render is the destination.** "Move it all to Echo and make
   it work there — having the native Swift render will be very beneficial."
   The sherpa-onnx spike is therefore **phase 0** and gates the build; the
   python renderer may ride only as temporary in-app scaffolding while native
   lands, and retires on the spike's success.

## Target shape

```
Claude (composes + curates)                     ← unchanged, by design
  └─ Stop-hook shim (~15 lines, outside the app: extract → POST /say →
     spool to disk when Echo is closed; never speaks)
       └─ Echo, the package: accepts text · routes speak-vs-mailbox (owner
          role) · renders warm/native · serves the phone (same v2 protocol)
          · plays ducked, walkie-gated · owns silence (hush = one call)
          · one lifecycle (login item), one log
            └─ iPhone: pure client, untouched
```

Phasing: **P0** sherpa-onnx render spike (gates all) · **P1** voice core
inside Echo (native render where the spike allows; warm python engine only as
transition scaffolding) · **P2** hook shrinks to shim, queue + routing move
in · **P3** scaffolding retires, scripts die per the fate table.

## Fate table

| Part | Fate | Becomes |
|---|---|---|
| `core/voice/nic-say.sh` | reshaped | ~15-line shim: extract → POST /say → spool (never speaks) |
| `core/voice/nic-player.sh` | dies | Echo's in-app queue (pendingAutoPlay lineage) |
| `core/voice/nic-tts.py` | reshaped → dies | P1 scaffolding engine · retired by native render |
| `core/voice/echo-server.py` | dies | Swift listener inside EchoMac, same v2 protocol |
| `core/voice/echo-send.sh` | reshaped | thin CLI talking to the app |
| `core/voice/nic-hush.sh` | reshaped | one POST /hush; Echo owns silence end-to-end |
| `core/voice/nic-play.sh` (hear) | reshaped | replay = Echo history |
| `core/voice/voice.conf` | reshaped | prefs only; pipeline knobs → Echo settings |
| owner / mailbox files | stay | interchange format for Claude sessions (router logic moves — amber A5) |
| walkie v2 protocol | stays | the phone never notices any of this |

## Open ambers (resolve during build, on the canvas)

- **A4** settle-wait placement: shim-side vs Echo reads the transcript.
- **A5** who writes the mailbox file — shim or Echo (the latter unlocks Echo
  as the orchestrator's dashboard; decide with eyes open).
- **A6** → promoted to the P0 spike (below).
- **A7** should a new prompt still hard-silence a gated message, or only
  cancel pending chunks? Decide after a week of walkie use.

Parking lot: voice IN (push-to-talk, VoiceFlow twin, voice-"continue") — its
own sit; lock-screen Continue; re-listen control; per-voice Over; push-wake
delivery. (Nic radio was in this parking lot; it was REMOVED entirely
2026-08-22 — Echo superseded it and Ranny chose deletion over archiving.)

## Ops residue (at merge / deploy)

- Delete the `NIC_TTS` live-trial override from live `voice.conf`.
- Rebuild + `scripts/echomac-login.sh install` (login launches the unified build).
- Rebuild the iPhone app (walkie client), then `ECHO_LEGACY_CLIP=off`.
- Core-side: `integrity.sh baseline` → `./backup.sh` after doc updates.
