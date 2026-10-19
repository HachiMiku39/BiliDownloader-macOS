#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi
    rm -r "$TEMP"
}
trap cleanup EXIT
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
    for candidate in /Applications/Xcode.app /Applications/Xcode*.app; do
        if [[ -d "$candidate/Contents/Developer" ]]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$TEMP/ModuleCache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=pink:s=320x180:r=24 -t 1 -c:v libx264 -an "$TEMP/video.mp4"
ffmpeg -hide_banner -loglevel error -f lavfi -i sine=frequency=440:sample_rate=44100 -t 1 -c:a aac "$TEMP/audio.m4a"
python3 "$PROJECT/scripts/fixture-server.py" "$TEMP" "$TEMP/port" &
SERVER_PID=$!
for _ in {1..50}; do [[ -f "$TEMP/port" ]] && break; sleep 0.1; done
export BILIMAC_FIXTURE_BASE="http://127.0.0.1:$(cat "$TEMP/port")"
export BILIMAC_DATA_DIR="$TEMP/data"
if [[ " $* " == *" --scratch-path "* ]]; then
    xcrun swift test --package-path "$PROJECT" "$@"
else
    # Avoid file-provider metadata interfering with XCTest bundle signatures.
    xcrun swift test --package-path "$PROJECT" --scratch-path "$TEMP/swift-build" "$@"
fi
