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

## Window and info
- Media Info panel (⌘I): codec, resolution, HDR, bitrate, channels, hardware decoding, dropped frames and stream buffer, refreshed live.
- Go to Time (⌘J); Half, Actual, Double Size and Fit to Screen; the window keeps the video's shape while resizing, and a setting decides whether new files resize it.
- Audio files show their title, artist and album (cover art when the file has it); live streams and radio show a LIVE badge instead of a seek bar; streams show the downloaded part on the timeline.

- Picture in Picture (⌥⌘P, View menu or the ••• menu): the system's floating PiP window with play/pause and ±15 s; the main window shows a placeholder and video returns to it when PiP closes. Needs the Metal renderer.
- Mini player: compact controls on hover (play/pause, ±10 s, seek bar, close, expand), snaps to the nearest screen corner, resizes in the video's shape.
- Aspect ratio override (16:9, 4:3, 2.35:1, 1.85:1, 1:1), crop presets and deinterlacing (Off / Automatic / On) in the Video menu.

## Audio and subtitle preferences
- Subtitle font, colour, background (outline, drop shadow or dark box) and position.
- Preferred audio and subtitle languages picked automatically when a file opens.
- Volume boost up to 200% and an output device picker (Audio menu and the control bar's Audio button).

## Playlists
- .m3u, .m3u8 and .pls files open as separate playlist items with their titles; HLS stream playlists still play as one stream.
- YouTube playlist links (and videos opened from a playlist) load every video, up to 500, starting at the linked one.

## Windows
- Keyboard Shortcuts (⌘/): every shortcut in groups with key caps, searchable.
- Library (⇧⌘L): All / In Progress / Watched, search, progress per item, right-click to play, show in Finder, copy link, mark watched or remove; Clear History.
- Subtitle search: language picker, download counts, hearing-impaired marks, clear messages for a missing or rejected API key.
- Convert Media: drop a file, pick a format with a plain description, choose where to save, cancel, show the result in Finder.
- Open URL fills in a link from the clipboard and accepts links typed without https://.

## Live TV
- Live TV lives in the player: a channel panel (⇧⌘T, the TV button or Window › Live TV) with Favourites, Recent and All, category and country filters, search, channel numbers, logos and stars. The playing channel is highlighted.
- Add M3U lists by link or file (iptv-org presets: 11,000+ free channels, or by country, news, movies, music, sports), or paste a list link into Open URL; lists are kept on this Mac and refreshed daily.
- Change channels with the control bar's channel up/down buttons, ⌘↑ / ⌘↓, Page Up / Page Down, by typing a channel number, or ⌫ for the previous channel. Channel up/down stays within the tab, category, country or search you picked from.
- A TV-style banner shows logo, number, name, category, country and a favourite star on every switch; ⌘D adds the current channel to favourites.
- Dead channels: picked directly, Lumora says so and stays; reached by channel up/down, it counts down and moves on (Stay Here cancels). Failed channels are dimmed for the session.
- Favourites, recents and channel numbers survive list updates. Watching TV never replaces your playlist of files. Per-channel browser identity and referrer (#EXTVLCOPT) are sent. TV guide, IPTV logins and internet radio are planned (#45).

## Crash reports
- After a crash, Lumora offers on the next launch to open a pre-filled GitHub issue: Lumora and macOS versions, Mac model, renderer, crash reason and the crashed thread's stack, plus the last player messages. File names, titles, links and home-folder paths are removed, and nothing is sent unless you submit the issue. "Copy Report" is there for anyone without a GitHub account; the offer can be turned off in Settings › Advanced.

## Updates
- Automatic, signed updates through Sparkle from GitHub Releases.

## Not yet
AirPlay video (#5), Chromecast/DLNA (#6), IPTV channel lists (#24), redesigned Library and Converter windows (#25), notarization (#2).
