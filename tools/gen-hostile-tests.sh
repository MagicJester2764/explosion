#!/bin/sh
# Write the list runtests reads to give every program arguments nobody would
# give it on purpose.
#
#     tools/gen-hostile-tests.sh <stage-dir>
#
# One line for each program in the staged /usr/bin and each of the argument
# sets below, into <stage-dir>/etc/hostile.tests. Every line is `? @30`: a
# program may complain and exit with any status it likes, but it may not fault
# and it may not run for more than thirty seconds. runtests gives a program no
# standard input, so one that reads it has to notice.
#
# Some programs are left out, because starting them with arbitrary arguments
# does something other than test them: `shutdown` stops the machine, `login`
# and `runtests` take over the console, `wm` takes the display, and `qfuzz`
# fuzzes every service in the system. So are the programs another list runs —
# a suite's own tests, which read their arguments as test numbers and
# iteration counts, and which their suite runs with the arguments they expect.
# A test harness told to run ten billion iterations is not a program falling
# over, and zlib's `example` writes a gzip file over whatever path it is
# given.
#
# The file `/etc/hostile-sample` is written here to be that path: something
# that exists, that a program may read, write or destroy, and that nothing
# else needs.
set -e

STAGE=${1:?usage: gen-hostile-tests.sh <stage-dir>}
OUT=$STAGE/etc/hostile.tests

LONG=$(printf '%300s' '' | tr ' ' x)
CTRL=$(printf '\001')

# Every program a port's own suite runs. `selftest.tests` is runtests testing
# itself and `fuzz.tests` is the service fuzzer: both name programs of ours,
# which are exactly the ones to sweep.
SUITE=$(for list in "$STAGE"/etc/*.tests; do
    [ -f "$list" ] || continue
    case "$(basename "$list")" in
    hostile.tests|selftest.tests|fuzz.tests) continue ;;
    esac
    sed -e '/^#/d' -e 's/^? *//' -e 's/^@[0-9]* *//' "$list"
done | awk 'NF >= 1 { print $1 }' | sort -u)

SAMPLE=/etc/hostile-sample
printf 'A file for the hostile-argument sweep to read, write and ruin.\n' \
    > "$STAGE$SAMPLE"

{
    echo "# Every program, given arguments nobody would give it on purpose."
    echo "# Written by tools/gen-hostile-tests.sh from what is in /usr/bin."
    echo "# Expected: all passed. Any exit status passes; a fault or a hang does not."
    for f in "$STAGE"/usr/bin/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        # Quark's own programs are staged under their FAT32 names and land on
        # an ext2 root under the ones the shell uses.
        case "$name" in
        *.ELF) name=$(echo "${name%.ELF}" | tr 'A-Z' 'a-z') ;;
        esac
        case "$name" in
        shutdown|login|runtests|wm|qfuzz) continue ;;
        # It asserts that it has a compositor, and this sweep runs programs
        # without one; nothing here patches a client, so it is left out
        # rather than made to say so. Quark's own clients check and exit.
        weston-simple-shm) continue ;;
        esac
        if echo "$SUITE" | grep -qx -- "$name"; then
            continue
        fi
        for args in "" "-" "--" "-x" "--help" "$LONG" /nonexistent /etc \
                    /dev/null "$SAMPLE" 99999999999999999999 -1 0 héllo \
                    "$CTRL" "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15"; do
            echo "? @30 $name $args"
        done
    done
} > "$OUT"
echo "hostile: $(grep -c '^?' "$OUT") lines for $(grep '^?' "$OUT" | cut -d' ' -f3 | sort -u | wc -l) programs"
