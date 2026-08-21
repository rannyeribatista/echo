# Spike results — native Kokoro via sherpa-onnx (2026-08-20, night run)

Brief: `docs/spike-sherpa-kokoro.md`. Machine: this Mac (Apple Silicon),
prebuilt `sherpa-onnx v1.13.6 osx-arm64 shared` (no cmake, no build — CLT-only
Mac is enough), model package `kokoro-multi-lang-v1_0` (fp32, 53 voices,
sherpa layout: model.onnx + voices.bin + tokens.txt + espeak-ng-data +
lexicons). `./fetch-vendor.sh` reproduces the setup.

## Verdict: GO (engine) — voice parity pending Ranny's ear check

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
