# Third-party notices

## BiliDownloader

This macOS adaptation is based on [Majjcom/BiliDownloader](https://github.com/Majjcom/BiliDownloader), copyright (c) 2021–2026 Majjcom, under the MIT license. The original copyright notice and license are retained in [LICENSE](LICENSE). The original Python / PySide6 source remains in `src/`.

## FFmpeg

This software includes a separate FFmpeg command-line executable, built from the unmodified [FFmpeg/FFmpeg n9.0.2 tag](https://github.com/FFmpeg/FFmpeg/tree/n9.0.2). FFmpeg is copyright its respective developers and contributors and is distributed under **LGPL version 2.1 or later** in this build. GPL, nonfree and external third-party components are disabled. The Swift app invokes the executable as a separate process.

The SHA-256 checksum and license texts are in [`macos/vendor/ffmpeg/`](macos/vendor/ffmpeg/). The build script downloads the pinned archive and verifies it before building. The exact source archive is included in the distributed App at `Contents/Resources/FFmpegSource/`, together with the checksum, licenses, configure flags, compiler description and dynamic dependency list. No FFmpeg source modifications are applied.

Rebuild or replace the executable using [`macos/scripts/build-ffmpeg.sh`](macos/scripts/build-ffmpeg.sh). The App has an optional executable selector in Settings, so a compatible user-built replacement can be selected. Replacing the App's bundled executable changes its code signature and may require local re-signing; selecting an external executable avoids modifying the bundle.

FFmpeg is a trademark of Fabrice Bellard. See [FFmpeg's licensing information](https://ffmpeg.org/legal.html).
