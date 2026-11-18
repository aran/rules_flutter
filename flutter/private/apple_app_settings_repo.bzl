"""The build's Apple plugin libraries whose `Package.swift` decides its defines from the app.

An Apple app builds such a plugin for itself (`swiftpm_app_settings.bzl`): its
plugin aggregator depends on this repository's `libraries` through a transition
that sets the app's Info.plist and environment, and links the ones its graph
names. The edge has to be known when the aggregator is loaded, before the app's
plugins are, so it is to every such library of the build, for the platform
being built; those the app does not link are analysed and not built.

Which plugins they are, each source repository records in its Apple layout
(`flutter_pub_package`), from a text scan of the manifest, so building this
list runs no Xcode. Only an iOS or macOS app's aggregator fetches it.
"""

load(":apple_plugin_repo.bzl", "APPLE_PLUGIN_FILE", "APP_LIBRARY_SUFFIX", "apple_repo")
load(":flutter_pub_index.bzl", "sibling_path", "source_repo")

visibility("//flutter/...")

def _flutter_apple_app_settings_impl(ctx):
    libraries = {"ios": [], "macos": []}
    for package in ctx.attr.packages:
        path = sibling_path(ctx, source_repo(package), APPLE_PLUGIN_FILE)
        if not path.exists:
            continue
        layouts = json.decode(ctx.read(path))["platforms"]
        for platform in sorted(layouts.keys()):
            if layouts[platform].get("app_settings"):
                libraries[platform].append("@{}//:{}_apple_{}{}".format(apple_repo(package), package, platform, APP_LIBRARY_SUFFIX))
    ctx.file("BUILD.bazel", """\
load("@bazel_skylib//rules:common_settings.bzl", "bool_setting")
load("@rules_flutter//flutter/private:generated_repos.bzl", "flutter_swiftpm_app_libraries")

# Whether the build has any such library, for `swiftpm_app_transition`: without
# one, an app's settings change nothing, and its native code is built in the
# configuration it is in.
bool_setting(
    name = "any",
    build_setting_default = {any},
    visibility = ["//visibility:public"],
)

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
        any = repr(bool(libraries["ios"] or libraries["macos"])),
        ios = repr(libraries["ios"]),
        macos = repr(libraries["macos"]),
    ))
    return ctx.repo_metadata(reproducible = True)

flutter_apple_app_settings = repository_rule(
    implementation = _flutter_apple_app_settings_impl,
    attrs = {
        "packages": attr.string_list(doc = "The build's packages that have an Apple repository."),
    },
    doc = "`@flutter_pub_apple_app_settings`: see the module docstring.",
)
