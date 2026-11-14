"""The two rules a Flutter pub package is built from.

Pub allows packages to depend on each other (`dio` imports `dio_web_adapter`,
which imports `dio`) and Bazel does not allow a dependency cycle, so a pub
package is split in two, as rules_dart's `pub.from_lock()` splits it (see
`@rules_dart//dart/pub:pub_library.bzl`):

* `flutter_pub_member` is one package: its files, and what it states about
  itself that needs nothing but its own archive. Its Dart side is
  rules_dart's `DartPackageMemberInfo`; what only Flutter knows (the plugin it
  registers, its per-platform native libraries, the assets, fonts and shaders
  it bundles) is a `FlutterPubMemberInfo` beside it.
* `flutter_pub_library` is the dependency cycle of one or more members, and
  everything the cycle depends on outside itself. It builds one `DartInfo`
  with a package record for each member, and one `FlutterInfo` that merges
  what each member contributes. Each package keeps its own name, `package_root`
  and language version, so `package_config.json` cannot tell it from packages
  built one to a target; and what a package bundles is bundled under its own
  `packages/<name>/`, whichever member an app depends on.

The library reads its members' providers itself, so nothing Flutter adds has to
pass through rules_dart. It accepts rules_dart's own `pub_package_member` too,
which a pure-Dart package is, so one cycle can mix packages of both kinds.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo", "DartPackageMetadataInfo", "DartUsedWithoutImportInfo")
load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "PORTABLE_EXEC_GROUPS", "SUMMARY_ATTRS", "dart_info", "package_identity_attrs", "runtime_reset")
load("@rules_dart//dart/pub:pub_library.bzl", "DartPackageMemberInfo", "dart_package_member_info")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:flutter_info.bzl", "flutter_info")
load("//flutter/private:flutter_library.bzl", "SKY_ENGINE_ATTR", "bundled_without_import", "flutter_analyzable_info_of_packages")
load("//flutter/private:flutter_plugin.bzl", "PLUGIN_PACKAGE_ATTRS", "plugin_contributions")

FlutterPubMemberInfo = provider(
    doc = "What a Flutter pub package contributes to `FlutterInfo`, beyond its Dart package.",
    fields = {
        "contributions": "dict: The keyword arguments of `flutter_info()` for what this package itself contributes (plugin, native libraries, assets, fonts, shaders).",
    },
)

def _flutter_pub_member_impl(ctx):
    metadata = ctx.attr.package[DartPackageMetadataInfo]
    package_name = metadata.package_name
    for f in ctx.files.resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the non-Dart remainder of `lib/`; Dart sources belong in " +
                 "`srcs`.") % (ctx.label, f.short_path),
            )
    member = dart_package_member_info(
        label = ctx.label,
        metadata = metadata,
        srcs = ctx.files.srcs,
        resources = ctx.files.resources,
    )
    declares_plugin = bool(ctx.attr.platforms)
    contributions = plugin_contributions(
        ctx,
        package_name,
        member.package.package_root,
        declares_plugin = declares_plugin,
    )

    # A plugin is registered by native code, and what a package bundles is
    # loaded by key, so a library that depends on the package for either
    # need not import it. Its cycle's library says so for it.
    used_without_import = [DartUsedWithoutImportInfo()] if declares_plugin else bundled_without_import(
        contributions["pub_fonts"],
        contributions["pub_assets"],
        contributions["pub_shaders"],
    )
    return [
        member,
        FlutterPubMemberInfo(contributions = contributions),
    ] + used_without_import

flutter_pub_member = rule(
    implementation = _flutter_pub_member_impl,
    attrs = PLUGIN_PACKAGE_ATTRS | package_identity_attrs(
        mandatory = True,
        doc = "The package's `dart_package_metadata`, which states its facts.",
    ) | {
        "bundle_paths": attr.string_dict(
            doc = "For a file of `assets` or `shaders` bundled by a path other than its own in the package, its package-relative path and that path: the `lib/x` a pubspec names `packages/<the package>/x`, which flutter_tools bundles as `x`.",
        ),
    },
    doc = "One Flutter pub package's files and facts, which a `flutter_pub_library` builds; not a library by itself. A plugin when it has `platforms`; otherwise it contributes only its assets, fonts and shaders.",
)

def _flutter_pub_library_impl(ctx):
    members = [m[DartPackageMemberInfo] for m in ctx.attr.members]
    srcs = [f for m in members for f in m.srcs]
    resources = [f for m in members for f in m.resources]
    packages = [m.package for m in members]

    # What each member of Flutter's own kind adds. A member of rules_dart's has
    # nothing to add.
    contributions = {}
    for member in ctx.attr.members:
        if FlutterPubMemberInfo in member:
            for channel, values in member[FlutterPubMemberInfo].contributions.items():
                contributions.setdefault(channel, []).extend(values)

    # The Android libraries of the members' `exports` are the ones this library
    # `exports` (see the attribute): the same labels, written once for each.
    # Disagreeing would hide a plugin's library from the APK's dexing, so it is
    # an error here rather than a missing class there.
    member_libs = sorted([entry.lib.label for entry in contributions.get("android_libs", [])])
    exported = sorted([lib.label for lib in ctx.attr.exports])
    if member_libs != exported:
        fail(
            "%s: its `exports` are %s but its members' are %s. They are the same Android libraries." %
            (ctx.label, [str(lib) for lib in exported], [str(lib) for lib in member_libs]),
        )

    return [
        DefaultInfo(
            files = depset(srcs + resources),
            runfiles = ctx.runfiles(files = srcs + resources),
        ),
        dart_info(
            ctx = ctx,
            packages = packages,
            srcs = srcs,
            resources = resources,
            deps = ctx.attr.deps,
            analysis_deps = [ctx.attr._sky_engine],
        ),
        flutter_analyzable_info_of_packages(ctx, packages, srcs, resources),
        flutter_info(deps = ctx.attr.deps, **contributions),
        # Depending on the library brings each member to the app, so it is
        # used without an import when one of them is: a plugin, or a package
        # that bundles fonts, assets or shaders.
    ] + ([DartUsedWithoutImportInfo()] if [m for m in ctx.attr.members if DartUsedWithoutImportInfo in m] else [])

flutter_pub_library = rule(
    implementation = _flutter_pub_library_impl,
    # A pub package cannot `select()` on the web compiler, so it is built once
    # whichever web compilers an app reaching it compiles for.
    cfg = runtime_reset,
    attrs = {
        "members": attr.label_list(
            providers = [DartPackageMemberInfo],
            mandatory = True,
            doc = "The packages of one dependency cycle, or the one package that is in none: `flutter_pub_member`s and rules_dart's `pub_package_member`s.",
        ),
        "deps": attr.label_list(
            providers = [DartInfo],
            doc = "The libraries of the packages the members depend on outside the cycle.",
        ),
        "exports": attr.label_list(
            providers = [JavaInfo],
            doc = "The members' Android libraries, under a `select()` on Android as theirs are. Named `exports` so that rules_android's dex aspect, which follows `deps`, `exports` and `runtime_deps`, reaches them from an APK that depends on this library through `flutter_android_plugin_libs`. What reaches `FlutterInfo` is the members' own.",
        ),
        "_sky_engine": SKY_ENGINE_ATTR,
    } | SUMMARY_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "A Flutter pub package as a library: its dependency cycle's packages, built as one target.",
)
