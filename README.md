# Lumora

Fast, native macOS video player. Plays almost anything — MKV, MP4, WebM, AVI, HEVC, AV1, 10-bit, styled
subtitles, multi-audio, chapters, network streams — with a clean, modern interface.

Built with Swift and AppKit on an LGPL build of libmpv and FFmpeg, rendered with Metal (libplacebo `gpu-next`)
and falling back to OpenGL when needed.

## Install

1. Download the latest `Lumora-x.y.z.dmg` from [Releases](https://github.com/amegh-ts/lumora/releases/latest).
2. Open it and drag **Lumora** into **Applications**.
3. **First launch only:** Lumora isn't notarized by Apple yet, so macOS shows
   *"Apple could not verify 'Lumora' is free of malware"*. Click **Done**, then open
   **System Settings → Privacy & Security**, scroll down to the Lumora message and click **Open Anyway**.

   Or, in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Lumora.app
   ```

After that Lumora opens normally and updates itself (Lumora → Check for Updates…). Updates are signed and
verified before they're installed.

Requirements: Apple Silicon Mac, macOS 27. YouTube links need [yt-dlp](https://github.com/yt-dlp/yt-dlp)
(`brew install yt-dlp`).

## Features

- Hardware-accelerated decoding (VideoToolbox) of nearly every format; Metal rendering with HDR output.
- Floating control bar that fades with the cursor, timeline with chapter marks and hover thumbnails.
- Full ASS/SSA subtitle styling, sidecar auto-loading, drag-and-drop subtitles, delay and size, OpenSubtitles search.
- Audio and subtitle track menus, speed 0.25×–4×, exact A-B loop, frame stepping, bookmarks, screenshots.
- Fit / fill / stretch, rotate, mini player, keep on top, 10-band equalizer, brightness/contrast/saturation.
- Playlist sidebar, resume playback, Continue Watching start screen.
- HTTP, HLS and RTSP streams and YouTube links.

Keyboard shortcuts: Help → Keyboard Shortcuts, or [docs/KEYBOARD_SHORTCUTS.md](docs/KEYBOARD_SHORTCUTS.md).

## Build from source

```bash
brew install pkg-config meson ninja dav1d libass libplacebo luajit uchardet little-cms2 libbluray zimg molten-vk vulkan-loader vulkan-headers
Scripts/build-deps.sh     # LGPL FFmpeg + libmpv, Sparkle
Scripts/make-dmg.sh       # dist/Lumora.app and dist/Lumora-<version>.dmg
```

Details, signing and releasing: [docs/BUILDING.md](docs/BUILDING.md).

## Project

- Issues and roadmap: [GitHub Issues](https://github.com/amegh-ts/lumora/issues)
- Plan: [PLAN.md](PLAN.md) · Progress log: [PROGRESS.md](PROGRESS.md)
- Third-party licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
