#!/bin/sh
# Lay GNU Unifont out as an overlay: the font the console draws in.
#
#     ./stage-unifont.sh <unifont_all-N.hex.gz> <overlay-dir>
#
# The console is UTF-8 and was built with ASCII. Everything else it draws
# comes from a font it is given at boot, in the format Unifont is published
# in — a code point, a colon and sixteen rows of pixels, one character a
# line — so the file goes in as it came, unpacked.
#
# Having the font in the image is half of it. The other half is a line in
# `/etc/init.conf`, which is an overlay's to write since it also says what
# the session is:
#
#     run /usr/bin/setfont /usr/share/consolefonts/unifont.hex
#
# The licence: Unifont is the GNU Project's, under the GPL version 2 or later
# with the font embedding exception, and also under the SIL Open Font
# License 1.1. It is not modified here.
set -e
GZ=${1:?usage: stage-unifont.sh <unifont_all-N.hex.gz> <overlay-dir>}
OVERLAY=${2:?usage: stage-unifont.sh <unifont_all-N.hex.gz> <overlay-dir>}
DEST=$OVERLAY/usr/share/consolefonts
mkdir -p "$DEST"
gzip -dc "$GZ" > "$DEST/unifont.hex"
echo "unifont: $(wc -l < "$DEST/unifont.hex") characters in $DEST"
