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

# Homebrew can't install old versions, so the bundled Homebrew libraries are checked, not pinned:
# any difference from Scripts/brew-versions.txt is reported, and the installed set is saved in the prefix.
check_brew_versions() {
    local expected="$ROOT/Scripts/brew-versions.txt" drift=0 formula want have
    while read -r formula want; do
        [[ -z "$formula" || "$formula" == \#* ]] && continue
        have="$(basename "$(readlink "$BREW/opt/$formula" 2>/dev/null)" 2>/dev/null || true)"
        if [[ "$have" != "$want" ]]; then
            local message="Homebrew $formula is ${have:-missing}, expected $want (Scripts/brew-versions.txt)"
            if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::warning::$message"; else echo "warning: $message" >&2; fi
            drift=1
        fi
        echo "$formula ${have:-missing}"
    done < "$expected" > "$WORK/brew-versions.txt"
    if [[ "$drift" == 1 && "${STRICT_BREW_VERSIONS:-}" == "1" ]]; then
        echo "error: Homebrew versions differ (STRICT_BREW_VERSIONS=1)" >&2
        exit 1
    fi
}

fetch "$FFMPEG_URL" "$FFMPEG_SHA256" "ffmpeg-$FFMPEG_VERSION.tar.gz"
fetch "$MPV_URL" "$MPV_SHA256" "mpv-$MPV_VERSION.tar.gz"

# Only the filters mpv and Lumora use (checked against mpv 0.42.0; config and scripts are off):
#   graph plumbing and format negotiation: buffer/abuffer, buffersink/abuffersink, format/aformat,
#     scale/aresample (auto-inserted by libavfilter), null/anull
#   Lumora: equalizer (audio EQ), scale (thumbnails)
#   mpv auto filters: bwdif (deinterlace), rotate (non-90 rotation), vflip, atempo (af_lavfi_tempo),
#     xstack + crop (tiled HEIF/AVIF images)
# Adding a filter to an "af"/"vf" property in Lumora means adding it here.
FFMPEG_FILTERS="buffer,abuffer,buffersink,abuffersink,format,aformat,scale,aresample,null,anull,equalizer,bwdif,rotate,vflip,atempo,xstack,crop"
# Muxers write files. Kept: spdif (mpv audio passthrough) and the containers stream recording (#17) needs.
FFMPEG_MUXERS="spdif,matroska,webm,mpegts,mp4,mov"
FFMPEG_CONFIG_HASH="$(printf '%s|%s' "$FFMPEG_FILTERS" "$FFMPEG_MUXERS" | shasum -a 256 | cut -c1-12)"

FFMPEG_STAMP="$PREFIX/.ffmpeg-$FFMPEG_VERSION-$FFMPEG_CONFIG_HASH"
if [[ ! -f "$FFMPEG_STAMP" || "${REBUILD_FFMPEG:-}" == "1" ]]; then
    rm -rf "$PREFIX"
fi
rm -rf "$WORK"
mkdir -p "$WORK" "$PREFIX"
tar -xzf "$SRC/mpv-$MPV_VERSION.tar.gz" -C "$WORK"
check_brew_versions

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
        --disable-avdevice --disable-indevs --disable-outdevs \
        --disable-muxers --enable-muxer="$FFMPEG_MUXERS" \
        --disable-filters --enable-filter="$FFMPEG_FILTERS" \
        --disable-gpl --disable-nonfree \
        --extra-cflags="-I$BREW/include" --extra-ldflags="-L$BREW/lib" --extra-libs="-liconv" \
        --install-name-dir="$PREFIX/lib" > "$WORK/ffmpeg-configure.log"
    grep -E "^License:" "$WORK/ffmpeg-configure.log" || true
    if grep -i "did not match anything" "$WORK/ffmpeg-configure.log"; then
        echo "error: unknown FFmpeg filter or muxer name" >&2
        exit 1
    fi
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
        -Dlibavdevice=disabled \
        -Dlibbluray=enabled -Duchardet=enabled -Dlcms2=enabled -Dzimg=enabled \
        -Dcocoa=enabled -Dgl-cocoa=enabled -Dvideotoolbox-gl=enabled \
        > "$WORK/mpv-configure.log"
    grep -iE "gpl|license" build/meson-logs/meson-log.txt | grep -iE "^Message|gpl:" | head -3 || true
    meson compile -C build -j "$JOBS" > "$WORK/mpv-build.log" 2>&1
    meson install -C build > /dev/null
)

"$ROOT/Scripts/fetch-sparkle.sh"

if otool -L "$PREFIX"/lib/*.dylib | grep -iE 'x264|x265|rubberband|vapoursynth|postproc'; then
    echo "error: GPL library linked" >&2
    exit 1
fi

cp "$WORK/brew-versions.txt" "$PREFIX/brew-versions.txt"
echo "==> Done: $PREFIX"
ls -la "$PREFIX/lib"/*.dylib | awk '{print $5, $9}'
