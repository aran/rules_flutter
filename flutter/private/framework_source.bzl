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
load("//flutter/private:flutter_pub_index.bzl", "MEMBER_FILE", "MEMBER_OVERLAY")
load("//flutter/private:pub_constraint.bzl", "allows")
load("//flutter/private:pub_lock_sdks.bzl", "version_below_lower_bound")
load("//flutter/private:pub_resolve.bzl", "lock_directory")

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

def unset_message(ctx):
    """Why the framework source a repository rule was given is not there, or None.

    A source that needs a path of the machine it runs on (a local checkout)
    still loads where the path is not set, so that `bazel query` works for
    everyone: its `flutter_framework.json` then holds `unset`, and the
    repositories built from it hold targets that fail when something uses them.

    Args:
        ctx: A `repository_ctx` whose rule has a `framework_json` label attribute.

    Returns:
        The message, or None when the framework source is there.
    """
    return read_framework(ctx).get("unset")

def write_unset_stub(ctx, names, message, member = False):
    """Writes a repository whose targets fail with [message] when something uses them.

    Args:
        ctx: The `repository_ctx`.
        names: The names of the targets a build could ask this repository for.
        message: Why they fail.
        member: Whether the repository is an SDK package's source, which the
            hub's libraries plan against.
    """
    ctx.file("BUILD.bazel", 'load("@rules_flutter//flutter:engine.bzl", "flutter_missing_slice")\n' + "".join([
        """
flutter_missing_slice(
    name = {name},
    message = {message},
    visibility = ["//visibility:public"],
)
""".format(name = json.encode(name), message = json.encode(message))
        for name in names
    ]))
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
    """
    package_dir = framework_root(ctx).get_child("packages").get_child(package_name)
    if not package_dir.get_child("pubspec.yaml").exists:
        fail((
            "pubspec.lock lists `{name}` from the Flutter SDK, but the framework source {source} " +
            "has no packages/{name}; re-resolve the lock against that SDK."
        ).format(name = package_name, source = str(ctx.attr.framework_json)))
    ctx.watch_tree(package_dir)
    for child in package_dir.readdir():
        if child.basename == "android" and child.is_dir:
            for entry in child.readdir():
                if entry.basename not in ("BUILD", "BUILD.bazel"):
                    ctx.symlink(entry, "android/" + entry.basename)
        elif child.basename not in NEVER_LINKED + written:
            ctx.symlink(child, child.basename)

def _resolve_commands(sdk, default_sdk, verb, locks):
    """One command per lock, each run from the root of the workspace that holds the lock."""
    flag = "" if sdk == default_sdk else "--@rules_flutter//flutter:sdk={} ".format(sdk)
    commands = []
    for lock in locks:
        lock_dir = lock_directory(Label(lock))
        args = verb + (" --directory=" + lock_dir if lock_dir else "")
        commands.append("bazel run {}@rules_flutter//flutter/pub -- {}".format(flag, args))
    return "\n    ".join(commands)

def check_lock_floor(index, sdk, framework_version, default_sdk = "flutter"):
    """Fails when the lock needs a newer Flutter than the SDK's framework.

    Pub does not record the resolver's version, but it does record the floor
    its solution needs; a framework below that floor cannot compile what the
    lock pins.

    Args:
        index: The hub's index (`read_index`).
        sdk: The SDK's name.
        framework_version: The framework's version.
        default_sdk: The stock SDK's name.
    """
    for lock, constraint in sorted(index.flutter_constraints.items()):
        if constraint and version_below_lower_bound(framework_version, constraint):
            fail((
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
                command = _resolve_commands(sdk, default_sdk, "get", [lock]),
            ))

def check_dependency_constraints(index, sdk, package, pubspec_fields, default_sdk = "flutter"):
    """Fails when a Flutter SDK package needs a version of a locked package the lock does not hold.

    The SDK packages are recorded in the lock at `0.0.0`, so their own version
    never mismatches. What can is what their pubspecs require of the hosted
    packages the lock pins.

    Args:
        index: The hub's index (`read_index`).
        sdk: The SDK's name.
        package: The SDK package whose pubspec this is.
        pubspec_fields: The pubspec as decoded JSON (`read_pubspec(...).fields`).
        default_sdk: The stock SDK's name.
    """
    problems = []
    dependencies = pubspec_fields.get("dependencies") or {}
    for dep in sorted(dependencies.keys()):
        locked = index.versions.get(dep)
        spec = dependencies[dep]
        if type(spec) == "dict":
            spec = spec.get("version")
        if locked == None or type(spec) != "string" or index.sdk_packages.get(dep):
            continue
        if not allows(spec, locked):
            problems.append("  package:{pkg} needs {dep} {constraint}, and {lock} locks {dep} {locked}".format(
                pkg = package,
                dep = dep,
                constraint = spec,
                lock = ", ".join(index.locks),
                locked = locked,
            ))
    if problems:
        fail((
            "The lock does not fit the \"{sdk}\" Flutter SDK's framework:\n{problems}\n" +
            "Re-resolve the locks against this SDK, from the root of the workspace that " +
            "holds each:\n    {command}"
        ).format(
            sdk = sdk,
            problems = "\n".join(problems),
            command = _resolve_commands(sdk, default_sdk, "get", index.locks),
        ))
