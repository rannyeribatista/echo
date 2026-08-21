#!/bin/bash
# fetch-vendor.sh — pin + fetch the spike's binary dependencies (gitignored).
# sherpa-onnx prebuilt runtime (arm64 shared, with TTS) and the Kokoro v1.0
# multi-language package in sherpa's layout (model.onnx + voices.bin +
# tokens.txt + espeak-ng-data + lexicons). fp32 on purpose: quality parity
# with the pipeline's kokoro-v1.0.onnx is part of the spike's verdict.
set -euo pipefail
cd "$(dirname "$0")/vendor" 2>/dev/null || { mkdir -p "$(dirname "$0")/vendor"; cd "$(dirname "$0")/vendor"; }

SHERPA_TAG="v1.13.6"
RUNTIME="sherpa-onnx-${SHERPA_TAG}-osx-arm64-shared"
MODEL="kokoro-multi-lang-v1_0"

[ -d "$RUNTIME" ] || {
  gh release download "$SHERPA_TAG" --repo k2-fsa/sherpa-onnx --pattern "${RUNTIME}.tar.bz2"
  tar xjf "${RUNTIME}.tar.bz2" && rm "${RUNTIME}.tar.bz2"
}
[ -d "$MODEL" ] || {
  gh release download tts-models --repo k2-fsa/sherpa-onnx --pattern "${MODEL}.tar.bz2"
  tar xjf "${MODEL}.tar.bz2" && rm "${MODEL}.tar.bz2"
}
echo "vendor ready: $RUNTIME · $MODEL"
