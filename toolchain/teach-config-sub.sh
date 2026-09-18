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

# The same line in two vintages: a newer config.sub continues the list after
# `zephyr*` and an older one closes it there. Both are in the wild — libpng
# ships one and pcre2 the other — so both are answered.
p = sys.argv[1]
s = open(p).read()
cont = "\t     | nsk* | powerunix* | genode* | zvmoe* | qnx* | emx* | zephyr* \\\n"
last = "\t     | nsk* | powerunix* | genode* | zvmoe* | qnx* | emx* | zephyr*)\n"
if s.count(cont) == 1:
    s = s.replace(cont, cont + "\t     | quark* \\\n")
elif s.count(last) == 1:
    s = s.replace(last, last.replace("zephyr*)", "zephyr* \\") + "\t     | quark*)\n")
else:
    sys.exit(p + ": the OS list is not where this expects it")
open(p, "w").write(s)
PY
echo "==> $F knows quark"
