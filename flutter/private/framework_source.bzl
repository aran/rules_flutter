"""A Flutter framework source, as the repositories built from it read it.

A framework source is a repository whose root is a flutter/flutter tree:
`packages/<name>/` for every
`sdk: flutter` package, `packages/flutter_tools/`,
`bin/internal/material_fonts.version`, and `flutter_framework.json`, which says
what the tree is:

    {"version": "<flutterVersion>", "commit": "<sha or empty>",
     "dirty": false, "origin": "<release|local|archive|...>"}

The repositories that read one take the label of its `flutter_framework.json`
as an attribute, so Bazel fetches the source before they run.
"""

load("@rules_dart//dart/pub:pub_graph.bzl", "write_pubspec_dependencies")
load("//flutter/private:failing_targets.bzl", "write_failing_build")
load("//flutter/private:flutter_pub_index.bzl", "MEMBER_FILE", "MEMBER_OVERLAY")
load("//flutter/private:pub_lock_sdks.bzl", "version_below_lower_bound")
load("//flutter/private:pub_resolve.bzl", "lock_directory")

visibility("//flutter/...")

FRAMEWORK_JSON = "flutter_framework.json"

def framework_root(ctx):
    """The root of the framework source a repository rule was given.

    Args:
        ctx: A `repository_ctx` whose rule has a `framework_json` label attribute.

    Returns:
        The path of the tree's root.
    """
    return ctx.path(ctx.attr.framework_json).dirname

def read_framework(ctx):
    """The decoded `flutter_framework.json` of the framework source a repository rule was given."""
    return json.decode(ctx.read(ctx.attr.framework_json))

def unusable_message(ctx):
    """Why the framework source a repository rule was given cannot be used, or None.

    A source that needs a path of the machine it runs on (a local checkout)
    still fetches where the path is not set, or does not hold a checkout, so
    that `bazel fetch --all` and `bazel query` work for everyone: its
    `flutter_framework.json` then holds `unusable`, and the repositories built
    from it hold targets that fail when something uses them.

    Args:
        ctx: A `repository_ctx` whose rule has a `framework_json` label attribute.

    Returns:
        The message, or None when the framework source can be used.
    """
    return read_framework(ctx).get("unusable")

def write_failing_stub(ctx, names, message, member = False):
    """Writes a repository whose targets fail with [message] when something uses them.

    For a repository whose SDK cannot be used, or does not fit the build's
    locks: only a build that uses the SDK fails.

    Args:
        ctx: The `repository_ctx`.
        names: The names of the targets a build could ask this repository for.
        message: Why they fail.
        member: Whether the repository is an SDK package's source, which the
            hub's libraries plan against.
    """
    write_failing_build(ctx, names, message)
    if member:
        ctx.file(MEMBER_FILE, json.encode({"kind": MEMBER_OVERLAY, "material_icons": False, "android_lib": False}))
        write_pubspec_dependencies(ctx, [])

# Root names a package's source repository owns, whatever it writes: Bazel's
# own files, which would make the root another package or repository. A
# package's entry of one of these names is never linked in, as rules_dart's
# `link_pub_files` links none.
NEVER_LINKED = ["BUILD", "BUILD.bazel", "MODULE.bazel", "REPO.bazel", "WORKSPACE", "WORKSPACE.bazel", "WORKSPACE.bzlmod"]

def link_framework_package(ctx, package_name, written = []):
    """Links `packages/<package_name>` of the framework source at the repository root.

    The link follows the source, so an edit to a local checkout is seen; the
    tree is watched so that a new file refetches the repository. `android/`
    is a directory of the repository with its entries linked, because the
    repository writes its `android/BUILD.bazel` there, and a write through a
    link to the directory would land in the checkout. A `BUILD` file already
    in the checkout's `android/` is not linked, for the same reason.

    Args:
        ctx: A `repository_ctx` whose rule has a `framework_json` label attribute.
        package_name: The package under `packages/`.
        written: Root names the repository writes, which are not linked, as
            Bazel's files (`NEVER_LINKED`) are not: a write would land in the
            checkout.

    Returns:
        None, or why the package cannot be linked: the framework source does
        not have it. Nothing is linked then; the package's absence is watched,
        so that a checkout that gains it refetches the repository.
    """
    package_dir = framework_root(ctx).get_child("packages").get_child(package_name)
    pubspec = package_dir.get_child("pubspec.yaml")
    ctx.watch(pubspec)
    if not pubspec.exists:
        return (
            "pubspec.lock lists `{name}` from the Flutter SDK, but the framework source {source} " +
            "has no packages/{name}; re-resolve the lock against that SDK."
        ).format(name = package_name, source = str(ctx.attr.framework_json))
    ctx.watch_tree(package_dir)
    for child in package_dir.readdir():
        if child.basename == "android" and child.is_dir:
            for entry in child.readdir():
                if entry.basename not in ("BUILD", "BUILD.bazel"):
                    ctx.symlink(entry, "android/" + entry.basename)
        elif child.basename not in NEVER_LINKED + written:
            ctx.symlink(child, child.basename)
    return None

def _resolve_commands(sdk, verb, locks):
    """One command per lock, each run from the root of the workspace that holds the lock.

    Each names the SDK: which one a build uses without the flag is the
    `flutter` extension's to say (`flutter.use_sdk`), not the hub's.
    """
    flag = "--@rules_flutter//flutter:sdk={} ".format(sdk)
    commands = []
    for lock in locks:
        lock_dir = lock_directory(Label(lock))
        args = verb + (" --directory=" + lock_dir if lock_dir else "")
        commands.append("bazel run {}@rules_flutter//flutter/pub -- {}".format(flag, args))
    return "\n    ".join(commands)

def lock_floor_message(index, sdk, framework_version):
    """Why the locks need a newer Flutter than the SDK's framework, or None.

    Pub does not record the resolver's version, but it does record the floor
    its solution needs; a framework below that floor cannot compile what the
    lock pins.

    Args:
        index: The hub's index (`read_index`).
        sdk: The SDK's name.
        framework_version: The framework's version.

    Returns:
        The message for the first lock that needs a newer one, or None.
    """
    for lock, constraint in sorted(index.flutter_constraints.items()):
        if constraint and version_below_lower_bound(framework_version, constraint):
            return (
                "{lock} was resolved against a newer Flutter than the \"{sdk}\" SDK has: the lock " +
                "requires flutter {constraint}, and the SDK's framework is {version}.\n" +
                "Either use a newer framework or re-resolve against this SDK, from the " +
                "root of the workspace that holds the lock:\n" +
                "    {command}"
            ).format(
                lock = lock,
                sdk = sdk,
                constraint = constraint,
                version = framework_version,
                command = _resolve_commands(sdk, "get", [lock]),
            )
    return None

def locked_versions(index):
    """The version the build uses of each hosted package, for `read_pubspec`'s `locked_versions`.

    A Flutter SDK package is recorded in the lock at `0.0.0`, so its own
    version is no version to compare a constraint with.

    Args:
        index: The hub's index (`read_index`).

    Returns:
        A dict of version by package name.
    """
    return {n: v for n, v in index.versions.items() if not index.sdk_packages.get(n)}

def dependency_constraint_message(index, sdk, package, unsatisfied):
    """Why a Flutter SDK package does not fit the versions the build uses of the locked packages, or None.

    What the SDK packages' pubspecs require of the hosted packages the locks
    pin (`flutter_test` holds `test_api` at exactly one version) is what can
    mismatch. The build has one version of each package, the highest any lock
    records, and that one must be one the SDK package allows.

    Args:
        index: The hub's index (`read_index`).
        sdk: The SDK's name.
        package: The SDK package whose pubspec this is.
        unsatisfied: The `unsatisfied` of its `read_pubspec(locked_versions =
            locked_versions(index))`: the constraints that exclude the version
            the build uses, by package.

    Returns:
        The message, or None when every constraint holds.
    """
    problems = []
    culprits = {}
    example = None
    for dep in sorted(unsatisfied.keys()):
        spec = unsatisfied[dep]
        locked = index.versions[dep]
        locks = index.version_locks.get(dep) or index.locks
        for lock in locks:
            culprits[lock] = True
        if example == None:
            example = "`{}: {}`".format(dep, spec)
        problems.append("  package:{pkg} needs {dep} {constraint}, and the build uses {dep} {locked}, which {locks} records".format(
            pkg = package,
            dep = dep,
            constraint = spec,
            locks = " and ".join(locks),
            locked = locked,
        ))
    if not problems:
        return None
    return (
        "The locks do not fit the \"{sdk}\" Flutter SDK's framework:\n{problems}\n" +
        "The build uses one version of each package, the highest any lock records. " +
        "Re-resolve each lock named against this SDK so that it holds a version the SDK " +
        "package allows (for example, with {example} in its pubspec's dependencies), from " +
        "the root of the workspace that holds it:\n    {command}"
    ).format(
        sdk = sdk,
        problems = "\n".join(problems),
        example = example,
        command = _resolve_commands(sdk, "get", sorted(culprits.keys())),
    )
