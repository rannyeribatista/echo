# Spike — native Kokoro render in Swift via sherpa-onnx (P0 of One Echo)

Definition-of-Ready brief for the spike lane. Sized like the proc-tap spike
(a lane-day, measured verdict, promote-or-delete). Parent design:
`docs/unification-design.md`.

## Outcome + acceptance

A measured GO / NO-GO verdict on rendering Nic's voice natively inside
EchoMac. GO means all of:

1. sherpa-onnx (Swift/C API) loads the Kokoro model and synthesizes English
   speech on this Mac (Apple Silicon, CLT or Xcode toolchain).
2. Voice parity: `af_heart` at speed 1.1 sounds equivalent to today's python
   render on the same 3 test sentences (ear check + duration within ~10%).
3. pt-BR path: `pf_dora` renders Portuguese acceptably (the pick_voice_lang
   contract survives).
4. Timings measured and written down: model load (cold), per-sentence synth
   for 80/260/600-char inputs, RSS while warm. Target: warm first-chunk synth
   ≤ python's (~2-3s for a first sentence), load ≤ 5s once per app launch.
5. License + packaging story: what ships in the app bundle (framework size,
   model files stay user-supplied like `voice/models/` today).

NO-GO must name the wall precisely (missing espeak phonemization, voice
format, latency, size) so the fallback — warm python engine as a permanent
resident rather than scaffolding — is a decision, not a drift.

## Touch-set

- New: `spikes/sherpa-kokoro/` in the echo repo (SwiftPM CLI like
  `spikes/proc-tap-ducker/` — `synthctl say <text>` → wav + timing CSV).
- Read-only: `core/voice/nic-tts.py` (chunking + speakable() + voice pick —
  port NOTHING yet; the spike only proves the engine), Kokoro models at
  `~/Projects/core/voice/models/` (read in place).
- Touches no app target, no live pipeline, no server.

## No blocking TBDs

- Model files exist locally (kokoro-v1.0.onnx + voices-v1.0.bin, verified).
- sherpa-onnx ships Kokoro TTS support incl. espeak-ng data; if its Swift
  package doesn't expose TTS, fall back to the C API behind a thin Swift
  wrapper — both in scope for the spike.
- Kokoro voice-bin format vs sherpa's expected layout is the likeliest wall;
  budget the morning for it.

## Pointers, not prose

- Precedent spike (shape to copy): `spikes/proc-tap-ducker/` + its results
  section in `docs/desktop-design.md`.
- Today's render contract: `core/voice/nic-tts.py` (`kokoro.create(text,
  voice, speed, lang)`); walkie chunk sizes in the same file
  (`WALKIE_FIRST=80`, `CHUNK_CHARS=260`).
- Timing baselines to beat: `~/.claude/voice/nic-say.log` (grep `walkie:`)
  — e.g. 80-char first chunk ≈ 2.5s synth warm-model, +~2s cold load.

## Caps + tier

Task lane, one day, single worktree branch `spike/sherpa-kokoro` off
`feature/echo-streaming`. No changes outside `spikes/`. Report DONE with the
measured table + verdict; the verdict updates `docs/unification-design.md`
(P0 → resolved) and the One Echo canvas.
