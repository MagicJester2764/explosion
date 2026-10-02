#!/usr/bin/env python3
"""Write the package lists for a staged root.

    tools/stage-packages.py <stage-dir> <packages.conf> <version>

Every file the image will have is given to a package, by `packages.conf`,
and each package's list is written to <stage-dir>/var/lib/qpkg/NAME: what
it is, its set, and every file it owns with its length and a checksum —
and, for every program, what the program's manifest asks to be allowed. A
file `packages.conf` says is the owner's to change (`yours`) is marked so.
`qpkg`, on the system, reads those lists; `qpkg strap` copies a package by
one, and the list with it.

Paths are the image's, not the stage's: Quark's own programs are staged
under the names FAT wants (QSH.ELF, PASSWD) and land on an ext root as the
ones a shell uses (qsh, passwd). tools/populate-ext.sh does that renaming
when it fills an image, and this follows the same rule.

Run last: the lists describe everything the stage has.
"""

import fnmatch
import os
import shutil
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from readmanifest import describe, find_all  # noqa: E402

# What an image is filled from; populate-ext.sh's list.
TOPS = ("bin", "usr", "etc", "var")
DB = "var/lib/qpkg"


def image_path(staged):
    """The path a staged file has in an image."""
    d, base = os.path.split(staged)
    if d in ("usr/bin", "etc") and not any(c.islower() for c in base):
        base = base.lower()
        if base.endswith(".elf"):
            base = base[:-4]
    return os.path.join(d, base)


def read_conf(path):
    packages = []
    for raw in open(path):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, _, rest = line.partition(" ")
        if key == "package":
            packages.append(
                {"name": rest, "set": "", "about": "", "files": [], "lists": [], "dirs": [], "yours": []}
            )
        elif not packages:
            sys.exit(f"{path}: `{key}` before any package")
        elif key in ("set", "about"):
            packages[-1][key] = rest
        elif key in ("files", "lists", "yours"):
            packages[-1][key] += rest.split()
        elif key == "dir":
            mode, _, where = rest.partition(" ")
            packages[-1]["dirs"].append((mode, where))
        else:
            sys.exit(f"{path}: nothing is called `{key}`")
    for p in packages:
        if not p["set"] or not p["about"]:
            sys.exit(f"{path}: {p['name']} has no set, or nothing said about it")
    return packages


def listed_programs(stage, patterns):
    """The programs the test lists matching `patterns` name."""
    names = set()
    for top in TOPS:
        for root, _, files in os.walk(os.path.join(stage, top)):
            for f in files:
                rel = os.path.relpath(os.path.join(root, f), stage)
                if not any(fnmatch.fnmatchcase(image_path(rel), p) for p in patterns):
                    continue
                # Three lists name the system's own programs and not a
                # suite's: every program there is, with arguments nobody
                # would give it; runtests trying itself on `echo` and `ls`;
                # and the fuzzers. They claim nothing — a list that did took
                # `ls` out of every installed system.
                if f in ("hostile.tests", "selftest.tests", "fuzz.tests"):
                    continue
                for line in open(os.path.join(root, f), errors="replace"):
                    words = [w for w in line.split() if w != "?" and not w.startswith("@")]
                    if words and not line.startswith("#"):
                        names.add(words[0])
    return names


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__.strip())
    stage, conf, version = sys.argv[1:]
    packages = read_conf(conf)
    shutil.rmtree(os.path.join(stage, DB), ignore_errors=True)

    for p in packages:
        p["programs"] = listed_programs(stage, p["lists"]) if p["lists"] else set()
        p["lines"] = []

    staged = []
    for top in TOPS:
        for root, dirs, files in os.walk(os.path.join(stage, top)):
            dirs.sort()
            for f in sorted(files):
                staged.append(os.path.relpath(os.path.join(root, f), stage))
    for rel in sorted(staged, key=image_path):
        path = image_path(rel)
        owner = None
        for p in packages:
            if any(fnmatch.fnmatchcase(path, pat) for pat in p["files"]) or (
                path.startswith("usr/bin/") and os.path.basename(path) in p["programs"]
            ):
                owner = p
                break
        if owner is None:
            sys.exit(f"{path}: no package claims it; packages.conf wants one that takes what is left")
        full = os.path.join(stage, rel)
        if os.path.islink(full):
            owner["lines"].append(f"l /{path}")
            continue
        data = open(full, "rb").read()
        # A file that is the system's owner's to change is marked: it is
        # installed as built, and afterwards only looked for.
        kind = "y" if any(fnmatch.fnmatchcase(path, pat) for pat in owner["yours"]) else "f"
        owner["lines"].append(f"{kind} {zlib.crc32(data) & 0xFFFFFFFF:08x} {len(data)} /{path}")
        # What a program asks to be allowed, as the spawner will read it.
        if data[:4] == b"\x7fELF":
            asks = [describe(*r) for r in find_all(data) if r[0] != 0]
            if asks:
                owner["lines"].append(f"c /{path} {', '.join(asks)}")
        # The services a system starts before it has a root are programs
        # too, and the ones trusted with the most. They are inside boot.img,
        # which was made from the stage's boot directory.
        if os.path.basename(path) == "boot.img":
            boot = os.path.join(stage, "boot")
            for name in sorted(os.listdir(boot)):
                image = open(os.path.join(boot, name), "rb").read()
                asks = [describe(*r) for r in find_all(image) if r[0] != 0]
                if asks:
                    service = name.lower().removesuffix(".elf")
                    owner["lines"].append(f"c /{path}:{service} {', '.join(asks)}")

    os.makedirs(os.path.join(stage, DB))
    total = 0
    for p in packages:
        if not p["lines"] and not p["dirs"]:
            continue
        with open(os.path.join(stage, DB, p["name"]), "w") as out:
            out.write(f"name {p['name']}\nversion {version}\nset {p['set']}\nabout {p['about']}\n")
            for mode, where in p["dirs"]:
                out.write(f"d {mode} /{where}\n")
            out.write("\n".join(p["lines"]) + ("\n" if p["lines"] else ""))
        total += sum(1 for l in p["lines"] if l[0] in "fly")
    print(f"packages: {sum(1 for p in packages if p['lines'] or p['dirs'])} lists for {total} files")


if __name__ == "__main__":
    main()
