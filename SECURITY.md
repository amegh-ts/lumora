# Security policy

## Supported versions

Only the latest release gets security fixes. Lumora updates itself through Sparkle (signed updates), so staying current is the fix.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Report it privately instead:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability** (GitHub private vulnerability reporting).

Include what you found, how to reproduce it (a sample file, playlist or link if it matters), and the Lumora and macOS versions. You'll get a reply within a week. Once a fix ships, the advisory is published with credit unless you'd rather stay anonymous.

## Scope

In scope:
- Files, playlists (M3U/PLS), Live TV channel lists and links that make Lumora run code, read or write files it shouldn't, or reach the network unexpectedly
- The update path (Sparkle feed and signatures) and the release workflow
- Leaks of private data, for example in crash reports

Out of scope:
- Bugs in FFmpeg, mpv or other bundled libraries that are already fixed upstream (report them upstream; tell us if our bundled copy is outdated)
- Problems that need someone to already control your Mac or your user account
- Content of third-party streams or channel lists you add yourself
