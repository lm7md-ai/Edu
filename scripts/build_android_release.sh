#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v flutter >/dev/null 2>&1 || {
  echo "Flutter SDK is required (Flutter 3.24+)." >&2
  exit 127
}

if [[ ! -f assets/grammar/whiteboard.gbnf ]]; then
  echo "Missing required whiteboard grammar at assets/grammar/whiteboard.gbnf." >&2
  exit 1
fi

# Keep symbols outside the distributable and archive them with the release for
# crash de-obfuscation. Override SYMBOLS_DIR for CI artifact storage.
SYMBOLS_DIR="${SYMBOLS_DIR:-build/symbols/android}"
mkdir -p "$SYMBOLS_DIR"

flutter pub get
flutter test

BUILD_FLAGS=(
  --release
  --obfuscate
  "--split-debug-info=$SYMBOLS_DIR"
  --tree-shake-icons
  --target-platform=android-arm64
)

case "${1:-appbundle}" in
  appbundle)
    flutter build appbundle "${BUILD_FLAGS[@]}"
    ;;
  apk)
    flutter build apk "${BUILD_FLAGS[@]}"
    ;;
  *)
    echo "Usage: $0 [appbundle|apk]" >&2
    exit 2
    ;;
esac

echo "Release build completed. Preserve $SYMBOLS_DIR with the release artifacts."
echo "Native Gemma/VAD/ASR/TTS/embedding inference requires compatible vendor backend libraries and separately installed model weights."
