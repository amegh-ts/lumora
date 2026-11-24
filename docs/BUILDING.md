# Building and packaging

## Requirements

- macOS 13 or later.
- Swift 6 toolchain or Xcode Command Line Tools.
- `iconutil` for app icon generation. It ships with Xcode Command Line Tools.
- `plutil` for plist validation. It ships with macOS.

Xcode app is not required for the SwiftPM baseline. It is required only for the final native stack in `PLAN.md`.

## Debug build

```bash
swift build
```

Binary output is printed by:

```bash
swift build --show-bin-path
```

## Release build

```bash
swift build -c release --arch arm64
```

## App bundle

```bash
chmod +x Scripts/build-app.sh
Scripts/build-app.sh
```

The script:

1. Builds the selected configuration and architecture.
2. Creates `dist/Lumora.app`.
3. Copies `Resources/Info.plist` and the release binary.
4. Strips local symbols with `strip -x`.
5. Validates `Info.plist` with `plutil`.
6. Generates `AppIcon.icns` from `Scripts/make-icon.swift`.
7. Prints bundle size with `du -sh`.

Override defaults with environment variables:

```bash
CONFIGURATION=debug ARCH=x86_64 Scripts/build-app.sh
```

Current release bundle size is about 860K.

## Bundle layout

```text
dist/Lumora.app/
  Contents/
    Info.plist
    MacOS/
      Lumora
    Resources/
      AppIcon.icns
```

`Resources/Info.plist` registers common video, audio, and subtitle extensions so Finder can open files with Lumora.

## CI

`.github/workflows/ci.yml` runs on `macos-latest`:

1. Checks out the repository.
2. Prints the Swift version.
3. Runs `Scripts/build-app.sh`.
4. Uploads `dist/Lumora.app` as an artifact.

## Data locations

Lumora writes runtime data to:

```text
~/Library/Application Support/Lumora/
  settings.json
  library.json
  Thumbnails/
  Subtitles/
  Screenshots/
  Logs/
```

## Verification

```bash
swift build
Scripts/build-app.sh
plutil -lint dist/Lumora.app/Contents/Info.plist
```

See [Troubleshooting](TROUBLESHOOTING.md) for toolchain warnings and optional tool failures.
