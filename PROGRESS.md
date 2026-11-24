# Lumora Implementation Progress

Last updated: 2026-11-24

Legend: `[ ]` not started, `[~]` in progress, `[x]` done, `[!]` blocked.

Source plan: `PLAN.md`

## Current snapshot

- Repo started empty except `PLAN.md`.
- No git repository initialized.
- Swift 6.4.2, macOS 27.2 SDK, CommandLineTools only.
- Xcode app not installed; `xcodebuild` unavailable.
- `mpv` and `ffmpeg` not installed.
- `swift build` passes.
- `swift build -c release --arch arm64` passes.
- `Scripts/build-app.sh` produces `dist/Lumora.app`.
- Release bundle size: 860K.
- Build-warning status: only CommandLineTools linker search-path warnings remain.
- Implementation baseline uses AVFoundation/AppKit, not the final libmpv/FFmpeg/libplacebo stack.
- SwiftUI was removed because the command-line toolchain lacks the SwiftUI macro plugin.
- Docs added: `README.md` plus `docs/` pages for building, architecture, features, shortcuts, settings, and troubleshooting.
- Critical gap: wide VLC/Elmedia-like format support is a release requirement; AVFoundation baseline does not meet it. Blocking stack: libmpv + LGPL FFmpeg + libplacebo.

## Final stack

- [x] Swift 6 AppKit shell
- [!] SwiftUI panels/settings — replaced with AppKit due missing `SwiftUIMacros` plugin
- [!] libmpv playback engine — not implemented; `PlaybackEngine` uses `AVPlayer`
- [!] FFmpeg LGPL build — not bundled; converter shells out to optional `ffmpeg`
- [~] VideoToolbox hardware decoding — only indirect via AVFoundation
- [!] libplacebo `gpu-next` into `CAMetalLayer` — not implemented; rendering uses `AVPlayerLayer`
- [!] SQLite/GRDB data layer — settings/library use JSON files
- [!] Sparkle updates — `UpdateChecker` polls an appcast URL only
- [~] Crash reporting — local exception logs only

Implementation note: current app is a working AVFoundation baseline. The final stack in `PLAN.md` still requires native dependencies and Xcode-era packaging.

## Targets

- [ ] Cold start < 0.3 s, playable < 0.5 s — not measured
- [ ] Seek < 100 ms on local files — not measured
- [ ] 4K HDR HEVC at < 10% CPU — not measured
- [x] App < 35 MB — 860K release bundle
- [ ] RAM < 120 MB during 4K — not measured
- [ ] 500+ odd-file crash suite — corpus absent
- [~] Clear failures for damaged files — `presentError` paths exist, not fuzz-tested

## Staying small

- [x] arm64-only build — `Scripts/build-app.sh` defaults to `ARCH=arm64`
- [!] FFmpeg build script with LGPL-only options
- [~] Strip symbols / LTO / `-Oz` — `strip -x` and release `-O` active; no LTO or `-Osize`
- [x] Apple frameworks only — implemented baseline adds no packages
- [~] SF Symbols / asset catalog — AppKit controls and generated ICNS; no asset catalog

## Architecture

- [~] `PlayerCore` — `PlaybackEngine` exists but uses AVFoundation, not libmpv
- [x] `VideoView`
- [x] `ControlsOverlay`
- [x] `PlaylistStore`
- [x] `Library`
- [x] `ThumbnailService`
- [x] `SubtitleService`
- [~] `CastService` — AirPlay toggle only
- [x] `Settings`
- [~] Non-blocking engine/event model — KVO, Combine, and async tasks, not mpv events
- [~] Background thumbnails and metadata — thumbnails cached; metadata limited
- [x] One player instance per window

## Phases

### Phase 0 — Foundation

- [!] Source-build script for mpv, FFmpeg, libplacebo — blocked by missing native toolchains
- [x] App size measured on every build — `Scripts/build-app.sh` prints `du -sh`
- [x] GitHub Actions CI — `.github/workflows/ci.yml`
- [ ] Test library corpus setup
- [!] Bare window plays any file — release blocker: wide VLC/Elmedia format support requires libmpv + LGPL FFmpeg + libplacebo; current AVFoundation baseline is insufficient

### Phase 1 — Core player

- [x] Drag and drop open
- [~] Finder "Open with" / default app — document types registered in `Info.plist`; no default-app claim
- [x] Play, pause, seek, volume
- [x] Audio/subtitle tracks
- [~] Subtitle delay and style — delay present; style UI absent
- [ ] A/V sync — no audio-delay control
- [x] Speed, frame step, A-B loop, screenshots
- [x] Resume playback
- [x] Full screen
- [ ] Float on top
- [ ] Media keys
- [ ] Now Playing
- [~] PiP prototype — runtime selector against `AVPlayerView`; unverified at runtime

### Phase 2 — Elmedia-style UI

- [~] Borderless window — `.fullSizeContentView` used; title bar remains
- [x] Auto-hiding floating controls
- [x] Blurred backgrounds — `ControlsOverlay` uses `NSVisualEffectView`
- [x] Seek-bar thumbnail preview
- [x] Playlist sidebar
- [x] Bookmarks
- [ ] Chapters
- [~] Video adjustments — brightness, contrast, saturation, crop; no rotate/deinterlace
- [~] Custom keyboard shortcuts — hardcoded only, no rebinding UI
- [~] Trackpad gestures — basic horizontal seek and vertical volume

### Phase 3 — Power features

- [~] Full PiP — runtime selector only, unverified
- [x] OpenSubtitles search
- [x] Automatic subtitle download
- [~] Library posters / continue watching / watched marks — no TMDB posters; continue/watched data present
- [x] Network URLs
- [ ] SMB
- [~] HLS / RTSP — HLS may work via AVFoundation; no explicit RTSP support
- [x] YouTube links via `yt-dlp` — resolver shells out; `yt-dlp` not bundled

### Phase 4 — Streaming out

- [~] AirPlay HLS transcode — AirPlay toggle only; no local HLS transcode server
- [ ] Chromecast
- [ ] DLNA renderer discovery

### Phase 5 — VLC extras

- [~] Converter presets — command builder and AppKit UI present; requires external `ffmpeg`
- [ ] Encoder pack on demand
- [ ] Stream recording
- [ ] DVD menus via `libdvdnav`
- [ ] Audio visualizer

### Phase 6 — Polish and ship

- [ ] Instruments profiling
- [ ] Damaged-file fuzz suite
- [ ] Sign, notarize, Sparkle + DMG
- [ ] Mac App Store decision

## Risks

- [~] PiP with mpv: mpv bridge not applicable to AVFoundation baseline; native selector unverified
- [ ] AirPlay for MKV: transcode path not built
- [~] GPL code: no GPL/native deps bundled; written LGPL-only lock absent
- [~] Feature creep: phases 0–2 baseline exists, full plan not complete

## Open decisions

- [ ] Distribution: direct / Mac App Store
- [ ] Source: open / closed
- [ ] Name check for Lumora

## Files created so far

- `PLAN.md`
- `PROGRESS.md`
- `README.md`
- `docs/BUILDING.md`
- `docs/ARCHITECTURE.md`
- `docs/FEATURES.md`
- `docs/KEYBOARD_SHORTCUTS.md`
- `docs/SETTINGS.md`
- `docs/TROUBLESHOOTING.md`
- `Package.swift`
- `.gitignore`
- `.github/workflows/ci.yml`
- `Resources/Info.plist`
- `Scripts/build-app.sh`
- `Scripts/make-icon.swift`
- `Sources/LumoraApp/main.swift`
- `Sources/LumoraApp/App/AppDelegate.swift`
- `Sources/LumoraApp/App/MainWindowController.swift`
- `Sources/LumoraApp/Models/Models.swift`
- `Sources/LumoraApp/Support/AppPaths.swift`
- `Sources/LumoraApp/Support/CrashReporter.swift`
- `Sources/LumoraApp/Support/Notifications.swift`
- `Sources/LumoraApp/Features/Player/ControlsOverlay.swift`
- `Sources/LumoraApp/Features/Player/PlaybackEngine.swift`
- `Sources/LumoraApp/Features/Player/PlayerRootView.swift`
- `Sources/LumoraApp/Features/Player/PlayerViewController.swift`
- `Sources/LumoraApp/Features/Player/SeekSlider.swift`
- `Sources/LumoraApp/Features/Player/ThumbnailPreviewView.swift`
- `Sources/LumoraApp/Features/Player/VideoView.swift`
- `Sources/LumoraApp/Features/Thumbnails/ThumbnailService.swift`
- `Sources/LumoraApp/Features/Subtitles/SubtitleOverlayView.swift`
- `Sources/LumoraApp/Features/Subtitles/SubtitleService.swift`
- `Sources/LumoraApp/Features/Subtitles/SubtitleSearchWindowController.swift`
- `Sources/LumoraApp/Features/Updates/UpdateChecker.swift`
- `Sources/LumoraApp/Features/Library/LibraryWindowController.swift`
- `Sources/LumoraApp/Features/Library/LibraryStore.swift`
- `Sources/LumoraApp/Features/Network/OpenSubtitlesService.swift`
- `Sources/LumoraApp/Features/Network/YouTubeResolver.swift`
- `Sources/LumoraApp/Features/Cast/CastService.swift`
- `Sources/LumoraApp/Features/Converter/ConverterWindowController.swift`
- `Sources/LumoraApp/Features/Converter/ConverterService.swift`
- `Sources/LumoraApp/Features/Playlist/PlaylistSidebar.swift`
- `Sources/LumoraApp/Features/Playlist/PlaylistStore.swift`
- `Sources/LumoraApp/Features/Settings/SettingsStore.swift`
- `Sources/LumoraApp/Features/Settings/SettingsWindowController.swift`
- `dist/Lumora.app` — generated, ignored

## Build and verify commands

- `swift build`
- `swift build -c release --arch arm64`
- `chmod +x Scripts/build-app.sh && Scripts/build-app.sh`
- `plutil -lint dist/Lumora.app/Contents/Info.plist`

## Next chat handoff

1. Read `PLAN.md` and this file first.
2. Treat wide VLC/Elmedia-like format support as the top release blocker.
3. Continue from highest-priority unchecked or blocked item.
4. Current build baseline is green; preserve that before adding native dependencies.
5. Update this file after every completed section.
6. Keep code comments out unless explicitly requested.
7. Do not commit; user has not asked.

## 2026-11-24 — libmpv engine swap + player UI rebuild

- [x] libmpv playback engine (`PlaybackEngine` over libmpv, `CMPV` system library target, Homebrew mpv 0.42 for dev)
- [x] Rendering: mpv render API into `CAOpenGLLayer` (`VideoView.swift`); Metal/libplacebo path still to do
- [x] MKV/ASS/multi-audio/chapters verified with generated test file; frames verified by GL readback
- [x] Native ASS subtitles, sidecar auto-load, `sub-add`, sub delay/scale via mpv
- [x] Speed persists across pause; exact A-B loop (`ab-loop`); frame step both ways; equalizer, video adjustments, hwdec settings now live
- [x] YouTube via mpv ytdl hook (full quality, stable URL for resume); old `YouTubeResolver` removed
- [x] Thumbnails via headless mpv (`vo=image`), latest-request-wins queue, SHA256 cache keys, 14-day prune
- [x] New player UI: floating HUD control bar, custom timeline (hover knob, chapter ticks, A-B region), thumbnail preview at cursor, OSD toasts, empty state with Continue Watching, title overlay, auto-hide incl. cursor and window buttons, mini player, keep on top, context menu
- [x] Menu fixes: Edit menu added, no more ⌘C/⌘P/⌘S/⌘Space collisions, arrow-key shortcuts real
- [x] Window/controller lifecycle: extra windows retained, close stops playback and frees mpv
- [x] Converter: never overwrites source, `hvc1` tag fixed
- [x] Subtitle download filename/language sanitised; auto-search sends only local filename
- [!] AirPlay video / PiP: removed (were AVPlayer-only); needs phase 4 work
- [!] App links Homebrew `libmpv.2.dylib`; must bundle LGPL build before distributing
- Debug harness (DEBUG builds only): `LUMORA_OPEN`, `LUMORA_SNAPSHOT_DIR`, `LUMORA_SNAPSHOT_STEPS`, `LUMORA_MUTE`, `LUMORA_GL_PROBE`, `LUMORA_MPV_LOG`
