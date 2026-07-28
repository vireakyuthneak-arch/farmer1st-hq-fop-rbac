#!/usr/bin/env python3
"""manifest_tree_sha256.py — the PIN-4 tree hash of a rendered manifests/ tree.

MIRROR of the authoritative recipe in fop-appstore
(.github/scripts/publish/gate.py::manifests_tree_sha256): sha256 over the
UTF-8 lines '<relpath>\\0<sha256(file)>\\n' for every regular file under the
tree, sorted by relpath ('/' separators). The appstore RECOMPUTES this hash
over our uploaded `staged` artifact and rejects the publish (E_SOURCE_VERIFY)
on any mismatch — so this file must stay byte-semantics-identical to the
appstore's. Change it only in lockstep with fop-appstore.

Usage: python3 scripts/manifest_tree_sha256.py build/manifests
Prints the 64-hex digest.
"""

import hashlib
import os
import sys


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def manifests_tree_sha256(tree_dir: str) -> str:
    entries = []
    for root, dirs, files in os.walk(tree_dir):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            if os.path.islink(path):
                raise SystemExit(f"REFUSED: symlink in manifests tree: {path}")
            rel = os.path.relpath(path, tree_dir).replace(os.sep, "/")
            entries.append((rel, sha256_file(path)))
    if not entries:
        raise SystemExit("REFUSED: manifests tree is empty")
    h = hashlib.sha256()
    for rel, digest in sorted(entries):
        h.update(rel.encode("utf-8") + b"\0" + digest.encode("ascii") + b"\n")
    return h.hexdigest()


if __name__ == "__main__":
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        raise SystemExit("usage: manifest_tree_sha256.py <manifests-dir>")
    print(manifests_tree_sha256(sys.argv[1]))
