# Third-party notices

Lumora bundles the following libraries. Each is used as a separately linked dynamic library in
`Lumora.app/Contents/Frameworks`, so it can be replaced with a compatible build.

| Library | License | Source |
|---|---|---|
| mpv (libmpv), built with `-Dgpl=false` | LGPL 2.1 or later | https://github.com/mpv-player/mpv |
| FFmpeg (libavcodec, libavformat, libavutil, libavfilter, libavdevice, libswscale, libswresample), built without GPL or nonfree parts | LGPL 2.1 or later | https://github.com/FFmpeg/FFmpeg |
| libplacebo | LGPL 2.1 or later | https://code.videolan.org/videolan/libplacebo |
| libbluray | LGPL 2.1 or later | https://code.videolan.org/videolan/libbluray |
| libass | ISC | https://github.com/libass/libass |
| dav1d | BSD 2-Clause | https://code.videolan.org/videolan/dav1d |
| LuaJIT | MIT | https://luajit.org |
| FreeType | FreeType License | https://freetype.org |
| HarfBuzz | MIT | https://github.com/harfbuzz/harfbuzz |
| FriBidi | LGPL 2.1 or later | https://github.com/fribidi/fribidi |
| Little CMS | MIT | https://www.littlecms.com |
| uchardet | MPL 1.1 / GPL 2 / LGPL 2.1 (used under MPL) | https://www.freedesktop.org/wiki/Software/uchardet/ |
| zimg | WTFPL | https://github.com/sekrit-twc/zimg |
| Sparkle | MIT | https://github.com/sparkle-project/Sparkle |
| shaderc | Apache 2.0 | https://github.com/google/shaderc |
| Vulkan loader | Apache 2.0 | https://github.com/KhronosGroup/Vulkan-Loader |
| MoltenVK | Apache 2.0 | https://github.com/KhronosGroup/MoltenVK |
| GLib | LGPL 2.1 or later | https://gitlab.gnome.org/GNOME/glib |
| gettext (libintl) | LGPL 2.1 or later | https://www.gnu.org/software/gettext/ |
| Graphite2 | LGPL 2.1 or later / MPL 2.0 | https://github.com/silnrsi/graphite |
| libudfread | LGPL 2.1 or later | https://code.videolan.org/videolan/libudfread |
| Fontconfig | MIT-style | https://www.freedesktop.org/wiki/Software/fontconfig/ |
| PCRE2 | BSD 3-Clause | https://github.com/PCRE2Project/pcre2 |
| libunibreak | zlib | https://github.com/adah1972/libunibreak |
| libpng | libpng License | http://www.libpng.org |
| libjpeg-turbo | BSD-style / IJG | https://libjpeg-turbo.org |
| Brotli | MIT | https://github.com/google/brotli |

The exact source versions and build flags used for the LGPL libraries are recorded in
`Scripts/build-deps.sh` in the Lumora source repository. The full LGPL 2.1 text is available at
https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
