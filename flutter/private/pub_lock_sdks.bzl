"""Reads the `sdks:` block a resolver writes at the end of `pubspec.lock`.

Pub records the *constraints* its solution requires, not the SDK that produced
it — so a lock cannot tell you which Flutter resolved it. What it can tell you
is the floor: `flutter: ">=3.18.0-18.0.pre.54"` means no SDK below that can
honour the pinned versions. Checking the pinned toolchain against that floor
catches the direction that ends in a confusing compile error — a lock resolved
by a *newer* Flutter than the build uses.

The other direction (an older resolver silently capping packages at older
versions) leaves no trace in the lock at all: the result is a perfectly valid
solution under the newer SDK. Nothing can detect it after the fact, which is
why `@rules_flutter//flutter:pub` exists — resolving with the pinned toolchain
is the only thing that prevents it.
"""

def parse_lock_sdk_constraints(lock_content):
    """Extracts the `sdks:` block from a pubspec.lock.

    Args:
        lock_content: The full text of a `pubspec.lock`.

    Returns:
        A dict of SDK name to constraint string, e.g.
        `{"dart": ">=3.9.0 <4.0.0", "flutter": ">=3.18.0"}`. Empty when the
        lock records no `sdks:` block.
    """
    constraints = {}
    in_block = False
    for line in lock_content.split("\n"):
        if line.startswith("sdks:"):
            in_block = True
            continue
        if not in_block:
            continue

        # The block runs to the end of the file; any unindented line ends it.
        if not line.startswith("  "):
            if line.strip():
                break
            continue

        parts = line.strip().split(":", 1)
        if len(parts) != 2:
            continue
        constraints[parts[0].strip()] = parts[1].strip().strip('"')
    return constraints

def constraint_lower_bound(constraint):
    """The `>=` floor of a pub version constraint, as a list of ints.

    Only the numeric release components are returned; a prerelease suffix
    (`3.18.0-18.0.pre.54`) is dropped, which keeps the comparison sound: a
    release version is always >= any prerelease of the same triple.

    Args:
        constraint: A pub constraint string such as `">=3.18.0 <4.0.0"`.

    Returns:
        A list of ints, or None when the constraint states no `>=` floor or
        states one this function cannot read.
    """
    for term in constraint.split(" "):
        if not term.startswith(">="):
            continue
        release = term[2:].split("-")[0].split("+")[0]
        components = []
        for part in release.split("."):
            if not part.isdigit():
                return None
            components.append(int(part))
        return components if components else None
    return None

def version_below_lower_bound(version, constraint):
    """Whether `version` is definitely below a constraint's `>=` floor.

    Answers only when it can answer soundly: an unreadable constraint, or one
    with no `>=` term, yields False rather than a guess.

    Args:
        version: A version string such as `"3.44.1"`.
        constraint: A pub constraint string such as `">=3.18.0 <4.0.0"`.

    Returns:
        True only when `version` provably fails the constraint's floor.
    """
    bound = constraint_lower_bound(constraint)
    if bound == None:
        return False

    actual = []
    for part in version.split("-")[0].split("."):
        if not part.isdigit():
            return False
        actual.append(int(part))

    # Compare component-wise, padding the shorter with zeros.
    for i in range(max(len(actual), len(bound))):
        a = actual[i] if i < len(actual) else 0
        b = bound[i] if i < len(bound) else 0
        if a != b:
            return a < b
    return False

def hosted_package_sha256(name, info, lock):
    """Returns the recorded sha256 of a hosted package in `pubspec.lock`.

    Fails when the package entry has no non-empty `description.sha256`, naming
    the package, its version, and the lock file.

    Args:
        name: Hosted pub package name.
        info: Parsed lock entry dict for the package.
        lock: Label or string naming the `pubspec.lock` file.

    Returns:
        The recorded sha256 string.
    """
    desc = info["description"] if "description" in info else None
    version = info["version"] if "version" in info else ""
    if type(desc) != "dict" or "sha256" not in desc or not desc["sha256"]:
        # Same wording as rules_dart's pub.from_lock(), with
        # flutter.pub's command.
        fail((
            "pub package \"{name}\" {version} in {lock} has no sha256. " +
            "Run `bazel run @rules_flutter//flutter:pub -- get` " +
            "(Dart 2.19 or newer records one) and commit the lock."
        ).format(
            lock = str(lock),
            name = name,
            version = version,
        ))
    return desc["sha256"]
