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

How each tag names its lock's packages is checked by rules_dart's
`pub_lock_mapping_error`, as `pub.from_lock` checks its own, when the
extension reads the lock, so a wrong map fails every Bazel command that loads
the module, naming the lock, the package and the fix. What is here is how the
maps of every tag combine. Every function returns messages and never calls
`fail`: a unit test cannot catch `fail`.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "published_by_rules_dart")

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

def published_here_targets(locks, targets):
    """The packages rules_dart publishes to pub.dev, mapped to its own targets.

    `runfiles` reaches a build two ways: as `@rules_dart//dart/runfiles`, and
    from pub.dev, where each rules_dart release publishes those sources. Those
    are one package, so a build holds one copy, the one that came with the
    rules: it knows the runfiles layout of the rules_dart building it, whichever
    release a lock resolved. It is a `resolve` stated by the package's
    publisher, as rules_dart's own `pub` extension states it, so the two
    extensions serve the package alike. A lock's version of it is not compared,
    as with any `resolve`; code the rules' copy does not fit fails to compile.

    Only pub.dev's package is this one. A `runfiles` that any lock takes from
    another registry, git or a path is some other package of that name, and so
    is the build's to place. A `resolve` of it by any tag wins.

    Args:
        locks: One `struct(lock, hub, packages)` per tag: the lock's `Label`,
            the hub's name, and the lock's packages as `parse_pubspec_lock`
            returns them.
        targets: `resolved_targets`'s targets: the packages a tag maps.

    Returns:
        A dict of package name to `struct(target, lock, hub)`, as
        `resolved_targets` gives, for each published package some lock lists
        from pub.dev alone and no tag maps.
    """
    result = {}
    for name, target in published_by_rules_dart([lock.packages for lock in locks]).items():
        if name in targets:
            continue
        listed = [lock for lock in locks if name in lock.packages]
        result[name] = struct(target = str(target), lock = str(listed[0].lock), hub = listed[0].hub)
    return result
