#!/bin/sh
# Copy directory trees laid out like the root filesystem into the stage.
#
#     tools/stage-overlays.sh <stage-dir> [overlay...]
#
# Fonts and configuration are built by scripts in toolchain/ that need the
# cross toolchain, the same arrangement as COREUTILS. What was staged is
# recorded, so a later stage without an overlay takes its files back out, and
# the directories that leaves empty go too.
set -e
STAGE=${1:?usage: stage-overlays.sh <stage-dir> [overlay...]}
shift
# Outside usr, etc and var, so the image rules do not install the bookkeeping.
LIST=$STAGE/.overlays
# One path per line, whatever is in it.
set -f
IFS='
'
if [ -f "$LIST" ]; then
    while read -r path; do
        if [ -n "$path" ]; then
            rm -f "$STAGE/$path"
        fi
    done < "$LIST"
    rm -f "$LIST"
    for top in usr etc var; do
        if [ -d "$STAGE/$top" ]; then
            find "$STAGE/$top" -mindepth 1 -depth -type d -empty -delete
        fi
    done
    # Quark's install fills usr and etc; nothing but an overlay makes var.
    rmdir "$STAGE/var" 2>/dev/null || true
fi
for dir in "$@"; do
    if [ ! -d "$dir" ]; then
        echo "overlay: $dir is not a directory" >&2
        exit 1
    fi
    for d in $(cd "$dir" && find . -mindepth 1 -type d | sed 's|^\./||'); do
        mkdir -p "$STAGE/$d"
    done
    n=0
    for f in $(cd "$dir" && find . \( -type f -o -type l \) | sed 's|^\./||'); do
        cp -L "$dir/$f" "$STAGE/$f"
        echo "$f" >> "$LIST"
        n=$((n + 1))
    done
    echo "overlay: staged $n files from $dir"
done
