"""The build's Apple plugin libraries whose `Package.swift` decides its defines from the app.

An Apple app builds such a plugin for itself (`swiftpm_app_settings.bzl`): its
plugin aggregator depends on `@flutter_pub_apple_app_settings//:libraries`
through a transition that sets the app's Info.plist and environment, and links
the ones its graph names. The edge has to be known when the aggregator is
loaded, before the app's plugins are, so it is to every such library of the
build, for the platform being built; those the app does not link are analysed
and not built.

Which plugins they are, each source repository records in its Apple layout
(`flutter_pub_package`), from a text scan of the manifest, so building this
list runs no Xcode. Only an iOS or macOS app's aggregator fetches it.

The Flutter SDK packages are the selected SDK's, so the list is one
`flutter_apple_app_libraries` repository per framework the SDKs have, and
`libraries` names the selected SDK's.
"""

load(":apple_plugin_repo.bzl", "APPLE_PLUGIN_FILE", "APP_LIBRARY_SUFFIX", "apple_repo")
load(":flutter_face_repo.bzl", "face_build_content")
load(":flutter_pub_index.bzl", "sibling_path", "source_repo")

visibility("//flutter/...")

def _app_libraries(ctx, packages):
    """The libraries of `packages` (each package to the prefix of its repositories) that read the app, by platform."""
    libraries = {"ios": [], "macos": []}
    for package, prefix in sorted(packages.items()):
        path = sibling_path(ctx, source_repo(package, prefix), APPLE_PLUGIN_FILE)

        # A package without an Apple layout may gain one, when an overlay it
        # was built from goes away, say.
        ctx.watch(path)
        if not path.exists:
            continue
        layouts = json.decode(ctx.read(path))["platforms"]
        for platform in sorted(layouts.keys()):
            if layouts[platform].get("app_settings"):
                libraries[platform].append("@{}//:{}_apple_{}{}".format(apple_repo(package, prefix), package, platform, APP_LIBRARY_SUFFIX))
    return libraries

def _flutter_apple_app_libraries_impl(ctx):
    libraries = _app_libraries(ctx, ctx.attr.packages)
    ctx.file("BUILD.bazel", """\
load("@rules_flutter//flutter/private:generated_repos.bzl", "flutter_swiftpm_app_libraries")

flutter_swiftpm_app_libraries(
    name = "libraries",
    deps = select({{
        "@platforms//os:ios": {ios},
        "@platforms//os:macos": {macos},
        "//conditions:default": [],
    }}),
    visibility = ["//visibility:public"],
)
""".format(
        ios = repr(libraries["ios"]),
        macos = repr(libraries["macos"]),
    ))
    return ctx.repo_metadata(reproducible = True)

flutter_apple_app_libraries = repository_rule(
    implementation = _flutter_apple_app_libraries_impl,
    attrs = {
        "packages": attr.string_dict(
            doc = "The build's packages that have an Apple repository, each to the prefix of its " +
                  "repositories: the Flutter SDK packages' that of one framework.",
        ),
    },
    doc = "The libraries of one framework's build that read the app: see the module docstring.",
)

def _flutter_apple_app_settings_impl(ctx):
    libraries = _app_libraries(ctx, ctx.attr.packages)
    ctx.file("BUILD.bazel", 'load("@bazel_skylib//rules:common_settings.bzl", "bool_setting")\n\n' + face_build_content(
        {sdk: "@" + repo for sdk, repo in ctx.attr.sdks.items()},
        {"libraries": "{prefix}//:libraries"},
        extra = """
# Whether the build has any such library, for `swiftpm_app_transition`: without
# one, an app's settings change nothing, and its native code is built in the
# configuration it is in. A transition cannot read a setting that follows the
# selected SDK, so it is one value for every SDK.
bool_setting(
    name = "any",
    build_setting_default = {any},
    visibility = ["//visibility:public"],
)
""".format(any = repr(bool(libraries["ios"] or libraries["macos"] or ctx.attr.assume_any))),
    ))
    return ctx.repo_metadata(reproducible = True)

flutter_apple_app_settings = repository_rule(
    implementation = _flutter_apple_app_settings_impl,
    attrs = {
        "sdks": attr.string_dict(
            doc = "Each declared SDK to the `flutter_apple_app_libraries` repository of its framework.",
            mandatory = True,
        ),
        "packages": attr.string_dict(
            doc = "The packages whose libraries decide `any`, each to the prefix of its repositories: " +
                  "those that are the same under every SDK.",
        ),
        "assume_any": attr.bool(
            doc = "Whether `any` holds whatever `packages` say: for Flutter SDK packages that differ " +
                  "between the SDKs, which only the selected SDK's build may read.",
        ),
    },
    doc = "`@flutter_pub_apple_app_settings`: see the module docstring.",
)
