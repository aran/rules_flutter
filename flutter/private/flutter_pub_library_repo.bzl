"""The library repository of a built package of `flutter_pub.from_lock()`.

A package's files are in its source repository (`flutter_pub_package`); this
one decides what it is built with. It reads the pubspec dependencies of every
package the package reaches, as their source repositories record them (which
fetches only what building the package fetches anyway), and finds its
dependency cycle with rules_dart's planning (`pub_graph.bzl`). Pub allows
packages to depend on each other (`dio` and `dio_web_adapter` do), and Bazel
does not, so a cycle is one library, in the library repository of its first
package by name, which every other package of the cycle aliases. A cycle is
built only where it is declared (`flutter_pub.cycle()`, or rules_dart's
curated ones, `pub_cycles.bzl`); an undeclared one fails, naming the
declaration to write.

The library is a `flutter_pub_library` over the members of the cycle, or
rules_dart's `pub_library` when none of them has anything of Flutter's.
Either way its dependencies are the libraries of whatever the cycle depends on
outside itself. What those bring of Flutter's (a plugin, assets) reaches an
application through a `pub_library` too: Flutter's rules read it across one
with `flutter_info_forwarding_aspect`.
"""

load("@rules_dart//dart/pub:pub_graph.bzl", "dependency_cycle", "dependency_graph", "read_pubspec_dependencies")
load("//flutter/private:flutter_pub_index.bzl", "MEMBER_FILE", "MEMBER_FLUTTER", "MEMBER_OVERLAY", "library_label", "library_repo", "owner_prefix", "read_index", "read_sibling_file", "source_repo")
load("//flutter/private:pub_cycles.bzl", "DECLARE")

_MATERIAL_ICONS = "@rules_flutter//flutter:material_icons"

def _labels(labels):
    return "[{}]".format(", ".join(['"{}"'.format(label) for label in labels]))

def make_alias_build_content(name, actual):
    """BUILD content for a package that is its library by another target.

    Args:
      name: The package's name.
      actual: The label of the target that is its library.

    Returns:
      BUILD.bazel content as a string.
    """
    return """\
alias(
    name = "{name}",
    actual = "{actual}",
    visibility = ["//visibility:public"],
)
""".format(name = name, actual = actual)

def _member_dependencies(member_dependencies):
    """The `member_dependencies` attribute line of a library, sorted by member."""
    if not member_dependencies:
        return ""
    return "    member_dependencies = {{{}}},\n".format(", ".join([
        '"{}": {}'.format(m, _labels(sorted(member_dependencies[m])))
        for m in sorted(member_dependencies)
    ]))

def _android_exports(android_libs):
    """The `exports` attribute line of a library: its members' Android libraries on Android."""
    if not android_libs:
        return ""
    return """    exports = select({{
        "@platforms//os:android": {libs},
        "//conditions:default": [],
    }}),
""".format(libs = _labels(android_libs))

def make_library_build_content(name, members, deps, flutter, android_libs = [], member_dependencies = {}):
    """BUILD content for the library of a dependency cycle.

    Args:
      name: The library's name: the cycle's first package by name.
      members: Labels of the members of the cycle.
      deps: Labels of the libraries the cycle depends on outside itself.
      flutter: Whether a member is of Flutter's kind, so the library is a
        `flutter_pub_library` and not rules_dart's `pub_library`. `package:test`
        (never one) also carries the runner `dart_test` uses.
      android_libs: Labels of the members' Android libraries, which a
        `flutter_pub_library` lists under `exports` on Android.
      member_dependencies: For each member, by name, the packages its
        pubspec depends on directly, which a `flutter_pub_library` lists so
        each member's plugin depends on its own.

    Returns:
      BUILD.bazel content as a string.
    """
    if name == _TEST_PACKAGE:
        return _test_package_build_content(members, deps)
    load_statement, rule = (
        ('load("@rules_flutter//flutter/private:flutter_pub_library.bzl", "flutter_pub_library")', "flutter_pub_library") if flutter else ('load("@rules_dart//dart/pub:pub_library.bzl", "pub_library")', "pub_library")
    )
    return """\
{load_statement}

{rule}(
    name = "{name}",
    members = {members},
    deps = {deps},
{member_dependencies}{exports}    visibility = ["//visibility:public"],
)
""".format(
        load_statement = load_statement,
        rule = rule,
        name = name,
        members = _labels(members),
        deps = _labels(deps),
        member_dependencies = _member_dependencies(member_dependencies) if flutter else "",
        exports = _android_exports(android_libs) if flutter else "",
    )

# `package:test`'s library also carries the runner `dart_test` runs tests
# through, built from this same package so the two are one version. rules_dart's
# `pub_test_runner` declares it, as rules_dart's own hubs do; `dart_test` finds the
# runner on the direct dependency that provides `package:test`.
_TEST_PACKAGE = "test"

def _test_package_build_content(members, deps):
    return """\
load("@rules_dart//dart/pub:pub_library.bzl", "pub_library", "pub_test_runner")

pub_library(
    name = "test_library",
    members = {members},
    deps = {deps},
    visibility = ["//visibility:private"],
)

pub_test_runner(
    name = "test",
    library = ":test_library",
    visibility = ["//visibility:public"],
)
""".format(members = _labels(members), deps = _labels(deps))

def overlay_in_cycle_error(package, cycle):
    """The error for a package built from an overlay that is in a dependency cycle.

    Args:
      package: The package built from an overlay.
      cycle: The names of the packages of its cycle.

    Returns:
      The message.
    """
    return (
        "package `{package}` is built from a plugin overlay, and is in a dependency cycle " +
        "with {others}. An overlay replaces the package's whole target, so Bazel cannot " +
        "build the cycle as one target with it. Pub allows the cycle; Bazel does not. " +
        "Drop the overlay, or write one for the packages of the cycle together."
    ).format(
        package = package,
        others = ", ".join(["`{}`".format(p) for p in cycle if p != package]),
    )

def _flutter_pub_library_repo_impl(ctx):
    package = ctx.attr.package_name
    index = read_index(ctx, ctx.attr.prefix)

    # Every package this one reaches through built packages. The lock's other
    # entries (`package:flutter`, entries nothing supplies) are leaves:
    # they depend on built packages, never the other way round to a package
    # that depends on them.
    graph = dependency_graph(
        package,
        lambda p: [d for d in read_pubspec_dependencies(ctx, source_repo(p, owner_prefix(index, p))) if d in index.built or d in index.other],
        follow = index.built,
    )
    cycle = dependency_cycle(
        graph,
        package,
        declared = index.cycles,
        advisory = index.advisory_cycles,
        declare = DECLARE,
    )
    if cycle.owner != package:
        ctx.file("BUILD.bazel", make_alias_build_content(
            package,
            "@{}//:{}".format(library_repo(cycle.owner, owner_prefix(index, cycle.owner)), cycle.owner),
        ))
        return ctx.repo_metadata(reproducible = True)

    members = {
        member: json.decode(read_sibling_file(ctx, source_repo(member, owner_prefix(index, member)), MEMBER_FILE))
        for member in cycle.packages
    }
    overlays = [m for m, info in members.items() if info["kind"] == MEMBER_OVERLAY]
    if overlays and len(cycle.packages) > 1:
        fail(overlay_in_cycle_error(overlays[0], cycle.packages))
    if overlays:
        # The overlay's target is the library: the member and what it depends
        # on, in the one target the overlay writes.
        ctx.file("BUILD.bazel", make_alias_build_content(
            package,
            "@{}//:{}".format(source_repo(package, owner_prefix(index, package)), package),
        ))
        return ctx.repo_metadata(reproducible = True)

    deps = [library_label(index, dep) for dep in cycle.deps]
    if [m for m in members.values() if m["material_icons"]]:
        deps.append(_MATERIAL_ICONS)

    ctx.file("BUILD.bazel", make_library_build_content(
        name = package,
        members = ["@{}//:{}".format(source_repo(m, owner_prefix(index, m)), m) for m in cycle.packages],
        deps = sorted(deps),
        flutter = bool([m for m in members.values() if m["kind"] == MEMBER_FLUTTER]),
        android_libs = ["@{}//android:lib".format(source_repo(m, owner_prefix(index, m))) for m in cycle.packages if members[m].get("android_lib")],
        member_dependencies = {m: graph.get(m, []) for m in cycle.packages},
    ))
    return ctx.repo_metadata(reproducible = True)

flutter_pub_library_repo = repository_rule(
    implementation = _flutter_pub_library_repo_impl,
    attrs = {
        "prefix": attr.string(
            doc = "The prefix of the index the package is planned against: the build's, or another SDK framework's.",
            default = "flutter_pub",
        ),
        "package_name": attr.string(mandatory = True, doc = "The built package."),
    },
    doc = "Plans a built package's library: its dependency cycle, built as one target where it is declared.",
)
