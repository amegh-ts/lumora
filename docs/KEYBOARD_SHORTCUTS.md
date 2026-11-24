# Keyboard shortcuts

## Application menu

| Shortcut | Action |
|---|---|
| `Cmd+,` | Settings |
| `Cmd+N` | New Player Window |
| `Cmd+O` | Open files |
| `Cmd+U` | Open Network Stream |
| `Cmd+W` | Close window |
| `Cmd+H` | Hide Lumora |
| `Cmd+M` | Minimize window |
| `Cmd+Q` | Quit Lumora |
| `Cmd+?` | Show in-app shortcut help |

## Player

| Shortcut | Action |
|---|---|
| `Space` | Play/pause |
| `Left` | Seek back 10 seconds |
| `Right` | Seek forward 10 seconds |
| `Option+Left` | Seek back 60 seconds |
| `Option+Right` | Seek forward 60 seconds |
| `Up` | Volume up 5% |
| `Down` | Volume down 5% |
| `F` | Toggle full screen |
| `P` | Toggle Picture in Picture |
| `M` | Toggle mute |
| `S` | Take screenshot |
| `B` | Add bookmark at current time |
| `L` | Toggle playlist sidebar |
| `T` | Cycle subtitle options |
| `R` | Cycle repeat mode |
| `C` | Show/hide controls |
| `[` | Previous playlist item |
| `]` | Next playlist item |
| `.` | Stop playback |

`Cmd` combinations are left to the application menu and are not handled by the player view.

## Pointer and trackpad

| Gesture | Action |
|---|---|
| Double-click video | Toggle full screen |
| Single-click video | Show controls / make view first responder |
| Hover seek bar | Show thumbnail preview |
| Vertical scroll over video | Adjust volume |
| Horizontal scroll over video | Seek |
| Drag files into player | Add and play media |

Shortcuts are hardcoded in `AppDelegate` and `PlayerViewController`; there is no rebinding UI yet.
