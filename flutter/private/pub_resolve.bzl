"""Saying how each `path` package of a lock is built, or that it is not.

`flutter_pub.from_lock(resolve = {name: label})` names, for a package of the
lock, the target that builds it. Every `path` entry of the lock must be named in
exactly one of three attributes: `resolve`, the target that builds it;
`build_from_pubspec`, to build its directory from its pubspec as a hosted
package is built; or `ignored`, with the reason no Bazel build may contain it.
A hosted, git or sdk entry may be mapped too, to replace the locked
package for the whole graph with a fork or a patched copy: the hub's label for
the package is the target, so a hosted package that depends on it gets it, and
the locked package is not fetched.

Where a `path` entry points is pub's concern only: the map already says where
Bazel gets the package, which may be another module (a sibling checkout pub
reads by path and Bazel takes from a `bazel_dep`). What holds the mapping to the
lock is that the target declares the package's name, checked at analysis
(`resolved_package.bzl`).

The checks here are pure and run when the extension reads the lock, so a wrong
map fails every Bazel command that loads the module, naming the lock, the
package and the fix. Every function returns messages and never calls `fail`:
a unit test cannot catch `fail`.
"""

visibility("//flutter/...")

def lock_directory(lock):
    """The directory of a lock, from the root of its repository.

    The lock's Bazel package, and below it whatever directory the label's
    name reaches (`//app:lock/pubspec.lock` is in `app/lock`).

    Args:
        lock: The lock's `Label`.

    Returns:
        The directory, `/`-separated; empty for the repository root.
    """
    parts = [p for p in [lock.package, lock.name.rpartition("/")[0]] if p]
    return "/".join(parts)

def path_package_dir(lock_package, path):
    """Resolves a `path` lock entry's path to the Bazel package it names.

    The path is relative to the directory of the lock, whatever the depth of the
    package that declared the dependency. Both `/` and `\\` separate segments.

    Args:
        lock_package: The directory of the lock (`lock_directory`); empty
            for the repository root.
        path: The `path` of the entry's `description`.

    Returns:
        `struct(dir, error)`: `dir`, the Bazel package (empty for the
        repository root), or None when `error` is set: the path leaves the
        repository.
    """
    segments = []
    for segment in (lock_package + "/" + path.replace("\\", "/")).split("/"):
        if segment == "" or segment == ".":
            continue
        if segment == "..":
            if not segments:
                return struct(dir = None, error = "leaves the repository")
            segments.pop()
        else:
            segments.append(segment)
    return struct(dir = "/".join(segments), error = None)

def _is_true(value):
    return value in ["true", "True"]

def _suggested_target(lock, info):
    """The target `resolve` most likely maps a `path` entry to: the Bazel package at its path."""
    description = info.get("description", {})
    if type(description) != "dict" or not _is_true(description.get("relative", "")):
        return "//..."
    resolved = path_package_dir(lock_directory(lock), description.get("path", ""))
    return "//{}:<target>".format(resolved.dir) if resolved.dir != None else "//..."

def _quoted(names):
    return ", ".join(["`%s`" % n for n in names])

def resolve_errors(lock, lock_pkgs, resolve, build_from_pubspec = [], ignored = {}):
    """Everything wrong with how one `flutter_pub.from_lock()` names the lock's packages.

    The texts are rules_dart's `pub.from_lock`'s, which takes the same three
    attributes.

    Args:
        lock: The lock's `Label`.
        lock_pkgs: The lock's packages, from `parse_pubspec_lock`.
        resolve: The tag's `resolve`: package name to the target's `Label`.
        build_from_pubspec: The tag's `build_from_pubspec`: package names.
        ignored: The tag's `ignored`: package name to the reason.

    Returns:
        One line per problem, in a stable order; empty when every name is
        valid. The caller heads them with the tag (`resolve_failure`).
    """
    problems = []
    chosen = {}
    for attr, names in [("resolve", resolve.keys()), ("build_from_pubspec", build_from_pubspec), ("ignored", ignored.keys())]:
        stale = sorted([n for n in names if n not in lock_pkgs])
        if stale:
            problems.append("  - `%s` %s %s, which the lock does not list. Remove %s." % (
                attr,
                "maps" if attr == "resolve" else "names",
                _quoted(stale),
                "them" if len(stale) > 1 else "it",
            ))
        if attr != "resolve":
            not_path = sorted([n for n in names if n in lock_pkgs and lock_pkgs[n].get("source") != "path"])
            if not_path:
                problems.append(
                    "  - `%s` names %s, which the lock does not list as `path`: it takes only path packages." % (attr, _quoted(not_path)),
                )
        for name in names:
            chosen.setdefault(name, []).append(attr)
    for name in sorted(chosen.keys()):
        if len(chosen[name]) > 1:
            problems.append("  - `%s` is named in %s; name it in one." % (
                name,
                " and ".join(["`%s`" % a for a in chosen[name]]),
            ))
    unnamed = sorted([n for n, info in lock_pkgs.items() if info.get("source") == "path" and n not in chosen])
    if unnamed:
        problems.append(
            ("  - it lists %s as %s. Name each in exactly one of:\n" +
             "      resolve = {%s}  (a target of yours builds it)\n" +
             "      build_from_pubspec = [%s]  (build it from its directory, as a hosted package)\n" +
             "      ignored = {%s}  (nothing builds it; depending on it fails with the reason)") % (
                _quoted(unnamed),
                "`path` packages" if len(unnamed) > 1 else "a `path` package",
                ", ".join(['"%s": "%s"' % (n, _suggested_target(lock, lock_pkgs[n])) for n in unnamed]),
                ", ".join(['"%s"' % n for n in unnamed]),
                ", ".join(['"%s": "<why>"' % n for n in unnamed]),
            ),
        )
    return problems

def resolve_failure(hub, lock, problems):
    """The one message for a tag's `resolve_errors`.

    Args:
        hub: The tag's `name`.
        lock: The lock's `Label`.
        problems: What `resolve_errors` returned.

    Returns:
        The message.
    """
    return "flutter_pub.from_lock(name = \"%s\", lock = \"%s\"):\n%s" % (hub, lock, "\n".join(problems))

def path_package_directory(lock_dir, path):
    """The directory a `path` lock entry names, as pub reads it.

    Args:
        lock_dir: The absolute directory of the lock, `/`-separated.
        path: The entry's `description.path`: relative to the lock's
            directory, or absolute.

    Returns:
        The absolute directory, `/`-separated, without `.` or `..` segments.
    """
    path = path.replace("\\", "/")
    absolute = path.startswith("/") or (len(path) > 1 and path[1] == ":")
    full = path if absolute else lock_dir.replace("\\", "/") + "/" + path
    head = "/" if full.startswith("/") else ""
    segments = []
    for segment in full.split("/"):
        if segment == "" or segment == ".":
            continue
        if segment == "..":
            # Above the root is the root, as the system has it, and a drive
            # letter is a root.
            if segments and not (len(segments) == 1 and segments[0].endswith(":")):
                segments.pop()
            continue
        segments.append(segment)
    return head + "/".join(segments)

def resolved_targets(maps):
    """The packages mapped to workspace targets, over every `flutter_pub.from_lock()` tag.

    A mapped package is that target for the whole build: there is one
    repository per package, however many locks list it. The same package
    mapped to two different targets cannot be one repository.

    Args:
        maps: One `struct(lock, hub, resolve)` per tag: the lock's `Label`, the
            hub's name, and the tag's `resolve` (package name to target `Label`).

    Returns:
        `struct(targets, errors)`: `targets`, a dict of package name to
        `struct(target, lock, hub)` for the first tag that mapped it; `errors`,
        the messages, in a stable order.
    """
    mapped = {}
    for m in maps:
        for name, target in m.resolve.items():
            mapped.setdefault(name, []).append(struct(target = str(target), lock = str(m.lock), hub = m.hub))
    targets = {}
    errors = []
    for name in sorted(mapped.keys()):
        mappings = mapped[name]
        targets[name] = mappings[0]
        if len({x.target: True for x in mappings}) > 1:
            errors.append((
                "Package \"{name}\" is mapped to different targets:\n" +
                "{lines}\n" +
                "rules_flutter builds one copy of each package; map it to one target."
            ).format(
                name = name,
                lines = "\n".join([
                    "  - {target} (by the `resolve` of the flutter_pub.from_lock() for {lock}, hub \"{hub}\")".format(
                        target = x.target,
                        lock = x.lock,
                        hub = x.hub,
                    )
                    for x in mappings
                ]),
            ))
    return struct(targets = targets, errors = errors)
