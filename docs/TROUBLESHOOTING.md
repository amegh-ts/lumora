# Troubleshooting

## `xcodebuild requires Xcode`

Exact message:

```text
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance
```

The SwiftPM baseline does not use `xcodebuild`. Use:

```bash
swift build
Scripts/build-app.sh
```

Xcode is only needed for the final native stack in `PLAN.md`.

## SwiftUI macro plugin error

Exact message:

```text
external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'
```

Cause: Command Line Tools cannot load the SwiftUI macro plugin. Current fix: panels and settings use AppKit. Do not reintroduce `@State` SwiftUI views without an Xcode toolchain.

## Linker search-path warnings

Messages:

```text
ld: warning: search path '/Library/Developer/CommandLineTools/Developer/usr/lib' not found
ld: warning: search path '/Library/Developer/CommandLineTools/Developer/Library/Frameworks' not found
```

These come from the Command Line Tools SDK configuration. Builds still succeed.

## Picture in Picture unavailable

Exact message:

```text
Picture in Picture is not available in this build.
```

PiP uses a runtime `AVPlayerView` selector because the SDK bindings are unavailable. If the selector is missing, the action shows this message and leaves playback unchanged.

## YouTube playback fails

Exact message:

```text
Install yt-dlp or set its path in Settings.
```

Install `yt-dlp` or set the correct executable path in Settings → Tools. Default path is `/opt/homebrew/bin/yt-dlp`.

## Converter fails

`ffmpeg` is not bundled. Install it or set the correct executable path in Settings → Tools. Default path is `/opt/homebrew/bin/ffmpeg`.

Failure messages from `ffmpeg` are shown in the converter window, using the last eight stderr lines.

## OpenSubtitles search returns nothing

Requirements:

- non-empty API key in Settings → Subtitles,
- non-empty query,
- valid language string such as `en`.

Failed requests return an empty list instead of an alert.

## Update check fails

Exact message:

```text
Set a valid update feed URL in Settings.
```

Set an appcast URL in Settings → General. The checker expects simple XML with `<version>`, `<releaseNotes>` or `<description>`, and `<enclosure url="...">`.

## Unsupported media

A file may fail if AVFoundation lacks the codec or container support. Common examples include MKV, AV1, 10-bit HDR, VFR, 8K, and RTSP streams. This is a release blocker: Lumora must reach VLC/Elmedia-level format coverage before shipping. The required fix is the libmpv/LGPL-FFmpeg/libplacebo stack described in `PLAN.md`; it is not implemented yet.
