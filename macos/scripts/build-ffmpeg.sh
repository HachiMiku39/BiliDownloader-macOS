#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$PROJECT/vendor/ffmpeg"
ARCH="$(uname -m)"
OUTPUT="${1:-$PROJECT/.build/ffmpeg-$ARCH}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
SOURCE="$VENDOR/ffmpeg-n9.0.2.tar.gz"
if [[ ! -f "$SOURCE" ]]; then
    curl -fL --retry 3 --connect-timeout 20 --max-time 600 \
        https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n9.0.2 -o "$SOURCE.download"
    mv "$SOURCE.download" "$SOURCE"
fi
(cd "$VENDOR" && shasum -a 256 -c SHA256SUMS)
if [[ -x "$OUTPUT/ffmpeg" && -f "$OUTPUT/BUILD.txt" ]] && "$OUTPUT/ffmpeg" -version | head -1 | grep -q 'version 9.0.2 '; then
    otool -L "$OUTPUT/ffmpeg" | awk 'NR == 1 { print "ffmpeg:"; next } { print }' > "$OUTPUT/DEPENDENCIES.txt"
    echo "$OUTPUT/ffmpeg"
    exit 0
fi
BUILD="$OUTPUT/source"
mkdir -p "$BUILD"
tar -xf "$SOURCE" -C "$BUILD" --strip-components=1
cd "$BUILD"
# Pin the tag's release version rather than accidentally reading the parent
# application's Git revision when this source lives inside its checkout.
FLAGS=(
    --disable-autodetect --disable-gpl --disable-nonfree
    --disable-shared --enable-static --disable-debug --disable-doc
    --disable-ffplay --disable-ffprobe --disable-network --disable-everything
    --enable-ffmpeg --disable-x86asm
    --enable-protocol=file
    --enable-demuxer=mov,matroska,flv,aac,mp3,ogg,flac,concat
    --enable-muxer=mp4,ipod,flac,ogg,mp3,matroska
    --enable-parser=aac,h264,hevc,av1,flac,mpegaudio,opus,ac3
    --enable-bsf=aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb,av1_frame_merge
    --enable-decoder=aac,h264,hevc,flac,mp3,opus,vorbis,ac3,eac3
    --enable-encoder=flac
    --enable-filter=aresample,anull
    --extra-cflags=-mmacosx-version-min=26.0
    --extra-ldflags=-mmacosx-version-min=26.0
)
CC="$(xcrun --find clang)" ./configure "${FLAGS[@]}"
JOBS="${BILIMAC_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
rm -f .version
make -j "$JOBS" REVISION=9.0.2 ffmpeg
cp ffmpeg "$OUTPUT/ffmpeg"
strip "$OUTPUT/ffmpeg"
{
    echo "FFmpeg 9.0.2, unmodified official FFmpeg/FFmpeg n9.0.2 tag archive."
    echo "License: LGPL-2.1-or-later; GPL and nonfree components disabled."
    echo "Architecture: $ARCH; minimum macOS: 26.0"
    echo "Source SHA-256: $(awk '{print $1}' "$VENDOR/SHA256SUMS")"
    printf 'Configure flags:'
    printf ' %s' "${FLAGS[@]}"
    printf '\n'
    echo "Build command: make -j N REVISION=9.0.2 ffmpeg; strip ffmpeg"
    echo "Compiler: $(xcrun clang --version | head -1)"
    echo "Static FFmpeg libraries; only Apple system frameworks/libraries are dynamically linked."
} > "$OUTPUT/BUILD.txt"
otool -L "$OUTPUT/ffmpeg" | awk 'NR == 1 { print "ffmpeg:"; next } { print }' > "$OUTPUT/DEPENDENCIES.txt"
if awk 'NR > 1 {print $1}' "$OUTPUT/DEPENDENCIES.txt" | grep -Ev '^(/usr/lib/|/System/Library/)' | grep -q .; then
    echo "Unexpected non-system FFmpeg dependency" >&2
    cat "$OUTPUT/DEPENDENCIES.txt" >&2
    exit 1
fi
"$OUTPUT/ffmpeg" -version | head -3
echo "Built $OUTPUT/ffmpeg"
