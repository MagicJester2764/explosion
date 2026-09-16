#!/bin/sh
# Lay the DejaVu fonts out as an overlay for the root filesystem.
#
#     ./stage-fonts.sh <dejavu-fonts-ttf-2.37/ttf> <overlay-dir>
#
# Four faces, a sans-serif and a monospace with a bold of each, in
# /usr/share/fonts/dejavu. The rest of the family is nearly 8 MiB more that
# nothing here asks for yet.
#
# The licence goes with them. The fonts may be copied freely provided their
# copyright and permission notices are included in every copy, and an image is
# a copy. (Its other condition, a new name for modified fonts, does not arise:
# these are not modified.)
set -e
TTF=${1:?usage: stage-fonts.sh <dejavu-ttf-dir> <overlay-dir>}
OVERLAY=${2:?usage: stage-fonts.sh <dejavu-ttf-dir> <overlay-dir>}
LICENSE=$TTF/LICENSE
[ -f "$LICENSE" ] || LICENSE=$TTF/../LICENSE
DEST=$OVERLAY/usr/share/fonts/dejavu
mkdir -p "$DEST"
for face in DejaVuSans DejaVuSans-Bold DejaVuSansMono DejaVuSansMono-Bold; do
    cp "$TTF/$face.ttf" "$DEST/"
done
cp "$LICENSE" "$DEST/LICENSE"
echo "fonts: $(ls "$DEST" | wc -l) files in $DEST"
