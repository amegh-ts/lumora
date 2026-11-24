# Lumora

Fast, small macOS video player. Current build: Swift 6, AppKit, AVFoundation, SwiftPM.

Lumora opens local and network media with a compact AppKit player: playlist, subtitles, seek previews, library resume points, screenshots, converter presets, OpenSubtitles search, and update checks.

## Status

Implementation tracker: [PROGRESS.md](PROGRESS.md)  
Source plan: [PLAN.md](PLAN.md)

Current app is a working AVFoundation baseline. The final stack in `PLAN.md` still targets libmpv, FFmpeg, libplacebo, GRDB, Sparkle, and Sentry/PLCrashReporter.

## Requirements

- macOS 13 or later.
- Swift 6 toolchain or Xcode Command Line Tools.
- Apple Silicon for the default `arm64` bundle. Override with `ARCH=x86_64` if needed.
- Optional external tools:
  - `yt-dlp` for YouTube links.
  - `ffmpeg` for converter presets.
  - OpenSubtitles API key for subtitle search and auto-download.

## Quick start

```bash
chmod +x Scripts/build-app.sh
Scripts/build-app.sh
open dist/Lumora.app
```

Debug build:

```bash
swift build
```

## Features

- Drag-and-drop and Finder open for media files.
- Network URL and YouTube URL playback.
- Play, pause, seek, volume, speed, frame step, A-B loop.
- Audio and subtitle track selection.
- SRT/VTT/ASS sidecar subtitles, embedded subtitles, subtitle delay, OpenSubtitles search.
- Auto-hiding controls with hover thumbnails.
- Playlist sidebar, shuffle, repeat, resume playback, bookmarks.
- Library window with watched state and recent files.
- Screenshots saved into Application Support.
- Converter presets using an external `ffmpeg`.
- Local crash logs and optional appcast update checks.

## Documentation

- [Building and packaging](docs/BUILDING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Feature status](docs/FEATURES.md)
- [Keyboard shortcuts](docs/KEYBOARD_SHORTCUTS.md)
- [Settings reference](docs/SETTINGS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## Project layout

```text
Sources/LumoraApp/
  App/          Application and window controllers
  Features/     Player, playlist, library, subtitles, settings, tools
  Models/       Shared value types
  Support/      Paths, formatting, crash logging, notifications
  main.swift    Entry point
Resources/      App metadata and document type registration
Scripts/        App bundle and icon generation
docs/           Developer and user documentation
```

## Critical gap

Wide VLC/Elmedia-like format support is a release requirement. The current AVFoundation baseline does not meet it. The blocking next step is libmpv plus a custom LGPL FFmpeg build with VideoToolbox, then the test corpus from `PLAN.md`.

## Known limitations

- No libmpv/FFmpeg/libplacebo pipeline; format coverage follows AVFoundation.
- No SQLite/GRDB; settings and library use JSON.
- No Sparkle or symbolic crash reporter; update checks are basic appcast polling and crash logs are local text files.
- Chromecast, DLNA, full AirPlay transcoding, chapters, float-on-top, media keys, and Now Playing are not implemented.
- PiP uses a runtime `AVPlayerView` selector and may be unavailable on some SDKs.

## Third-party code

No third-party code is bundled today. The final native stack requires an LGPL-only dependency policy before shipping; see `PLAN.md`.
