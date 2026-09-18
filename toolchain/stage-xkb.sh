#!/bin/sh
# Stage xkeyboard-config's data for a Quark image.
#
#     ./stage-xkb.sh /path/to/xkeyboard-config-2.43 <overlay-dir>
#
# Keyboard layouts: the rules that turn "us, pc105" into a set of files, and
# the symbol, keycode, compat and geometry files they name. There is no code in
# any of it — xkbcommon reads these at run time — so the package is built for
# this machine and only its data is taken.
#
# `wm` sends every client a keymap it compiled itself, so nothing needed this
# until GTK: `gdk_wayland_display_open` makes a default keymap before any
# compositor has said anything, and a NULL keymap is a null dereference three
# calls later.
#
# The tree is pruned to what a keyboard here can be. Every layout of every
# language is forty megabytes of an image that has one keyboard in it.
set -e

SRC=${1:?usage: stage-xkb.sh <xkeyboard-config-src> <overlay-dir>}
OVERLAY=${2:?usage: stage-xkb.sh <xkeyboard-config-src> <overlay-dir>}

BUILD=$SRC/build-host
rm -rf "$BUILD"
(cd "$SRC" && meson setup build-host --prefix="$BUILD/root")
ninja -C "$BUILD" install >/dev/null

XKB=$OVERLAY/usr/share/X11/xkb
rm -rf "$XKB"
mkdir -p "$XKB"
cp -r "$BUILD/root/share/X11/xkb/." "$XKB/"

# What a keymap actually names: the rules that map a model and layout onto
# files, and the files for a plain PC keyboard in the layouts this image has.
# `evdev` is the rule set every Wayland client asks for.
find "$XKB/symbols" -type f ! -name 'us' ! -name 'pc' ! -name 'srvr_ctrl' \
     ! -name 'capslock' ! -name 'group' ! -name 'level3' ! -name 'level5' \
     ! -name 'terminate' ! -name 'compose' ! -name 'keypad' ! -name 'eurosign' \
     ! -name 'inet' ! -name 'altwin' ! -name 'ctrl' ! -name 'shift' \
     ! -name 'nbsp' ! -name 'typo' ! -name 'kpdl' ! -name 'empty' -delete
find "$XKB/geometry" -type f ! -name 'pc' -delete
find "$XKB/rules" -type f ! -name 'evdev*' -delete
find "$XKB" -type d -empty -delete

echo "staged $(find "$XKB" -type f | wc -l) files into $XKB"
