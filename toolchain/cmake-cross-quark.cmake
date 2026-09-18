# Toolchain file for x86_64-quark, for the few ports that build with cmake.
#
# `Generic` rather than a named system: cmake has no idea what Quark is, and
# saying so keeps it from assuming a platform's libraries and link flags. The
# compiler is the musl wrapper, which knows where a program loads and what it
# links against, so nothing else has to be said.
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(CMAKE_C_COMPILER x86_64-quark-musl-gcc)
set(CMAKE_CXX_COMPILER x86_64-quark-musl-g++)
set(CMAKE_AR x86_64-quark-ar)
set(CMAKE_RANLIB x86_64-quark-ranlib)
set(CMAKE_STRIP x86_64-quark-strip)

# A program built here cannot be run here, and cmake must not try: it probes
# with `try_run` otherwise and takes a failure to start as a failed feature.
set(CMAKE_CROSSCOMPILING TRUE)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_FIND_ROOT_PATH $ENV{HOME}/opt/cross/x86_64-quark/musl)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
