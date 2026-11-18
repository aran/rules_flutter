"""Which Flutter version a `flutter.toolchain` name resolves to."""

visibility("//flutter/...")

def parse_flutter_version(v):
    """Splits a version string into a list of ints for comparison.

    Args:
        v: A dotted version such as `3.47.9`.

    Returns:
        The components as ints.
    """
    result = []
    for x in v.split("."):
        if not x.isdigit():
            fail((
                "Invalid Flutter version '{}': expected numeric components " +
                "separated by dots (e.g. '3.47.2'), but got non-numeric component '{}'."
            ).format(v, x))
        result.append(int(x))
    return result

def select_flutter_version(name, root_version, requests, allow_upgrade_by_dependencies = False):
    """The version a toolchain name gets, or why the module graph cannot have one.

    The root module's version is used exactly, as rules_go uses the root's Go
    SDK: the root chooses every toolchain. A dependency may not be given an
    SDK older than it asks for, so one asking for a newer version than the
    root's fails the build, naming it and both fixes, unless the root sets
    `allow_upgrade_by_dependencies`, which makes the highest version win. A
    name the root does not pin takes the highest version any module asks for.

    Args:
        name: The toolchain name, for the error.
        root_version: The root module's version for the name, or None.
        requests: `(module name, version)` for every module's request for the
            name, the root's included.
        allow_upgrade_by_dependencies: The root's opt-in to the highest version
            any module asks for, instead of its own pin.

    Returns:
        `struct(version, error)`: the selected version and None, or None and
        the message to fail with.
    """
    if root_version != None and not allow_upgrade_by_dependencies:
        newer = [
            (module, v)
            for module, v in requests
            if parse_flutter_version(v) > parse_flutter_version(root_version)
        ]
        if newer:
            return struct(version = None, error = (
                "The root module pins flutter.toolchain(name = \"{name}\") to Flutter {root}, " +
                "older than {modules} asks for. A module is never given an older SDK than it " +
                "asks for: raise the root's flutter_version to {highest} or newer, or set " +
                "allow_upgrade_by_dependencies = True on it to use the highest version asked for."
            ).format(
                name = name,
                root = root_version,
                modules = ", ".join(["{} ({})".format(m, v) for m, v in newer]),
                highest = _highest([v for _, v in newer]),
            ))
        return struct(version = root_version, error = None)
    return struct(version = _highest([v for _, v in requests]), error = None)

def _highest(versions):
    selected = versions[0]
    for v in versions[1:]:
        if parse_flutter_version(v) > parse_flutter_version(selected):
            selected = v
    return selected
