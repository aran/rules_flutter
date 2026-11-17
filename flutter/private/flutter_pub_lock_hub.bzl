"""Hub repo rule for `flutter_pub.from_lock()` locks.

Mirrors `rules_dart//dart/pub:pub_lock_hub.bzl`'s top-level alias structure:
`@<hub>//:pkg` aliases the package's library, `@flutter_pub_lib__<pkg>//:<pkg>`
for a built package (whose dependency cycle is built as one target) and
`@flutter_pub__<pkg>//:<pkg>` for the other entries. Those repositories are the
build's, one per package however many hubs list it; the hub is the set of
labels the user's own lock(s) name, so a target reaches only what its lock
states.

It also has an `android/` package, aliasing the build's Maven data an Android
app checks the plugins it links against, and, for a lock with `flutter_test`, a
`goldens/` package aliasing the golden service the integration tests share.

`flutter_android_app` links the Android libraries of the plugins its
application depends on (`flutter_android_plugin_libs`), not those of every
package of the lock, and passes that rule `@<hub>//android:maven_requirements`.

Loaded lazily: Bazel only parses `android/BUILD.bazel` when an Android build
asks for it. Non-Android workspaces (mac-only, web-only) don't pay the
`@rules_android` / `@rules_kotlin` cost.

This rule is the rules_flutter sibling of rules_dart's `pub_lock_hub`; the two
never run for the same hub. `flutter_pub.from_lock()` always invokes this one.
`pub.pub()` (in non-Flutter modules) keeps using `pub_lock_hub`.
"""

load("//flutter/private:flutter_pub_index.bzl", "ANDROID_MAVEN_REPO", "GOLDENS_REPO", "library_repo", "source_repo")

def _flutter_pub_lock_hub_impl(ctx):
    built = {pkg: True for pkg in ctx.attr.built_packages}
    sdk_packages = {pkg: True for pkg in ctx.attr.sdk_packages}
    aliases = []
    for pkg in ctx.attr.packages:
        if pkg in sdk_packages and len({p: True for p in ctx.attr.sdk_prefixes.values()}) > 1:
            # A Flutter SDK package is the package of the selected SDK's
            # framework: `--@rules_flutter//flutter:sdk` chooses among them.
            branches = "".join([
                '        "@flutter_toolchains//:sdk_{sdk}": "@{repo}//:{pkg}",\n'.format(
                    sdk = sdk,
                    pkg = pkg,
                    repo = library_repo(pkg, prefix) if pkg in built else source_repo(pkg, prefix),
                )
                for sdk, prefix in sorted(ctx.attr.sdk_prefixes.items())
            ])
            aliases.append("""\
alias(
    name = "{pkg}",
    actual = select(
        {{
{branches}        }},
        no_match_error = "No Flutter SDK is declared for --@rules_flutter//flutter:sdk. Declared: {declared}.",
    ),
    visibility = ["//visibility:public"],
)""".format(pkg = pkg, branches = branches.replace("        \"@", "            \"@"), declared = ", ".join(sorted(ctx.attr.sdk_prefixes.keys()))))
            continue
        aliases.append("""\
alias(
    name = "{pkg}",
    actual = "@{repo}//:{pkg}",
    visibility = ["//visibility:public"],
)""".format(
            pkg = pkg,
            repo = library_repo(pkg) if pkg in built else source_repo(pkg),
        ))
    ctx.file("BUILD.bazel", "\n\n".join(aliases) + "\n")

    if "flutter_test" in ctx.attr.packages:
        ctx.file(
            "goldens/BUILD.bazel",
            """\
alias(
    name = "service",
    actual = "@{goldens}//:service",
    testonly = True,
    visibility = ["//visibility:public"],
)
""".format(goldens = GOLDENS_REPO),
        )

    ctx.file(
        "android/BUILD.bazel",
        """\
# What an Android app's `flutter_android_plugin_libs` checks the plugins it
# links against: every plugin's Maven requirements and what
# @rules_flutter_maven resolved.
alias(
    name = "maven_requirements",
    actual = "@{maven}//:requirements",
    visibility = ["//visibility:public"],
)

# Prints every Maven artifact the build's Android plugins declare, ready to
# paste into the root module's maven.install(name = "rules_flutter_maven").
alias(
    name = "maven_artifacts",
    actual = "@{maven}//:maven_artifacts",
    visibility = ["//visibility:public"],
)
""".format(maven = ANDROID_MAVEN_REPO),
    )

    # `bazel run @<hub>//swift:packages`: what the root module declares for
    # the lock's Apple plugins' Swift package dependencies.
    resolved = ctx.attr.swift_package_resolved
    ctx.file(
        "swift/BUILD.bazel",
        """\
load("@rules_flutter//flutter/private:flutter_swift_packages_report.bzl", "flutter_swift_packages_report")

flutter_swift_packages_report(
    name = "packages",
    hub = {hub},
    requirements = {requirements},
    resolved = {resolved},
    visibility = ["//visibility:public"],
)
""".format(
            hub = repr(ctx.attr.hub_name),
            requirements = repr(["@{}//:swift_requirements.json".format(r) for r in ctx.attr.apple_repos]),
            resolved = repr(_workspace_path(resolved) if resolved else ""),
        ),
    )
    return ctx.repo_metadata(reproducible = True)

def _workspace_path(label):
    """`label`'s path in the main repository, or its label when it is another repository's."""
    if label.repo_name:
        return str(label)
    return (label.package + "/" + label.name) if label.package else label.name

flutter_pub_lock_hub = repository_rule(
    implementation = _flutter_pub_lock_hub_impl,
    attrs = {
        "hub_name": attr.string(
            doc = "The hub's name, as the user gave `flutter_pub.from_lock(name = ...)`.",
            mandatory = True,
        ),
        "packages": attr.string_list(
            doc = "The package names of the hub's lock(s) to create aliases for.",
            mandatory = True,
        ),
        "sdk_packages": attr.string_list(
            doc = "The Flutter SDK packages among `packages`, whose alias follows the selected SDK when the SDKs' frameworks differ.",
            default = [],
        ),
        "sdk_prefixes": attr.string_dict(
            doc = "For each declared SDK, the prefix of the repositories that hold its framework's SDK packages.",
            default = {},
        ),
        "apple_repos": attr.string_list(
            doc = "The Apple repositories of the built packages, whose Swift package requirements `swift:packages` reports.",
            default = [],
        ),
        "swift_package_resolved": attr.label(
            doc = "The tag's `swift_package_resolved`, whose pins `swift:packages` checks.",
        ),
        "built_packages": attr.string_list(
            doc = "The built ones among `packages` (hosted, git, and Flutter SDK packages built from the Flutter source): their alias is their library repository's, the others' their one repository's.",
            default = [],
        ),
    },
    doc = "Creates a `flutter_pub.from_lock()` hub repo: the top-level package aliases, an `android/` " +
          "package aliasing the build's Maven requirements, and, with `flutter_test`, a " +
          "`goldens/` package aliasing the golden service the integration test macros share.",
)
