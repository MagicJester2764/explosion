#!/bin/sh
# Teach an autoconf config.sub that quark is an operating system.
#
#     ./teach-config-sub.sh path/to/config.sub
#
# The same one line every autoconf package needs. Idempotent.
#
# The file is generated and reformatted every few years, and the packages in
# this tree ship at least three vintages of it: one alternation per line, four
# or five to a line continued with a backslash, and the same closed with `)`
# at the end of the list. Matching a literal line meant a new package stopped
# the build, so this finds the list by what it is — the alternation that names
# the operating systems — and adds to it in whatever shape it is written.
set -e
F=${1:?usage: teach-config-sub.sh <config.sub>}
grep -q 'quark\*' "$F" && exit 0
python3 - "$F" <<'PY'
import re
import sys

p = sys.argv[1]
lines = open(p).read().split("\n")

# The OS list is an alternation, so its lines begin with `|`. `zephyr*` is in
# every vintage of it and appears elsewhere only without that `|`, which is how
# the list is told from the case that guesses a machine.
hits = [i for i, l in enumerate(lines) if re.match(r"^\s*\|.*\bzephyr\*", l)]
if len(hits) != 1:
    sys.exit(p + ": the OS list is not where this expects it")

i = hits[0]
line = lines[i]
indent = re.match(r"^(\s*)", line).group(1)
if line.rstrip().endswith("\\"):
    # The list goes on: another line of it will do.
    lines.insert(i + 1, indent + "| quark* \\")
elif line.rstrip().endswith(")"):
    # The list ends here: continue it and close it one line further down.
    lines[i] = line.rstrip()[:-1].rstrip() + " \\"
    lines.insert(i + 1, indent + "| quark*)")
else:
    sys.exit(p + ": the OS list ends in a way this does not understand")

open(p, "w").write("\n".join(lines))
PY
echo "==> $F knows quark"
