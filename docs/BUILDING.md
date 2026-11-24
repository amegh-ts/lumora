# Building and packaging

## Requirements

- Apple Silicon Mac, Xcode Command Line Tools (Swift 6).
- Homebrew packages used to build and link the LGPL stack:

```bash
brew install pkg-config meson ninja dav1d libass libplacebo luajit uchardet little-cms2 libbluray zimg molten-vk vulkan-loader vulkan-headers
```

`brew install mpv` is optional: it lets `swift build` work before you have run `Scripts/build-deps.sh`, but its GPL build must never ship.

## 1. Build the LGPL libraries (once per version bump)

```bash
Scripts/build-deps.sh
```

Downloads pinned, checksum-verified sources of FFmpeg 9.1 and mpv 0.42.0, builds them without any GPL or
nonfree parts into `.build/deps/prefix`, and unpacks Sparkle 2.10.1 into `.build/deps/sparkle`.
The script fails if a GPL library ends up linked.

### Video renderers

- **Metal (default)**: mpv `vo=gpu-next` (libplacebo) with `gpu-context=macvk`, i.e. Vulkan on MoltenVK on Metal,
  with HDR/EDR output. Upstream mpv can't embed this output in another app's view on macOS, so
  `Scripts/patches/mpv-macvk-embed.py` (applied by `build-deps.sh`) lets the `wid` option name an `NSView` that mpv
  draws into. The app bundles `libMoltenVK.dylib` and its ICD manifest in `Contents/Resources/vulkan/icd.d`.
- **OpenGL**: the libmpv render API into a `CAOpenGLLayer`. Selectable in Settings → Playback → Renderer, and used
  automatically if the Metal output fails to start (the player shows "Metal unavailable — using OpenGL").

Because mpv's macOS video output synchronously hops to the main thread, the app never makes blocking libmpv calls
from the main thread: property changes are asynchronous and `mpv_terminate_destroy` runs on a background queue.

## 2. Develop

```bash
swift build
.build/debug/Lumora
```

`Package.swift` links `.build/deps/prefix` when it exists and falls back to Homebrew's libmpv otherwise.

DEBUG builds read these environment variables (see `Sources/LumoraApp/Support/DebugHarness.swift`):
`LUMORA_OPEN`, `LUMORA_SNAPSHOT_DIR`, `LUMORA_SNAPSHOT_STEPS`, `LUMORA_MUTE`, `LUMORA_GL_PROBE`, `LUMORA_MPV_LOG`.

## 3. App and DMG

```bash
Scripts/make-dmg.sh
```

Builds `dist/Lumora.app`, copies every non-system dylib plus `Sparkle.framework` into
`Contents/Frameworks`, rewrites load paths to `@rpath`, signs, and creates `dist/Lumora-<version>.dmg`.
The script refuses to run without the LGPL build unless `ALLOW_HOMEBREW_MPV=1` is set for a local-only test.

### Signing and notarization

Without arguments the app is ad-hoc signed: it runs on the Mac that built it, and other Macs need
right-click → Open the first time.

With a paid Apple Developer account:

1. Create a **Developer ID Application** certificate in Xcode or on developer.apple.com.
2. Store notarization credentials once (you will be asked for an app-specific password):

```bash
xcrun notarytool store-credentials lumora-notary --apple-id <apple-id> --team-id <TEAMID>
```

3. Build, sign with the hardened runtime (`Resources/Lumora.entitlements`), notarize and staple:

```bash
SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=lumora-notary Scripts/make-dmg.sh
```

## 4. Update feed (Sparkle)

The app checks `https://github.com/amegh-ts/lumora/releases/latest/download/appcast.xml`.
Updates are signed with an EdDSA key stored in the login Keychain under the account `lumora`
(public key in `Resources/Info.plist` → `SUPublicEDKey`).

```bash
Scripts/make-appcast.sh
```

signs the DMG and writes `dist/appcast.xml`. Upload both files to the GitHub release `v<version>`.

Back up the private key — losing it means existing installs can't verify future updates:

```bash
.build/deps/sparkle/bin/generate_keys --account lumora -x lumora-sparkle-key.txt
```

Keep that file somewhere safe and out of the repository.

## Releasing

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Commit to `develop`, push, open a PR `develop` → `main` with release notes.
3. After merging: `Scripts/make-dmg.sh`, `Scripts/make-appcast.sh`, tag `v<version>`, and create a GitHub
   release with the notes, the DMG and `appcast.xml` attached.
