#!/bin/sh
# Copy directory trees laid out like the root filesystem into the stage.
#
#     tools/stage-overlays.sh <stage-dir> [overlay...]
#
# Fonts and configuration are built by scripts in toolchain/ that need the
# cross toolchain, the same arrangement as COREUTILS. What is staged is
# recorded, and tools/stage-forget.sh takes it back out at the start of the
# next stage — before the kernel and the userland install, not here. Taken
# out here, after them, a file an overlay had replaced was gone for good:
# an overlay with an /etc/passwd of its own left the next image without one.
set -e
STAGE=${1:?usage: stage-overlays.sh <stage-dir> [overlay...]}
shift
# Outside usr, etc and var, so the image rules do not install the bookkeeping.
LIST=$STAGE/.overlays
# One path per line, whatever is in it.
set -f
IFS='
'
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
