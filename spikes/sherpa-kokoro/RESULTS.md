# Spike results — native Kokoro via sherpa-onnx (2026-08-20, night run)

Brief: `docs/spike-sherpa-kokoro.md`. Machine: this Mac (Apple Silicon),
prebuilt `sherpa-onnx v1.13.6 osx-arm64 shared` (no cmake, no build — CLT-only
Mac is enough), model package `kokoro-multi-lang-v1_0` (fp32, 53 voices,
sherpa layout: model.onnx + voices.bin + tokens.txt + espeak-ng-data +
lexicons). `./fetch-vendor.sh` reproduces the setup.

## Verdict: GO (engine) — EN parity confirmed by ear; PT fixed, round-2 ear pending

Ear check round 1 (2026-08-21, Ranny): **English perfect.** Portuguese "sounds
like an American that learned to speak very poorly" — root cause found, not a
model problem: the run omitted a language hint, and sherpa's kokoro package
defaults to **en-us espeak phonemization** for all text. The python pipeline
passes `lang="pt-br"`; sherpa's equivalent is `--kokoro-lang=pt-br` /
`SherpaOnnxOfflineTtsKokoroModelConfig.lang` (verified in the shipped C API
header + CLI help, which names pt-br explicitly). Re-rendered PT with
`--kokoro-lang=pt-br`: 2.02s / 7.53s audio (RTF 0.27), delivered as ear-check
round 2 (msg `1787281428882`). **Design note for P1:** `lang` is
instance-level config, so language switching means either two warm engines
(RSS cost TBD) or a ~2.4s reconfigure on switch — PT messages are the rarer
case; decide with the warm-RSS measurement.

Acceptance items from the brief:

1. **Loads + synthesizes: YES.** CLI `sherpa-onnx-offline-tts`, 4 threads.
2. **Voice parity: pending ear.** Speaker mapping confirmed from sherpa's own
   packaging script (`scripts/kokoro/v1.0/generate_voices_bin.py`):
   `af_heart = sid 3`, `pf_dora = sid 42` (their bin carries 53 of kokoro's
   54 voices). Ear-check message `1787280942779` delivered to Echo: chunk 1
   native EN, chunk 2 native PT.
3. **pt-BR renders: YES** (sid 42, espeak-ng data in package; duration
   plausible; ear confirms quality).
4. **Timings (cold process, `/usr/bin/time` + CLI's own stats):**

   | input | synth | audio | RTF |
   |---|---|---|---|
   | en 80 chars (sid 3) | 1.21 s | 3.87 s | 0.31 |
   | en 260 chars | 5.33 s | 13.85 s | 0.39 |
   | en 600 chars | 10.47 s | 34.91 s | 0.30 |
   | pt 130 chars (sid 42) | 2.54 s | 8.44 s | 0.30 |

   Model load ≈ **2.4 s**, once per process (wall 3.60s minus 1.21s synth on
   the 80-char run) — vs the python pipeline paying import+load per message.
   Warm first-chunk target from the brief (≤ ~2-3 s for a first sentence):
   **met** (1.21 s). Output format matches the pipeline exactly: 24 kHz mono
   PCM16 WAV.
5. **Packaging:** runtime `lib/` = **31 MB** of dylibs (Apache-2.0); model
   package ~360 MB on disk, stays user-fetched like `voice/models/` today
   (`fetch-vendor.sh` pins versions).

## Still open (next session of the spike)

- The Swift wrapper itself (`synthctl`): C API behind a thin Swift layer,
  warm-process RSS measurement, and streaming synthesis (sherpa supports a
  per-chunk callback — maps directly onto walkie chunk emission).
- Speed parameter: map `AI_SPEED=1.1` → sherpa `length_scale ≈ 0.91`, ear-check.
- Port decision for `speakable()` + walkie chunking (Swift port is P1 work,
  not spike scope).
- Note: sherpa's 53-voice bin drops one of kokoro's 54 voices; irrelevant to
  af_heart/pf_dora (ids verified) but worth knowing if voices ever change.
