# Architecture

## Current baseline

Lumora is an AppKit shell around an AVFoundation playback engine. It is intentionally dependency-free and builds with SwiftPM and Command Line Tools.

```text
AppDelegate
  ├─ MainMenu
  ├─ MainWindowController
  │   ├─ PlaybackEngine (AVPlayer)
  │   ├─ PlaylistStore
  │   └─ PlayerViewController
  │       ├─ VideoView (AVPlayerLayer)
  │       ├─ ControlsOverlay
  │       ├─ SubtitleOverlayView
  │       ├─ PlaylistSidebar
  │       └─ Picture-in-Picture helper view
  ├─ SettingsWindowController
  ├─ LibraryWindowController
  ├─ SubtitleSearchWindowController
  └─ ConverterWindowController
```

## Final plan vs current implementation

| Layer | Plan | Current |
|---|---|---|
| UI | AppKit shell + SwiftUI panels | AppKit only |
| Playback | libmpv wrapper | `AVPlayer` in `PlaybackEngine` |
| Decode | FFmpeg LGPL + VideoToolbox | AVFoundation, indirect hardware decode |
| Render | libplacebo `gpu-next` into `CAMetalLayer` | `AVPlayerLayer` |
| Data | SQLite/GRDB | JSON files |
| Updates | Sparkle | appcast polling |
| Crash reports | Sentry/PLCrashReporter | local text logs |

The playback/rendering gap is the reason the current build does not meet the VLC/Elmedia format-support requirement. Closing it requires replacing `PlaybackEngine` and `VideoView`, not adding codec checks around AVFoundation.

## Startup flow

1. `main.swift` configures `NSApplication` and installs `AppDelegate`.
2. `AppDelegate.applicationDidFinishLaunching`:
   - creates Application Support directories,
   - installs the local crash reporter,
   - warms `SettingsStore` and `LibraryStore`,
   - installs the main menu,
   - shows the main window,
   - starts an update check when enabled.
3. `MainWindowController` creates one `PlaybackEngine`, one `PlaylistStore`, and one `PlayerViewController` per window.

## Opening media

`MainWindowController.open(_:)`:

1. Detects YouTube URLs and resolves them through `yt-dlp`.
2. Builds `PlaybackItem` values.
3. Adds them to `PlaylistStore`.
4. Calls `playCurrent()`.
5. `playCurrent()` reads the saved resume time from `LibraryStore` when enabled and loads the item into `PlaybackEngine`.

Local files, drags, Finder open, and library double-click all use this path.

## Playback

`PlaybackEngine` owns the `AVPlayer` and provides:

- load/stop, play/pause, seek, skip, volume, mute, rate,
- periodic time observers and KVO for rate/external playback,
- audio and subtitle track selection,
- frame step,
- A-B loop,
- screenshot export.

UI state is exposed through Combine properties and callbacks. UI work is marshalled to the main actor.

## Rendering

`VideoView` hosts an `AVPlayerLayer` and applies Core Image filters for brightness, contrast, and saturation. Crop is implemented through `contentsRect`.

`SubtitleOverlayView` draws parsed sidecar cues above the video layer. Embedded subtitle tracks are handled by AVFoundation track selection.

## Controls

`ControlsOverlay` is an `NSVisualEffectView` containing transport controls, volume, seek slider, track menus, and thumbnail preview. `PlayerRootView` forwards mouse, keyboard, scroll, and drag events to `PlayerViewController`.

Controls auto-hide during playback and reappear on activity.

## Playlist and library

`PlaylistStore` tracks items, selection, shuffle, and repeat mode.

`LibraryStore` persists `LibraryRecord` values to `library.json` with:

- resume time,
- duration,
- last played date,
- watched state,
- bookmarks.

## Subtitles

`SubtitleService` parses SRT, VTT, and ASS cues and discovers sidecar files next to the media file.

`OpenSubtitlesService` calls the OpenSubtitles REST API with an API key from Settings. Downloads are saved into Application Support and added to the active subtitle list.

## Thumbnails

`ThumbnailService` generates seek previews with `AVAssetImageGenerator`. PNG data is produced on a utility task and cached on disk; `NSImage` objects are cached on the main actor.

## External tools

- `YouTubeResolver` shells out to `yt-dlp`.
- `ConverterService` shells out to `ffmpeg` with preset argument sets.
- `UpdateChecker` fetches a simple appcast-style XML feed and compares dotted version strings.

None of these tools are bundled.

## Persistence

Settings are stored in `settings.json` through a `Codable` snapshot in `SettingsStore`. All UI settings persist automatically through `didSet`.

Runtime directories are defined in `AppPaths`.

## Concurrency model

- UI controllers and stores are `@MainActor`.
- AVPlayer callbacks hop to the main actor.
- URLSession calls are `async`.
- Thumbnail and converter work runs in `Task.detached`.
- `isolated deinit` is used where observers must be removed from main-actor state.

## Extension points

- Replace `PlaybackEngine` with a libmpv-backed implementation for the final stack.
- Replace `VideoView` with a `CAMetalLayer` renderer.
- Replace JSON stores with GRDB while keeping store APIs stable.
- Add Sparkle behind `UpdateChecker`.
- Add structured crash reporting behind `CrashReporter`.
