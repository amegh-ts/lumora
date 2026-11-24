# Settings reference

Settings are stored in `~/Library/Application Support/Lumora/settings.json`. The API key field is secure in the UI, but the value is saved in plain JSON in that user-local file, not the Keychain.

## General

| Setting | Default | Behavior |
|---|---|---|
| Remember playback position | On | Loads saved resume time when reopening media |
| Autoplay next item | On | Advances through playlist |
| Shuffle | Off | Random playlist order |
| Repeat | Off | Off, All, or One |
| Video scaling | Aspect | Aspect, Fill, or Stretch |
| Check for updates | On | Runs a daily appcast check when a feed URL is set |
| Appcast URL | Empty | XML feed URL used by `UpdateChecker` |

Expected appcast fields are `<version>`, `<releaseNotes>` or `<description>`, and `<enclosure url="...">`.

## Playback

| Setting | Default | Behavior |
|---|---|---|
| Volume | 1 | Initial player volume |
| Hardware decoding | On | Persisted preference; no explicit AVFoundation toggle yet |
| Brightness | 0 | Core Image brightness adjustment |
| Contrast | 1 | Core Image contrast adjustment |
| Saturation | 1 | Core Image saturation adjustment |
| Equalizer 31–16k | 0 | Ten persisted gain values; not currently applied to audio |

## Subtitles

| Setting | Default | Behavior |
|---|---|---|
| Font size | 24 | Overlay cue font size |
| Delay | 0 | Subtitle timing offset in seconds |
| Download automatically | Off | Searches OpenSubtitles when media loads |
| Languages | `en` | Language list passed to OpenSubtitles |
| API key | Empty | Required for OpenSubtitles search and download |

## Tools

| Setting | Default | Behavior |
|---|---|---|
| yt-dlp path | `/opt/homebrew/bin/yt-dlp` | Executable used for YouTube URL resolution |
| ffmpeg path | `/opt/homebrew/bin/ffmpeg` | Executable used by converter presets |

Crash logs are stored locally under `~/Library/Application Support/Lumora/Logs/`. Nothing is uploaded.
