"""Body-only edit to a leaf file: bumps the constant in `var total = N;`.

Usage: bump.py <file.dart>. Changes one function body and no signature, so the
public API stays the same. suite.py applies it to packages/pkg0/lib/src/f0.dart.
"""
import re, sys


def bump(path):
    s = open(path).read()
    s2, n = re.subn(r"var total = (\d+);", lambda m: f"var total = {int(m[1]) + 1};", s, count=1)
    assert n == 1 and s2 != s, f"no `var total = N;` in {path}"
    open(path, "w").write(s2)


if __name__ == "__main__":
    bump(sys.argv[1])
