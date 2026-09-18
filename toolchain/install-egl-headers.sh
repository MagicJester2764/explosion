#!/bin/sh
# Install the Khronos EGL headers into the Quark prefix.
#
#     ./install-egl-headers.sh
#
# These are the headers that *describe* EGL, not an implementation of it. On a
# Linux system they arrive with Mesa; there is no Mesa here and there is no
# EGL, and they are still needed, because libepoxy generates its EGL dispatch
# from its own copy of the registry and that generated header includes
# `EGL/eglplatform.h` for the types. GTK's Wayland backend then includes
# epoxy's header in a file it compiles whether or not it ever makes a context.
#
# `eglplatform.h` pulls in Xlib only when `USE_X11` is defined, which it is
# not here, so nothing else comes with them.
#
# Pinned to a commit rather than a branch: these files are edited in place
# upstream, and a build should not change because somebody added an extension.
set -e

PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
COMMIT=5961a7fe64cf8a126890ced6f13d69e0a1e1b83e
BASE=https://raw.githubusercontent.com/KhronosGroup/EGL-Registry/$COMMIT/api

get() {
    path=$1
    sum=$2
    out=$PREFIX/include/$path
    mkdir -p "$(dirname "$out")"
    if [ ! -f "$out" ]; then
        echo "==> $path"
        curl -fsSL -o "$out.part" "$BASE/$path"
        mv "$out.part" "$out"
    fi
    if ! echo "$sum  $out" | sha256sum -c --status -; then
        echo "$out is not the file this was tested with (sha256 $sum)" >&2
        exit 1
    fi
}

get EGL/egl.h         a7c24c828bf2e1a4dfe6511b4f4812b948a285eb54787074015896976d4da076
get EGL/eglext.h      a5f574a0074001400c6c50232235ee00e9a67b2168bfd1c364ba0f6f52e5a75c
get EGL/eglplatform.h 25b5391655effcf363a38fa00c3154f356a3eab3d35dc067847875513cf1e441
get KHR/khrplatform.h 7b1e01aaa7ad8f6fc34b5c7bdf79ebf5189bb09e2c4d2e79fc5d350623d11e83

echo
echo "EGL headers installed into $PREFIX/include"
