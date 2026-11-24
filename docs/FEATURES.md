# Feature status

Detailed section-by-section tracking lives in [PROGRESS.md](../PROGRESS.md). This page is the user-facing summary.

| Area | Feature | Status | Notes |
|---|---|---|---|
| Playback | Open local files | Ready | Finder open, drag-and-drop, Open dialog |
| Playback | Open network URLs | Ready | HTTP/HLS depends on AVFoundation support |
| Playback | YouTube links | Partial | Requires external `yt-dlp` |
| Playback | Play/pause/seek/volume | Ready | Keyboard and controls |
| Playback | Speed and frame step | Ready | Controls and engine API |
| Playback | A-B loop | Ready | Set from controls |
| Playback | Screenshot | Ready | Saves to Application Support and reveals in Finder |
| Playback | Resume playback | Ready | Uses `library.json` |
| Playback | Full screen | Ready | `F` key or View menu |
| Playback | Media keys | Missing | No `MPRemoteCommandCenter` integration |
| Playback | Now Playing | Missing | No `MPNowPlayingInfoCenter` integration |
| Playback | Float on top | Missing | No window level control |
| Playback | PiP | Partial | Runtime `AVPlayerView` selector; not runtime-verified |
| Subtitles | Sidecar SRT/VTT/ASS | Ready | Discovered beside media file |
| Subtitles | Embedded subtitle tracks | Ready | AVFoundation track selection |
| Subtitles | Delay and font size | Ready | Settings pane; size applies to overlay |
| Subtitles | OpenSubtitles search | Ready | Requires API key |
| Subtitles | Automatic download | Ready | Requires API key |
| UI | Auto-hiding controls | Ready | 3-second hide while playing |
| UI | Seek thumbnail preview | Ready | Disk and memory cached |
| UI | Playlist sidebar | Ready | Add, remove, clear, select |
| UI | Library window | Ready | Recent files, progress, watched marks |
| UI | Bookmarks | Ready | `B` key adds current time |
| UI | Chapters | Missing | Not parsed or displayed |
| UI | Video adjustments | Partial | Brightness, contrast, saturation, crop; no rotate/deinterlace |
| UI | Equalizer | Partial | Ten sliders persist values but are not wired into audio |
| UI | Keyboard shortcuts | Partial | Hardcoded only; no rebinding UI |
| UI | Trackpad gestures | Partial | Vertical scroll volume, horizontal scroll seek |
| Tools | Converter presets | Partial | Requires external `ffmpeg` |
| Tools | Update check | Partial | Basic appcast polling, no Sparkle |
| Tools | Crash logs | Partial | Local text logs only |
| Streaming | AirPlay toggle | Partial | Sets `allowsExternalPlayback`; no local HLS transcode |
| Streaming | Chromecast | Missing | Not implemented |
| Streaming | DLNA | Missing | Not implemented |

## Format support requirement

Wide VLC/Elmedia-like format support is a release requirement, not an optional enhancement. The current build does not meet it.

Current AVFoundation support is limited to codecs and containers provided by macOS. Common MP4, MOV, M4A, and HLS streams generally work. MKV, AV1, 10-bit HDR, ASS, VFR, 8K, odd MKV variants, RTSP, and damaged files are not reliably supported.

Required path:

1. Build libmpv from source.
2. Build LGPL-only FFmpeg with all decoders and VideoToolbox.
3. Integrate libplacebo `gpu-next` into `CAMetalLayer`.
4. Validate against the corpus listed in `PLAN.md`: HEVC, AV1, 10-bit HDR, ASS subtitles, odd MKVs, VFR, 8K, and damaged files.

Do not treat the app as feature-complete until this gap is closed.
