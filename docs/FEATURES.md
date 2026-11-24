# Features

## Playback
- libmpv 0.42 + FFmpeg 9.1 (LGPL builds): MKV, MP4, MOV, WebM, AVI, TS, HEVC, AV1, VP9, H.264, 10-bit, multi-audio, chapters.
- Hardware decoding (VideoToolbox) with automatic software fallback.
- Metal renderer (libplacebo `gpu-next`, HDR/EDR output); OpenGL fallback chosen automatically when Metal can't start.
- Speed 0.25×–4× (kept across pause), exact A-B loop, frame stepping, bookmarks, chapters.
- Resume where you left off; Continue Watching on the start screen and in Open Recent.
- Per-file audio delay and subtitle delay.
- 10-band equalizer with presets; brightness, contrast, saturation; fit / fill / stretch; rotate.
- Network streams: HTTP(S), HLS, RTSP and more; YouTube and similar sites through yt-dlp.
- Stream quality: pick any resolution an online video offers (Video › Quality) without reloading; the default matches your display. Streams download in chunks and keep two minutes buffered, so ±10 s jumps don't stall.

## Subtitles
- Full ASS/SSA styling, SRT, VTT, PGS, VobSub.
- Sidecar files load automatically (same folder or `Subtitles/`); drop or open a subtitle file to add it to the playing video.
- OpenSubtitles search and optional auto-download (API key stored in the Keychain).

## Interface
- Floating control bar on Liquid Glass (macOS 26+), auto-hiding with the cursor; hover thumbnails on the timeline.
- Menu bar with live track, chapter, bookmark and speed menus; File → Open Recent.
- Settings: General, Video, Audio, Subtitles, Tools, Advanced.
- Mini player, keep on top, full screen, multiple windows, playlist sidebar with repeat and shuffle.
- Finder integration: Open With and default player for MKV, WebM, AVI and more without taking over QuickTime/Music formats.
- Media keys, AirPods and headphone controls, Control Center / lock screen Now Playing.
- VoiceOver labels, timeline seeking with VoiceOver, spoken on-screen messages, Reduce Motion support.

## Efficiency
- About the same memory as Elmedia at 4K with roughly half the CPU.
- When the window is hidden or minimized, video stops drawing and, after 5 s, the video output is released (audio keeps playing).
- Library and settings are written in the background, debounced; mpv's unused built-in scripts are disabled; shader cache persists.

## Updates
- Automatic, signed updates through Sparkle from GitHub Releases.

## Not yet
Picture in Picture (#4), AirPlay video (#5), Chromecast/DLNA (#6), IPTV channel lists (#24), redesigned Library and Converter windows (#25), notarization (#2).
