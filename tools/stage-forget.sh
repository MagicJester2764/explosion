#!/bin/sh
# Take back out of the stage what an earlier stage recorded putting there.
#
#     tools/stage-forget.sh <stage-dir> <record>...
#
# The clients and the test suites are somebody else's builds, staged when a
# variable names them. Each file is written down as it is staged, in a
# record at the top of the stage, and this removes them before the next
# stage begins: so an image built without the variable has nothing of the
# variable's in it, instead of whatever the last build left. Run before the
# kernel and the userland install, so that a file one of them owns and a
# suite had replaced is put back.
set -e
STAGE=${1:?usage: stage-forget.sh <stage-dir> <record>...}
shift
# One path per line, whatever is in it.
set -f
IFS='
'
for record in "$@"; do
    LIST=$STAGE/$record
    [ -f "$LIST" ] || continue
    while read -r path; do
        if [ -n "$path" ]; then
            rm -f "$STAGE/$path"
        fi
    done < "$LIST"
    rm -f "$LIST"
done
for top in usr etc var; do
    if [ -d "$STAGE/$top" ]; then
        find "$STAGE/$top" -mindepth 1 -depth -type d -empty -delete
    fi
done
