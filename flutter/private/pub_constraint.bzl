"""Answers "does this pub version constraint allow this version?".

Follows Dart's `package:pub_semver` (`VersionConstraint.parse`,
`VersionRange.allows`, `Version.compareTo`), which is what pub itself uses, so
a repository rule reaches the verdict pub would.

Differences from npm's semver that matter here:

- A pre-release is allowed by any range that its numbers fall inside, whether
  or not the constraint mentions a pre-release.
- An exclusive upper bound that is a plain release (`<2.0.0`, or the end of
  `^1.2.3`) is treated as that release's first pre-release, so `2.0.0-dev` is
  outside both.
- `^` is "at least this version, below its next breaking version"; for `0.x.y`
  the breaking version is the next minor, for `0.0.z` too.
"""

visibility("//flutter/...")

_DIGITS = "0123456789"
_IDENT_CHARS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-"

def _is_digits(text):
    if not text:
        return False
    for c in text.elems():
        if c not in _DIGITS:
            return False
    return True

def _identifier(text):
    # Numeric identifiers compare as numbers and sort below alphanumeric ones.
    if _is_digits(text):
        return int(text, 10)
    return text

def _scan_digits(text, pos):
    end = pos
    for _ in range(len(text) - pos):
        if text[end] not in _DIGITS:
            break
        end += 1
    return end

def _scan_identifiers(text, pos):
    """Returns the end of a `ident(.ident)*` run starting at `pos`, or `pos`."""
    end = pos
    for _ in range(len(text) - pos + 1):
        start = end
        for _ in range(len(text) - start):
            if text[end] not in _IDENT_CHARS:
                break
            end += 1
        if end == start:
            return pos
        if end + 1 < len(text) and text[end] == "." and text[end + 1] in _IDENT_CHARS:
            end += 1
            continue
        return end
    return end

def _scan_version(text):
    """Reads a version from the start of `text`; returns (version, rest) or None."""
    pos = 0
    numbers = []
    for i in range(3):
        end = _scan_digits(text, pos)
        if end == pos:
            return None
        numbers.append(int(text[pos:end], 10))
        pos = end
        if i < 2:
            if pos >= len(text) or text[pos] != ".":
                return None
            pos += 1

    pre = []
    if pos < len(text) and text[pos] == "-":
        end = _scan_identifiers(text, pos + 1)
        if end > pos + 1:
            pre = [_identifier(p) for p in text[pos + 1:end].split(".")]
            pos = end

    build = []
    if pos < len(text) and text[pos] == "+":
        end = _scan_identifiers(text, pos + 1)
        if end > pos + 1:
            build = [_identifier(p) for p in text[pos + 1:end].split(".")]
            pos = end

    version = struct(
        major = numbers[0],
        minor = numbers[1],
        patch = numbers[2],
        pre = pre,
        build = build,
    )
    return version, text[pos:]

def parse_version(text):
    """Parses `major.minor.patch[-pre][+build]`.

    Args:
        text: the version string.

    Returns:
        A struct (major, minor, patch, pre, build) or None if `text` is not a
        version. `pre` and `build` are lists of ints and strings.
    """
    if type(text) != "string":
        return None
    scanned = _scan_version(text)
    if scanned == None or scanned[1]:
        return None
    return scanned[0]

def _compare_identifiers(a, b):
    for i in range(max(len(a), len(b))):
        if i >= len(a):
            return -1
        if i >= len(b):
            return 1
        x = a[i]
        y = b[i]
        if x == y:
            continue
        x_num = type(x) == "int"
        y_num = type(y) == "int"
        if x_num != y_num:
            return -1 if x_num else 1
        return -1 if x < y else 1
    return 0

def compare_versions(a, b):
    """Orders two parsed versions the way pub does.

    Args:
        a: a version from `parse_version`.
        b: a version from `parse_version`.

    Returns:
        -1, 0 or 1. A pre-release sorts below its release; build metadata
        sorts above the same version without it and otherwise compares like a
        pre-release.
    """
    for x, y in [(a.major, b.major), (a.minor, b.minor), (a.patch, b.patch)]:
        if x != y:
            return -1 if x < y else 1
    if bool(a.pre) != bool(b.pre):
        return -1 if a.pre else 1
    c = _compare_identifiers(a.pre, b.pre)
    if c != 0:
        return c
    if bool(a.build) != bool(b.build):
        return 1 if a.build else -1
    return _compare_identifiers(a.build, b.build)

def _version(major, minor, patch, pre = []):
    return struct(major = major, minor = minor, patch = patch, pre = pre, build = [])

def _first_pre_release(v):
    return _version(v.major, v.minor, v.patch, [0])

def _next_breaking(v):
    if v.major == 0:
        return _version(0, v.minor + 1, 0)
    return _version(v.major + 1, 0, 0)

def _same_release(a, b):
    return a.major == b.major and a.minor == b.minor and a.patch == b.patch

def _range(min, include_min, max, include_max):
    return struct(any = min == None and max == None, empty = False, min = min, include_min = include_min, max = max, include_max = include_max)

_EMPTY = struct(any = False, empty = True, min = None, include_min = False, max = None, include_max = False)

def _parse_constraint(text):
    """Returns (constraint, None) or (None, problem)."""
    if type(text) != "string":
        return None, "version constraint {} is not a string".format(repr(text))
    original = text
    text = text.strip()
    if text == "" or text == "any":
        return _range(None, False, None, False), None

    if text.startswith("^"):
        scanned = _scan_version(text[1:].lstrip())
        if scanned == None:
            return None, 'Expected version number after "^" in "{}"'.format(original)
        if scanned[1]:
            return None, 'Cannot include other constraints with "^" constraint in "{}"'.format(original)
        v = scanned[0]
        return _range(v, True, _first_pre_release(_next_breaking(v)), False), None

    lo = None
    include_min = False
    hi = None
    include_max = False
    for _ in range(len(text) + 1):
        text = text.lstrip()
        if not text:
            break

        # A bare version is the range [v, v].
        term_min = None
        term_max = None
        term_include_min = False
        term_include_max = False
        scanned = _scan_version(text)
        if scanned != None:
            term_min = scanned[0]
            term_max = scanned[0]
            term_include_min = True
            term_include_max = True
        else:
            op = ""
            for candidate in ["<=", ">=", "<", ">"]:
                if text.startswith(candidate):
                    op = candidate
                    break
            if not op:
                return None, 'Could not parse version "{}". Unknown text at "{}".'.format(original, text)
            scanned = _scan_version(text[len(op):].lstrip())
            if scanned == None:
                return None, 'Expected version number after "{}" in "{}", got "{}".'.format(op, original, text[len(op):].lstrip())
            if op == "<=":
                term_max = scanned[0]
                term_include_max = True
            elif op == "<":
                term_max = scanned[0]
            elif op == ">=":
                term_min = scanned[0]
                term_include_min = True
            else:
                term_min = scanned[0]
        text = scanned[1]

        if term_min != None:
            c = 1 if lo == None else compare_versions(term_min, lo)
            if c > 0:
                lo = term_min
                include_min = term_include_min
            elif c == 0 and not term_include_min:
                include_min = False
        if term_max != None:
            c = -1 if hi == None else compare_versions(term_max, hi)
            if c < 0:
                hi = term_max
                include_max = term_include_max
            elif c == 0 and not term_include_max:
                include_max = False

    if lo != None and hi != None:
        c = compare_versions(lo, hi)
        if c > 0:
            return _EMPTY, None
        if c == 0:
            if include_min and include_max:
                return _range(lo, True, hi, True), None
            return _EMPTY, None

    # An exclusive plain-release maximum stands for that release's first
    # pre-release, unless the minimum is a pre-release of the same release.
    if hi != None and not include_max and not hi.pre and not hi.build and (lo == None or not lo.pre or not _same_release(lo, hi)):
        hi = _first_pre_release(hi)
    return _range(lo, include_min, hi, include_max), None

def constraint_problem(constraint):
    """Says why a constraint cannot be parsed.

    Args:
        constraint: a pub version constraint string.

    Returns:
        A message quoting the offending text, or None if it parses.
    """
    return _parse_constraint(constraint)[1]

def version_problem(version):
    """Says why a version cannot be parsed.

    Args:
        version: a version string.

    Returns:
        A message quoting the offending text, or None if it parses.
    """
    if parse_version(version) == None:
        return 'Could not parse version "{}".'.format(version)
    return None

def allows(constraint, version):
    """Tells whether a pub version constraint allows a version.

    Args:
        constraint: a constraint such as `any`, `1.2.3`, `^1.2.3` or
            `>=1.0.0 <2.0.0`; the empty string allows everything.
        version: a version string such as `1.2.3-beta.1+7`.

    Returns:
        True if pub would accept `version` under `constraint`. Fails on text
        that is not a constraint or a version.
    """
    parsed, problem = _parse_constraint(constraint)
    if problem:
        fail(problem)
    v = parse_version(version)
    if v == None:
        fail(version_problem(version))
    if parsed.empty:
        return False
    if parsed.min != None:
        c = compare_versions(v, parsed.min)
        if c < 0 or (c == 0 and not parsed.include_min):
            return False
    if parsed.max != None:
        c = compare_versions(v, parsed.max)
        if c > 0 or (c == 0 and not parsed.include_max):
            return False
    return True
