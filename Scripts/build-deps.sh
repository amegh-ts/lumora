#!/usr/bin/env bash
# Builds LGPL-only FFmpeg and libmpv into .build/deps/prefix.
# Permissively licensed helper libraries (libass, libplacebo, dav1d, luajit, freetype, harfbuzz, ...)
# come from Homebrew. GPL pieces (x264, x265, rubberband, vapoursynth, libpostproc) are never linked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/.build/deps"
SRC="$DEPS/src"
WORK="$DEPS/work"
PREFIX="$DEPS/prefix"
JOBS="$(sysctl -n hw.ncpu)"

FFMPEG_VERSION="9.1"
FFMPEG_URL="https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz"
FFMPEG_SHA256="0ac7c9b9806b58eda00a528dcba316a2f33d291d949438900efa811d04b051bd"

MPV_VERSION="0.42.0"
MPV_URL="https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz"
MPV_SHA256="bcfebbfa2b65a6d88dc97ea18117831072373e38b5785a2afb874ed4df5070dd"

HOMEBREW_DEPS=(pkg-config meson ninja dav1d libass libplacebo luajit uchardet little-cms2 libbluray zimg molten-vk vulkan-loader vulkan-headers)

for tool in meson ninja pkg-config; do
    command -v "$tool" >/dev/null || { echo "error: $tool missing — run: brew install ${HOMEBREW_DEPS[*]}" >&2; exit 1; }
done

BREW="$(brew --prefix)"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$BREW/lib/pkgconfig"
export PATH="$BREW/bin:$PATH"

fetch() {
    local url="$1" sha="$2" file="$3"
    mkdir -p "$SRC"
    if [[ ! -f "$SRC/$file" ]]; then
        curl -fL --retry 3 -o "$SRC/$file.part" "$url"
        mv "$SRC/$file.part" "$SRC/$file"
    fi
    echo "$sha  $SRC/$file" | shasum -a 256 -c - >/dev/null || { echo "error: checksum mismatch for $file" >&2; exit 1; }
}

fetch "$FFMPEG_URL" "$FFMPEG_SHA256" "ffmpeg-$FFMPEG_VERSION.tar.gz"
fetch "$MPV_URL" "$MPV_SHA256" "mpv-$MPV_VERSION.tar.gz"

FFMPEG_STAMP="$PREFIX/.ffmpeg-$FFMPEG_VERSION"
if [[ ! -f "$FFMPEG_STAMP" || "${REBUILD_FFMPEG:-}" == "1" ]]; then
    rm -rf "$PREFIX"
fi
rm -rf "$WORK"
mkdir -p "$WORK" "$PREFIX"
tar -xzf "$SRC/mpv-$MPV_VERSION.tar.gz" -C "$WORK"

if [[ -f "$FFMPEG_STAMP" ]]; then
    echo "==> FFmpeg $FFMPEG_VERSION already built (REBUILD_FFMPEG=1 to force)"
else
tar -xzf "$SRC/ffmpeg-$FFMPEG_VERSION.tar.gz" -C "$WORK"
echo "==> FFmpeg $FFMPEG_VERSION (LGPL)"
(
    cd "$WORK/FFmpeg-n$FFMPEG_VERSION"
    ./configure \
        --prefix="$PREFIX" \
        --enable-shared --disable-static \
        --disable-programs --disable-doc --disable-debug \
        --disable-autodetect \
        --enable-videotoolbox --enable-audiotoolbox --enable-securetransport \
        --enable-zlib --enable-bzlib --enable-iconv \
        --enable-libdav1d \
        --disable-encoders --enable-encoder=png,mjpeg,ljpeg,aac,pcm_s16le \
        --disable-indevs --disable-outdevs \
        --disable-gpl --disable-nonfree \
        --extra-cflags="-I$BREW/include" --extra-ldflags="-L$BREW/lib" --extra-libs="-liconv" \
        --install-name-dir="$PREFIX/lib" > "$WORK/ffmpeg-configure.log"
    grep -E "^License:" "$WORK/ffmpeg-configure.log" || true
    make -j"$JOBS" > "$WORK/ffmpeg-build.log" 2>&1
    make install > /dev/null
)
touch "$FFMPEG_STAMP"
fi

echo "==> mpv $MPV_VERSION (libmpv, -Dgpl=false)"
(
    cd "$WORK/mpv-$MPV_VERSION"
    # Let gpu-context=macvk render into Lumora's own view (see the patch for details).
    python3 "$ROOT/Scripts/patches/mpv-macvk-embed.py" .
    meson setup build \
        --prefix="$PREFIX" \
        --buildtype=release \
        -Dgpl=false \
        -Dlibmpv=true -Dcplayer=false \
        -Dlua=luajit -Djavascript=disabled \
        -Drubberband=disabled -Dvapoursynth=disabled \
        -Dlibarchive=disabled -Dcaca=disabled -Dsixel=disabled -Dsdl2-audio=disabled \
        -Dvulkan=enabled -Degl=disabled \
        -Dswift-build=enabled -Dmacos-cocoa-cb=disabled -Dmacos-media-player=disabled -Dmacos-touchbar=disabled \
        -Dmanpage-build=disabled -Dhtml-build=disabled \
        -Dlibbluray=enabled -Duchardet=enabled -Dlcms2=enabled -Dzimg=enabled \
        -Dcocoa=enabled -Dgl-cocoa=enabled -Dvideotoolbox-gl=enabled \
        > "$WORK/mpv-configure.log"
    grep -iE "gpl|license" build/meson-logs/meson-log.txt | grep -iE "^Message|gpl:" | head -3 || true
    meson compile -C build -j "$JOBS" > "$WORK/mpv-build.log" 2>&1
    meson install -C build > /dev/null
)

SPARKLE_VERSION="2.10.1"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
echo "==> Sparkle $SPARKLE_VERSION"
fetch "$SPARKLE_URL" "$SPARKLE_SHA256" "Sparkle-$SPARKLE_VERSION.tar.xz"
rm -rf "$DEPS/sparkle"
mkdir -p "$DEPS/sparkle"
tar -xJf "$SRC/Sparkle-$SPARKLE_VERSION.tar.xz" -C "$DEPS/sparkle"

if otool -L "$PREFIX"/lib/*.dylib | grep -iE 'x264|x265|rubberband|vapoursynth|postproc'; then
    echo "error: GPL library linked" >&2
    exit 1
fi

echo "==> Done: $PREFIX"
ls -la "$PREFIX/lib"/*.dylib | awk '{print $5, $9}'
