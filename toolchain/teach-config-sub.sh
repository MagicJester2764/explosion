#!/bin/sh
# Teach an autoconf config.sub that quark is an operating system.
#
#     ./teach-config-sub.sh path/to/config.sub
#
# The same one line every autoconf package needs. Idempotent.
set -e
F=${1:?usage: teach-config-sub.sh <config.sub>}
grep -q '| quark\*' "$F" && exit 0
python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
a = "\t     | nsk* | powerunix* | genode* | zvmoe* | qnx* | emx* | zephyr* \\\n"
if s.count(a) != 1:
    sys.exit(p + ": the OS list is not where this expects it")
open(p, "w").write(s.replace(a, a + "\t     | quark* \\\n"))
PY
echo "==> $F knows quark"
