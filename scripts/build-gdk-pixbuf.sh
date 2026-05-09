#!/usr/bin/env bash
# build-gdk-pixbuf.sh — build gdk-pixbuf loaders for the ROCKNIX bundle
#
# Compiles gdk-pixbuf with builtin_loaders=none so every image format
# (including PNG and JPEG) ships as an explicit .so module. This is needed
# because ROCKNIX ships a broken gdk-pixbuf where the loaders.cache lists
# modules that don't exist on the read-only squashfs.
#
# Output: build/gdk-pixbuf/libgdk_pixbuf-2.0.so.0
#         build/gdk-pixbuf/loaders/libpixbufloader-*.so
#
# Only needs to be re-run when gdk-pixbuf version changes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="2.42.10"
SRC_DIR="/tmp/gdk-pixbuf-${VERSION}"
OUT="$REPO_ROOT/build/gdk-pixbuf"

die() { echo "error: $*" >&2; exit 1; }

command -v meson  >/dev/null || die "meson not found — apt-get install meson"
command -v ninja  >/dev/null || die "ninja not found — apt-get install ninja-build"
pkg-config --exists libpng   || die "libpng-dev not found — apt-get install libpng-dev"
pkg-config --exists libjpeg  || die "libjpeg-dev not found — apt-get install libjpeg62-turbo-dev"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "==> Downloading gdk-pixbuf $VERSION..."
    curl -L "https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-${VERSION}.tar.xz" \
         -o "/tmp/gdk-pixbuf-${VERSION}.tar.xz"
    tar xf "/tmp/gdk-pixbuf-${VERSION}.tar.xz" -C /tmp
fi

echo "==> Configuring..."
cd "$SRC_DIR"
rm -rf build
meson setup build \
    --buildtype=release \
    -Dpng=enabled \
    -Djpeg=enabled \
    -Dtiff=disabled \
    -Dbuiltin_loaders=none \
    -Dgio_sniffing=false \
    -Dintrospection=disabled \
    -Dinstalled_tests=false \
    -Dman=false \
    -Ddocs=false

echo "==> Building..."
cd build
LOADERS=(
    gdk-pixbuf/libpixbufloader-ani.so
    gdk-pixbuf/libpixbufloader-bmp.so
    gdk-pixbuf/libpixbufloader-gif.so
    gdk-pixbuf/libpixbufloader-icns.so
    gdk-pixbuf/libpixbufloader-ico.so
    gdk-pixbuf/libpixbufloader-jpeg.so
    gdk-pixbuf/libpixbufloader-png.so
    gdk-pixbuf/libpixbufloader-pnm.so
    gdk-pixbuf/libpixbufloader-qtif.so
    gdk-pixbuf/libpixbufloader-tga.so
    gdk-pixbuf/libpixbufloader-xbm.so
    gdk-pixbuf/libpixbufloader-xpm.so
)
ninja gdk-pixbuf/libgdk_pixbuf-2.0.so.0.4200.10 "${LOADERS[@]}"

echo "==> Installing to $OUT ..."
mkdir -p "$OUT/loaders"
cp gdk-pixbuf/libgdk_pixbuf-2.0.so.0.4200.10 "$OUT/libgdk_pixbuf-2.0.so.0"
cp gdk-pixbuf/libpixbufloader-*.so "$OUT/loaders/"

echo ""
echo "Done. $(ls "$OUT/loaders/" | wc -l) loaders built."
echo "Now run: bash scripts/deploy-rocknix.sh [thor-ip]"
