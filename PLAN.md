# Lumora — Build Plan

Fast, reliable, small macOS video player. VLC-level format support, Elmedia-style UI.

Platform: **macOS only** (Apple Silicon first). If Windows/Linux needed later, only the UI layer changes; engine stays.

---

## Final stack

| Layer | Choice | Why |
|---|---|---|
| Language / UI | Swift 6. AppKit for window, video, timeline. SwiftUI for panels and settings | Native, instant start, low RAM |
| Playback engine | libmpv (built from source) | Plays all formats, best image quality, small API |
| Decoding | FFmpeg (LGPL build) + VideoToolbox hardware decoding | Low CPU, cool laptop, long battery |
| Rendering | libplacebo `gpu-next` into `CAMetalLayer` | No extra frame copies, HDR, 120 Hz |
| Data | SQLite (GRDB) | Library, resume points, bookmarks |
| Updates | Sparkle | Small delta updates |
| Crash reports | Sentry or PLCrashReporter | Catch crashes on user machines |

Rejected: Electron, Tauri, Flutter (slower, bigger). libVLC (bigger, weaker rendering).

---

## Targets ("best of the best")

**Speed**
- Cold start < 0.3 s; file playing < 0.5 s
- Seek < 100 ms on local files
- 4K HDR HEVC at < 10% CPU on Apple Silicon

**Size**
- App < 35 MB (IINA ~100 MB, VLC ~150 MB)
- RAM < 120 MB while playing 4K

**Reliability**
- Zero crashes across a 500+ odd-file test library
- Damaged files fail with clear message, never hang

---

## Staying small

1. Build `arm64` only — roughly halves size. Separate Intel build only if needed.
2. Custom FFmpeg build: keep every decoder; drop encoders, FFmpeg CLI tools, docs, unused filters. Converter encoders become optional download later.
3. Strip symbols (`strip -x`), link-time optimization, `-Oz` on bundled libraries.
4. Use Apple frameworks for networking, JSON, images — no extra packages.
5. Asset catalog with SF Symbols, no PNG icon sets.

---

## Architecture

```
App (AppKit shell)
 ├─ PlayerCore        Swift wrapper over libmpv (commands, property observers, events)
 ├─ VideoView         CAMetalLayer + mpv render context
 ├─ ControlsOverlay   floating bar, timeline, thumbnail preview
 ├─ PlaylistStore     playlists, shuffle/repeat, history
 ├─ Library           SQLite: watched, resume points, bookmarks, posters
 ├─ ThumbnailService  separate low-priority mpv instance for seek-bar previews
 ├─ SubtitleService   local + OpenSubtitles search
 ├─ CastService       AirPlay / Chromecast / DLNA (later phase)
 └─ Settings          SwiftUI preferences
```

Rules:
- UI never waits on mpv. All engine calls non-blocking; results come back as events.
- Thumbnails and metadata made in background, cached on disk.
- One mpv instance per player window.

---

## Phases

### Phase 0 — Foundation (1 week)
- Script that builds mpv, FFmpeg, libplacebo from source (LGPL-only options locked)
- App size measured on every build; GitHub Actions CI
- Test library: HEVC, AV1, 10-bit HDR, ASS subtitles, odd MKVs, VFR, 8K, damaged files
- **Done when:** bare window plays any file, app < 35 MB.

### Phase 1 — Core player (2 weeks)
- Open via drag and drop, Finder "Open with", default app; play, pause, seek, volume
- Audio/subtitle tracks, subtitle delay and style, A/V sync
- Speed, frame step, A-B loop, screenshots
- Resume playback, full screen, float on top, media keys, Now Playing
- Early Picture-in-Picture prototype (risk check)
- **Done when:** whole test library plays without crash; start-up targets met.

### Phase 2 — Elmedia-style UI (2–3 weeks)
- Borderless window, auto-hiding floating controls, blurred backgrounds
- Thumbnail preview on seek-bar hover
- Playlist sidebar, bookmarks, chapters
- Video adjustments (brightness, contrast, crop, rotate, deinterlace), 10-band equalizer
- Custom keyboard shortcuts, trackpad gestures
- **Done when:** feels finished for everyday use.

### Phase 3 — Power features (2–3 weeks)
- Picture-in-Picture (full)
- OpenSubtitles search, automatic subtitle download
- Library view: posters (TMDB), continue watching, watched marks
- Network playback: URLs, SMB, HLS/RTSP, YouTube links via `yt-dlp` (optional download)
- **Done when:** matches Elmedia free version.

### Phase 4 — Streaming out (3–4 weeks, hardest)
- AirPlay: on-the-fly HLS transcode with VideoToolbox encoding, served locally
- Chromecast: same pipeline + Cast protocol
- DLNA renderer discovery
- **Done when:** matches Elmedia Pro.

### Phase 5 — VLC extras (optional)
- Converter with presets (encoder pack downloaded on demand)
- Stream recording, DVD menus via `libdvdnav`, audio visualizer

### Phase 6 — Polish and ship
- Instruments profiling: launch time, leaks, energy
- Fuzz testing with damaged files
- Sign, notarize, ship via Sparkle + DMG
- Mac App Store version only if build is LGPL-clean

**Total:** ~3 months to Elmedia Pro level. ~5–6 weeks for polished core player (phases 0–2).

---

## Risks

- **PiP with mpv:** native PiP needs sample-buffer bridge. Prototype in phase 1.
- **AirPlay for MKV:** needs transcode; expect 2–4 s start delay.
- **GPL code:** any GPL piece forces open source and blocks App Store. Lock LGPL-only build in phase 0.
- **Feature creep:** ship phases 0–2 first, add rest based on real use.

---

## Open decisions

- Distribution: direct download only, or Mac App Store too?
- Source: open source or closed?
- Name check: confirm "Lumora" free (App Store, domain, trademark) before branding.
