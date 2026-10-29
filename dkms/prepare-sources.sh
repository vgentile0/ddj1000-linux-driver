#!/bin/sh
# DKMS PRE_BUILD hook: extract sound/usb for the target kernel and patch it.
#
# Usage: prepare-sources.sh <kernelver>
# Runs inside the DKMS build directory.
#
# Source of truth is Debian's linux-source-X.Y package
# (/usr/src/linux-source-X.Y.tar.xz), which carries the same Debian patches
# as the installed kernel. The patch is chosen by kernel series (X.Y).

set -eu

kver="${1:?kernel version required}"
series="$(printf '%s\n' "$kver" | cut -d. -f1,2)"
here="$(pwd)"
patch_file="$here/patches/snd-usb-audio-ddj1000-$series.patch"

log() { printf 'ddj1000-dkms: %s\n' "$*"; }
die() { printf 'ddj1000-dkms: ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$patch_file" ] || die "no patch for kernel series $series (expected $patch_file).
Supported series: $(ls "$here/patches" | sed -n 's/^snd-usb-audio-ddj1000-\(.*\)\.patch$/\1/p' | tr '\n' ' ')"

tarball=""
for ext in tar.xz tar.bz2 tar.gz; do
    if [ -f "/usr/src/linux-source-$series.$ext" ]; then
        tarball="/usr/src/linux-source-$series.$ext"
        break
    fi
done
[ -n "$tarball" ] || die "missing /usr/src/linux-source-$series.tar.xz
Install it with: sudo apt install linux-source-$series"

# Warn if the source package and the kernel image come from different
# Debian revisions: the build usually still works within one stable series,
# but matching versions are the safe case.
if command -v dpkg-query >/dev/null 2>&1; then
    src_ver="$(dpkg-query -W -f='${Version}' "linux-source-$series" 2>/dev/null || true)"
    img_ver="$(dpkg-query -W -f='${Version}' "linux-image-$kver" 2>/dev/null || true)"
    if [ -n "$src_ver" ] && [ -n "$img_ver" ] && [ "$src_ver" != "$img_ver" ]; then
        log "WARNING: linux-source-$series is $src_ver but linux-image-$kver is $img_ver"
    fi
fi

rm -rf "$here/src"
mkdir -p "$here/src"
log "extracting sound/usb from $tarball"
tar -xf "$tarball" -C "$here/src" --strip-components=1 \
    --wildcards "linux-source-$series/sound/usb/*"
[ -f "$here/src/sound/usb/quirks-table.h" ] || die "sound/usb not found in $tarball"

if grep -q 'PIONEER DJ DDJ-1000' "$here/src/sound/usb/quirks-table.h"; then
    die "the kernel source already contains a DDJ-1000 entry; this package is not needed or the patch must be updated"
fi

log "applying $(basename "$patch_file")"
if ! patch -d "$here/src" -p1 --batch --forward --no-backup-if-mismatch < "$patch_file"; then
    die "patch does not apply to the $series sources; the kernel changed and the patch needs an update"
fi

# Build only snd-usb-audio + snd-usbmidi-lib: drop the subdirectories of
# the other USB audio drivers (misc/, line6/, caiaq/, ...). They stay in
# use from the stock kernel and keep working with our snd-usbmidi-lib.
sed -i -E '/^obj-\$\((CONFIG_SND|CONFIG_SND_USB_LINE6)\)[[:space:]]*\+=.*\/[[:space:]]*$/d' \
    "$here/src/sound/usb/Makefile"
grep -q '^obj-\$(CONFIG_SND_USB_AUDIO)' "$here/src/sound/usb/Makefile" \
    || die "unexpected sound/usb/Makefile layout"

log "sources ready for $kver"
