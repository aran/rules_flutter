"""Reconciling a package that several `flutter_pub.from_lock()` locks list.

There is one repository per package for the whole build, so when more than one
lock lists a package they must agree on what it is. `reconcile_package` decides,
from the entries every lock has for the package, which one the build uses, or
why none can be. Whether the hosted, git and `path` entries agree is rules_dart's
`pub_lock_disagreement_errors`, as `pub.from_lock` applies it, and a hosted
package's version is chosen by rules_dart's policy (`select_pub_version`):
every lock's entry is a minimum and the highest wins.

Every function here is pure and returns messages instead of calling `fail`: a
unit test cannot catch `fail`. The extension joins the messages and fails.

An entry is a `struct` the extension makes of one lock entry:

* `kind`: its `lock_entry_kind`;
* `lock_entry`, for a hosted, git or `build_from_pubspec` package: the entry
  rules_dart's `pub_lock_entry` read;
* `version`, `sha256`, `url` (the registry's), for a hosted package;
* `reason`, for an ignored `path` package;
* `hub`, `lock_label`: the tag it came from;
* `module`, `is_root`: the module whose tag it is, and whether that is the root.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "pub_lock_disagreement_errors")
load("@rules_dart//dart/pub:pub_versions.bzl", "pub_version_request", "select_pub_version")
load("//flutter/private:lock_entry_kind.bzl", "GIT", "HOSTED", "LOCAL", "UNSUPPORTED")

visibility("//flutter/...")

# What runs pub with the pinned toolchain, for the commands messages give. It
# runs while the locks are refused: it needs the toolchain, which the `flutter`
# extension makes, and no repository of the `pub` extension, nor of rules_dart's.
PUB_RUNNER = "@rules_flutter//flutter/pub"

def _where(entry):
    return "hub \"{}\", {}".format(entry.hub, entry.lock_label)

# The kinds whose entries rules_dart compares (`pub_lock_disagreement_errors`).
_LOCKED_KINDS = [HOSTED, GIT, LOCAL]

def _kinds_error(name, entries):
    """A package one lock takes from a source rules_dart does not compare (ignored, the Flutter SDK, ...) and another from another."""
    return (
        "Package \"{name}\" comes from different sources across flutter_pub.from_lock() locks:\n" +
        "{lines}\n" +
        "rules_flutter builds one copy of each package. Make the locks agree, or map " +
        "it to one target with `resolve`."
    ).format(
        name = name,
        lines = "\n".join(["  - {} ({})".format(e.kind, _where(e)) for e in entries]),
    )

def _where_version(entry):
    # The label within its module, which the message names when it is not the root.
    where = "the lock `//{}`".format(entry.lock_label.split("//", 1)[1])
    if not entry.is_root:
        where += " in module `{}`".format(entry.module)
    return where

def _hosted_selection(name, entries, check):
    """Picks a hosted package's entry with rules_dart's one version policy.

    Every lock's entry is a request and the highest wins, as rules_dart's
    `pub.from_lock` does. A lock of the root module whose request is raised is
    reported at the root's `check`. Two entries of one version must pin one
    digest, and every entry one registry.

    Args:
        name: The package's name.
        entries: Its hosted entries.
        check: The root's `check_direct_dependencies`.

    Returns:
        `struct(entry, errors, warnings)`.
    """
    requests = [
        pub_version_request(
            version = e.version,
            sha256 = e.sha256,
            url = e.url,
            is_root = e.is_root,
            where = _where_version(e),
            upgrade = e.lock_entry.upgrade,
            refresh = e.lock_entry.refresh,
        )
        for e in entries
    ]
    selection = select_pub_version(name, requests, check, settings = "flutter_pub.settings")
    if selection.error:
        return struct(entry = None, errors = [selection.error], warnings = [])

    # The first entry at the winning version, as the selection picks the first
    # request at it.
    winner = [e for e in entries if e.version == selection.request.version][0]
    return struct(entry = winner, errors = [], warnings = [selection.warning] if selection.warning else [])

def reconcile_package(name, entries, check = "warning"):
    """Decides which of a package's lock entries the build uses.

    Args:
        name: The package's name.
        entries: Its entries, one per lock that lists it (see the file doc).
        check: The root's `check_direct_dependencies`, for a hosted package
            whose root lock is raised.

    Returns:
        `struct(entry, errors, warnings)`: `entry`, the one the build uses
        (None when `errors` is set); `errors`, the messages, empty when the
        locks agree; `warnings`, the messages to print when they do.
    """
    kinds = {e.kind: True for e in entries}
    if len(kinds) > 1 and [k for k in kinds if k not in _LOCKED_KINDS]:
        return struct(entry = None, errors = [_kinds_error(name, entries)], warnings = [])
    errors = pub_lock_disagreement_errors(name, [e.lock_entry for e in entries if e.kind in _LOCKED_KINDS])
    if errors:
        return struct(entry = None, errors = errors, warnings = [])
    if entries[0].kind == HOSTED:
        return _hosted_selection(name, entries, check)
    return struct(entry = entries[0], errors = [], warnings = [])

def unsupported_locks(entries):
    """The locks that list an unsupported package, for its one stub's message.

    Args:
        entries: The package's entries, of kind `UNSUPPORTED`.

    Returns:
        The lock labels, joined.
    """
    return ", ".join(sorted({e.lock_label: True for e in entries if e.kind == UNSUPPORTED}.keys()))
