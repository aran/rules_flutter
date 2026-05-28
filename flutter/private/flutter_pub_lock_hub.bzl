"""Augmented hub repo rule for Flutter pub lock files.

Mirrors `rules_dart//dart/pub:pub_lock_hub.bzl`'s top-level alias
structure (`@<hub>//:pkg` → `@<hub>__<pkg>//:<pkg>`) and additionally
emits an `android/BUILD.bazel` containing the
`all_android_plugin_libs` aggregator. The aggregator is a
`kt_android_library` whose deps are every spoke's `android:lib` target
(see `flutter_pub_package`'s `_make_android_subpackage_build_content`).

`flutter_android_app` depends on `@<hub>//android:all_android_plugin_libs`
to compile every transitively-needed plugin's Kotlin/Java sources into
the final `android_binary`. Spokes without Android sources contribute
an empty `:lib` (a no-op at link time) so the aggregator's deps list
is mechanical.

Loaded lazily — Bazel only parses `android/BUILD.bazel` when something
queries the aggregator. Non-Android workspaces (mac-only, web-only)
don't pay the `@rules_android` / `@rules_kotlin` cost.

This rule is the rules_flutter sibling of rules_dart's `pub_lock_hub`;
the two never run for the same hub. `flutter.pub()` always invokes
this one. `pub.pub()` (in non-Flutter modules) keeps using
`pub_lock_hub`.
"""

def _flutter_pub_lock_hub_impl(ctx):
    spoke_prefix = ctx.attr.spoke_prefix if ctx.attr.spoke_prefix else ctx.attr.hub_name

    # Top-level aliases — same shape as rules_dart's pub_lock_hub.
    aliases = []
    for pkg in ctx.attr.packages:
        aliases.append("""\
alias(
    name = "{pkg}",
    actual = "@{spoke}__{pkg}//:{pkg}",
    visibility = ["//visibility:public"],
)""".format(
            pkg = pkg,
            spoke = spoke_prefix,
        ))
    ctx.file("BUILD.bazel", "\n\n".join(aliases) + "\n")

    # `android/all_android_plugin_libs` aggregator. Every spoke
    # unconditionally exposes `android:lib`, so the deps list is just
    # the package list mapped to `@<hub>__<pkg>//android:lib`.
    android_deps = [
        '"@{spoke}__{pkg}//android:lib"'.format(
            spoke = spoke_prefix,
            pkg = pkg,
        )
        for pkg in ctx.attr.packages
    ]
    deps_block = ",\n        ".join(android_deps)
    if deps_block:
        deps_block = "\n        " + deps_block + ",\n    "

    ctx.file(
        "android/BUILD.bazel",
        """\
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

# Aggregator — re-exports every spoke's `android:lib`. Spokes without
# Android sources contribute empty libraries (a no-op at link time).
# The `flutter_android_app` Tier-1 macro adds this label to its
# `android_binary.deps`, ensuring every Flutter plugin's Kotlin/Java
# is on the runtime classpath without per-plugin manual wiring.
#
# `exports = [...]` (rather than `deps = [...]`) is required by
# rules_android: a `kt_android_library` without `srcs` or
# `resource_files` may not declare `deps` directly — the supported way
# to forward dependencies is `exports`.
kt_android_library(
    name = "all_android_plugin_libs",
    srcs = [],
    visibility = ["//visibility:public"],
    exports = [{deps}],
)
""".format(deps = deps_block),
    )

flutter_pub_lock_hub = repository_rule(
    implementation = _flutter_pub_lock_hub_impl,
    attrs = {
        "hub_name": attr.string(
            doc = "The apparent name of this hub repo (for constructing spoke labels).",
            mandatory = True,
        ),
        "spoke_prefix": attr.string(
            doc = "Prefix for spoke repo names. If empty, defaults to hub_name.",
            default = "",
        ),
        "packages": attr.string_list(
            doc = "All hosted package names to create aliases and Android-aggregator deps for.",
            mandatory = True,
        ),
    },
    doc = "Creates a Flutter pub hub repo with both the standard top-level package aliases " +
          "and an `android/all_android_plugin_libs` aggregator that the `flutter_android_app` " +
          "Tier-1 macro depends on. The aggregator pulls in every spoke's `android:lib`, " +
          "compiling all plugins' Kotlin/Java automatically.",
)
