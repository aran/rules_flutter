"""How the repositories `flutter_pub.from_lock()` makes find each other.

There is one repository per package for the whole build, however many hubs
(`flutter_pub.from_lock(name = ...)`) list it. A built package (a hosted
package, or a Flutter SDK package other than `package:flutter`, which
`flutter_pub_package` builds from the pinned Flutter source) is two
repositories, made by the one module extension:

* its source repository, `flutter_pub__<package>` (`flutter_pub_package`): the
  package's files, its `flutter_pub_member` (or rules_dart's
  `pub_package_member`) and the facts it states about itself, which need
  nothing but its own archive;
* its library repository, `flutter_pub_lib__<package>` (`flutter_pub_library_repo`):
  the package's dependency cycle as one library, in the repository of the
  cycle's first package by name, which the others alias. A cycle is built only
  where it is declared (`flutter_pub.cycle()`, or rules_dart's curated ones).

`package:flutter` (`flutter_framework_package`), the stub for a lock entry
nothing supplies, and a package `flutter_pub.from_lock(resolve = ...)` maps to a
workspace target (`flutter_resolved_package`) are each one repository named
`flutter_pub__<package>`, which is its own library.

Library repositories read what source repositories record (their pubspec
dependencies, and `MEMBER_FILE`), which is why the source repositories read
nothing of each other: planning a cycle never asks a repository to wait on
itself. Both are read through canonical names, since Bazel fetches every
repository a label attribute names before the rule runs and only the packages
a cycle reaches are wanted.

What every repository needs to know of the lock, and would otherwise state in
an attribute of its own (growing the lock's record of the repositories with
the square of the package count), is stated once in the one index
repository, over every lock of the build. A hub is only the set of aliases a
user's own lock names.
"""

visibility("//flutter/...")

# What the repositories of the build are named by. No hub name is part of them,
# so a hub cannot be named with this prefix.
SPOKE_PREFIX = "flutter_pub"

# The one index repository, and the build-wide repositories beside the packages.
INDEX_REPO = "flutter_pub_index"
ANDROID_MAVEN_REPO = "flutter_pub_android_maven"
APPLE_APP_SETTINGS_REPO = "flutter_pub_apple_app_settings"
GOLDENS_REPO = "flutter_pub_goldens"

# The file each source repository writes: what its library repository needs to
# build the package with the others of its cycle.
MEMBER_FILE = "flutter_pub_member.json"

# What kind of member a source repository holds.
MEMBER_DART = "dart"  # rules_dart's `pub_package_member`
MEMBER_FLUTTER = "flutter"  # `flutter_pub_member`
MEMBER_OVERLAY = "overlay"  # an overlay's whole BUILD file, which `:<package>` is

_INDEX_FILE = "index.json"

def source_repo(package, prefix = SPOKE_PREFIX):
    """The name of a package's source repository: its files and the build it states.

    Args:
        package: The package.
        prefix: What the build's repositories are named by; another framework's
            Flutter SDK packages have a prefix of their own (`sdk_prefix`).

    Returns:
        The repository's name.
    """
    return "{}__{}".format(prefix, package)

def files_repo(package, prefix = SPOKE_PREFIX):
    """The name of the repository holding a hosted, git or Flutter SDK package's fetched files."""
    return "{}_files__{}".format(prefix, package)

def library_repo(package, prefix = SPOKE_PREFIX):
    """The name of the repository holding a built package's library."""
    return "{}_lib__{}".format(prefix, package)

def index_repo(prefix = SPOKE_PREFIX):
    """The name of the index repository of a prefix."""
    return prefix + "_index"

def sdk_prefix(sdk):
    """What the Flutter SDK packages of the framework of another SDK are named by.

    The default SDK's framework is the build's own (`SPOKE_PREFIX`). Hubs may not
    be named with this prefix either.
    """
    return "{}-{}".format(SPOKE_PREFIX, sdk)

def _canonical_prefix(ctx):
    """What canonical names of the extension's repositories start with, seen from `ctx`."""
    return ctx.name[:len(ctx.name) - len(ctx.original_name)]

def sibling_path(ctx, repo, path):
    """The path of a file at the root of another repository of the same module extension.

    Args:
      ctx: The reading repository's `repository_ctx`.
      repo: The other repository's name, as the extension gave it.
      path: A file at its root.

    Returns:
      Its path.
    """
    return ctx.path(Label("@@{}{}//:{}".format(_canonical_prefix(ctx), repo, path)))

def read_sibling_file(ctx, repo, path):
    """Reads a file of another repository of the same module extension.

    Args:
      ctx: The reading repository's `repository_ctx`.
      repo: The other repository's name, as the extension gave it.
      path: A file at its root.

    Returns:
      The file's text.
    """
    return ctx.read(sibling_path(ctx, repo, path))

def read_index(ctx, prefix = SPOKE_PREFIX):
    """The index: which packages the locks list, by who supplies them.

    Args:
      ctx: The reading repository's `repository_ctx`.
      prefix: The prefix of the index to read.

    Returns:
      `struct(built, other, sdk_packages, main_prefix, sdk_prefix, via_hub, versions, locks, flutter_constraints, cycles, advisory_cycles)`:
      `built`, a dict of the names of the built
      packages (hosted ones and Flutter SDK ones built from the Flutter
      source; each has a library repository); `other`, a dict of the names of
      the locks' other entries (`package:flutter`, packages mapped to a
      workspace target, and entries nothing supplies), whose `flutter_pub__<name>`
      repository is the library; `sdk_packages`, the Flutter SDK packages among
      them. `main_prefix` names the repositories of every other package and
      `sdk_prefix` those of the SDK packages: the same unless this is the index
      of another SDK's framework. `via_hub` says that a package depending on an
      SDK package reaches it through the main hub's alias, which follows the
      selected SDK (`sdk_hubs`: a hub that lists each). `versions` is the version the build uses of
      each package the locks list, `locks` their labels, and
      `flutter_constraints` the `sdks: flutter` constraint of each.
      `cycles` are the root module's `flutter_pub.cycle()` declarations and
      `advisory_cycles` every other declaration that may apply (`pub_cycles.bzl`),
      each a list of packages.
    """
    index = json.decode(read_sibling_file(ctx, index_repo(prefix), _INDEX_FILE))
    return struct(
        built = {n: True for n in index["built"]},
        other = {n: True for n in index["other"]},
        sdk_packages = {n: True for n in index.get("sdk_packages", [])},
        main_prefix = index.get("main_prefix") or prefix,
        sdk_prefix = index.get("sdk_prefix") or prefix,
        via_hub = index.get("via_hub", False),
        sdk_hubs = index.get("sdk_hubs", {}),
        versions = index.get("versions", {}),
        locks = index.get("locks", []),
        flutter_constraints = index.get("flutter_constraints", {}),
        cycles = index.get("cycles", []),
        advisory_cycles = index.get("advisory_cycles", []),
    )

def owner_prefix(index, package):
    """The prefix of the repositories that hold a package: its SDK's framework's, or the build's."""
    return index.sdk_prefix if package in index.sdk_packages else index.main_prefix

def library_label(index, package):
    """The label of a locked package's library, as another package depends on it.

    Args:
      index: The index, from `read_index`.
      package: A package of the locks.

    Returns:
      The label string.
    """
    if package in index.sdk_packages and index.via_hub:
        return "@{}//:{}".format(index.sdk_hubs[package], package)
    owner = owner_prefix(index, package)
    repo = library_repo(package, owner) if package in index.built else source_repo(package, owner)
    return "@{}//:{}".format(repo, package)

def _flutter_pub_index_impl(ctx):
    ctx.file("BUILD.bazel", "")
    ctx.file(_INDEX_FILE, json.encode({
        "built": ctx.attr.built,
        "other": ctx.attr.other,
        "sdk_packages": ctx.attr.sdk_packages,
        "main_prefix": ctx.attr.main_prefix,
        "sdk_prefix": ctx.attr.sdk_prefix,
        "via_hub": ctx.attr.via_hub,
        "sdk_hubs": ctx.attr.sdk_hubs,
        "versions": ctx.attr.versions,
        "locks": ctx.attr.locks,
        "flutter_constraints": ctx.attr.flutter_constraints,
        "cycles": [c.split(" ") for c in ctx.attr.cycles],
        "advisory_cycles": [c.split(" ") for c in ctx.attr.advisory_cycles],
    }))
    return ctx.repo_metadata(reproducible = True)

flutter_pub_index = repository_rule(
    implementation = _flutter_pub_index_impl,
    attrs = {
        "built": attr.string_list(doc = "The locks' built packages, hosted and from the Flutter source: each has a source and a library repository."),
        "other": attr.string_list(doc = "The locks' other entries: `package:flutter`, packages mapped to workspace targets, and entries nothing supplies."),
        "sdk_packages": attr.string_list(doc = "The Flutter SDK packages among them, `package:flutter` included."),
        "main_prefix": attr.string(doc = "The prefix of the repositories of the packages that are not SDK ones. Empty for the index's own."),
        "sdk_prefix": attr.string(doc = "The prefix of the repositories of the SDK packages. Empty for the index's own."),
        "via_hub": attr.bool(doc = "Whether a dependency on an SDK package reaches it through the main hub's alias."),
        "sdk_hubs": attr.string_dict(doc = "For each SDK package, a hub that lists it, whose alias follows the selected SDK, for `via_hub`."),
        "versions": attr.string_dict(doc = "The version the build uses of each package the locks list."),
        "locks": attr.string_list(doc = "The locks' labels, for messages."),
        "flutter_constraints": attr.string_dict(doc = "The `sdks: flutter` constraint of each lock, by its label."),
        "cycles": attr.string_list(doc = "The root module's `flutter_pub.cycle()` declarations, each its packages joined by spaces: each must be exactly a cycle."),
        "advisory_cycles": attr.string_list(doc = "Other modules' and rules_dart's curated cycle declarations whose packages are all built, each its packages joined by spaces: each applies where it is exactly a cycle."),
    },
    doc = "The packages the repositories of every `flutter_pub.from_lock()` lock plan against.",
)
