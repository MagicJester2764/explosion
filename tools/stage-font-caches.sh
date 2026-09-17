#!/bin/sh
# Build fontconfig's caches for the fonts in the stage, as fc-cache on Quark
# would write them, so that the image comes with them.
#
#     tools/stage-font-caches.sh <stage-dir>
#
# Does nothing unless the stage has a fontconfig configuration. Runs
# quark-fc-cache, the host build of the same fontconfig (build-fontconfig.sh
# makes it), over the stage as a sysroot. Its caches match what Quark's would
# be except for one thing, the time of each font directory they record, which
# is why every font directory is set to a whole second first: Quark's clock
# has no fraction, and tools/populate-ext.sh carries staged times into the
# image. What it writes is listed with the overlays, so a stage without fonts
# takes it back out.
set -e
STAGE=${1:?usage: stage-font-caches.sh <stage-dir>}
HOSTDEPS=${QUARK_HOSTDEPS:-${QUARK_SRC:-$HOME/opt/src}/host-deps}
FC_CACHE=$HOSTDEPS/bin/quark-fc-cache
CONF=$STAGE/etc/fonts/fonts.conf
CACHE=var/cache/fontconfig

[ -f "$CONF" ] || exit 0
if [ ! -x "$FC_CACHE" ]; then
    echo "font caches: no $FC_CACHE (toolchain/build-fontconfig.sh makes it); the image goes without" >&2
    exit 0
fi

now=$(date +%s)
if [ -d "$STAGE/usr/share/fonts" ]; then
    find "$STAGE/usr/share/fonts" -type d -exec touch -d "@$now" {} +
fi
mkdir -p "$STAGE/$CACHE"
find "$STAGE/$CACHE" -mindepth 1 \( -type f -o -type l \) -delete
FONTCONFIG_FILE="$(cd "$(dirname "$CONF")" && pwd)/fonts.conf" \
    "$FC_CACHE" -s -f -y "$(cd "$STAGE" && pwd)"
n=0
for f in $(cd "$STAGE" && find "$CACHE" -mindepth 1 \( -type f -o -type l \)); do
    echo "$f" >> "$STAGE/.overlays"
    n=$((n + 1))
done
echo "font caches: $n files in $CACHE"
