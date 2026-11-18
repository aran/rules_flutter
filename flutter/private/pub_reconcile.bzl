"""Reconciling a package that several `flutter_pub.from_lock()` locks list.

There is one repository per package for the whole build, so when more than one
lock lists a package they must agree on what it is. `reconcile_package` decides,
from the entries every lock has for the package, which one the build uses, or
why none can be. A hosted package's version is chosen by rules_dart's policy
(`select_pub_version`): every lock's entry is a minimum and the highest wins.

Every function here is pure and returns messages instead of calling `fail`: a
unit test cannot catch `fail`. The extension joins the messages and fails.

An entry is a `struct` the extension makes of one lock entry:

* `kind`: its `lock_entry_kind`;
* `version`, `sha256`, `url` (the registry's), for a hosted package;
* `git_url`, `resolved_ref`, `git_path`, `git_lock` (the lock's label when the
  url is relative to it, else `""`), for a git package;
* `directory` (absolute), for a `path` package built from its pubspec;
* `reason`, for an ignored `path` package;
* `hub`, `lock_label`: the tag it came from;
* `module`, `is_root`: the module whose tag it is, and whether that is the root;
* `lock_dir`: the lock's directory within its repository (`lock_directory`).
"""

load("@rules_dart//dart/pub:pub_versions.bzl", "pub_version_request", "select_pub_version")
load("//flutter/private:lock_entry_kind.bzl", "GIT", "HOSTED", "IGNORED", "LOCAL", "UNSUPPORTED")

visibility("//flutter/...")

def pub_command(verb, lock_dir, packages = []):
    """The command that re-resolves the lock in `lock_dir` with the pinned toolchain.

    It is run from the root of the workspace that holds the lock, and it runs
    while the locks disagree or are refused: the runner needs the toolchain,
    which the `flutter` extension makes, and no repository of the `pub`
    extension, nor of rules_dart's.

    Args:
        verb: The pub command: `get` or `upgrade`.
        lock_dir: The lock's directory relative to the workspace root; empty
            for the root.
        packages: The packages to move forward; empty for all of them.

    Returns:
        The command line.
    """
    args = [verb]
    if lock_dir:
        args.append("--directory=" + lock_dir)
    return " ".join(["bazel run @rules_flutter//flutter/pub --"] + args + packages)

def _where(entry):
    return "hub \"{}\", {}".format(entry.hub, entry.lock_label)

def _describe(entry):
    if entry.kind == HOSTED:
        return "hosted {} ({})".format(entry.version, _where(entry))
    if entry.kind == GIT:
        return "git {} at {} ({})".format(entry.git_url, entry.resolved_ref, _where(entry))
    if entry.kind == LOCAL:
        return "built from its pubspec at {} ({})".format(entry.directory, _where(entry))
    if entry.kind == IGNORED:
        return "ignored ({})".format(_where(entry))
    return "{} ({})".format(entry.kind, _where(entry))

def _kinds_error(name, entries):
    return (
        "Package \"{name}\" comes from different sources across flutter_pub.from_lock() locks:\n" +
        "{lines}\n" +
        "rules_flutter builds one copy of each package. Make the locks agree, or map " +
        "it to one target with `resolve`."
    ).format(
        name = name,
        lines = "\n".join(["  - " + _describe(e) for e in entries]),
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
            upgrade = pub_command("upgrade", e.lock_dir, [name]),
            refresh = pub_command("get", e.lock_dir),
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

def _git_key(entry):
    return (entry.git_url, entry.git_lock, entry.resolved_ref, entry.git_path)

def _git_errors(name, entries):
    keys = {_git_key(e): True for e in entries}
    if len(keys) > 1:
        return [(
            "Package \"{name}\" is pinned to different git sources across flutter_pub.from_lock() locks:\n" +
            "{lines}\n" +
            "rules_flutter builds one copy of each package. Make the locks agree."
        ).format(
            name = name,
            lines = "\n".join(["  - {} ({})".format(_describe(e), _where(e)) for e in entries]),
        )]
    return []

def _local_errors(name, entries):
    if len({e.directory: True for e in entries}) > 1:
        return [(
            "Package \"{name}\" is built from its pubspec in different directories across flutter_pub.from_lock() locks:\n" +
            "{lines}\n" +
            "rules_flutter builds one copy of each package. Make the locks agree, or map " +
            "it to one target with `resolve`."
        ).format(
            name = name,
            lines = "\n".join(["  - " + _describe(e) for e in entries]),
        )]
    return []

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
    if len(kinds) > 1:
        return struct(entry = None, errors = [_kinds_error(name, entries)], warnings = [])
    kind = entries[0].kind
    errors = []
    if kind == HOSTED:
        return _hosted_selection(name, entries, check)
    elif kind == GIT:
        errors = _git_errors(name, entries)
    elif kind == LOCAL:
        errors = _local_errors(name, entries)
    if errors:
        return struct(entry = None, errors = errors, warnings = [])
    return struct(entry = entries[0], errors = [], warnings = [])

def unsupported_locks(entries):
    """The locks that list an unsupported package, for its one stub's message.

    Args:
        entries: The package's entries, of kind `UNSUPPORTED`.

    Returns:
        The lock labels, joined.
    """
    return ", ".join(sorted({e.lock_label: True for e in entries if e.kind == UNSUPPORTED}.keys()))
