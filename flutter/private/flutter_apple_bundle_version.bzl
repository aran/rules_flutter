"""An Apple bundle's version, from Flutter's build name and build number."""

load("@rules_apple//apple:providers.bzl", "apple_provider")
load("//flutter/private:app_version.bzl", "apple_version")
load("//flutter/private:application_version.bzl", "APPLICATION_VERSION_ATTR", "application_version", "version_names")

visibility("//flutter/...")

def _impl(ctx):
    given = application_version(ctx.label, ctx.attr.application, ctx.attr.build_name, ctx.attr.build_number)
    version = apple_version(given.build_name, given.build_number, version_names(given.settings))
    if version.error:
        fail("%s: %s" % (ctx.label, version.error))

    # The file rules_apple's `apple_bundle_version` writes, which its
    # Info.plist step reads for the two keys.
    version_file = ctx.actions.declare_file(ctx.label.name + ".bundle_version")
    ctx.actions.write(version_file, json.encode({
        "build_version": version.build_version,
        "short_version_string": version.short_version_string,
    }))
    return [
        apple_provider.make_apple_bundle_version_info(version_file = version_file),
        DefaultInfo(files = depset([version_file])),
    ]

flutter_apple_bundle_version = rule(
    implementation = _impl,
    attrs = APPLICATION_VERSION_ATTR | {
        "build_name": attr.string(
            doc = "CFBundleShortVersionString, as `flutter build --build-name`: " +
                  "numbers separated by periods, padded to three (`2.1` is " +
                  "`2.1.0`). Empty is `1.0.0`.",
        ),
        "build_number": attr.string(
            doc = "CFBundleVersion, as `flutter build --build-number`: numbers " +
                  "separated by periods. Empty is `1`.",
        ),
    },
    doc = """The version of an iOS or macOS bundle, from Flutter's build name and number.

`flutter_ios_app` and `flutter_macos_app` declare one from their `build_name`
and `build_number`. Declare one yourself to give an app extension the same
version as its app, passing it as the `version` of both, and give it the app's
`application`, whose version it takes:

    flutter_apple_bundle_version(
        name = "version",
        application = ":app_flutter",
    )

The app checks that its `version` is its `application`'s, so one with another
version, or with none and so the defaults, fails the app's build. With an
`application`, it follows `--@rules_flutter//flutter:build_name` and
`build_number` as the application does; without one, its version is fixed, and
an app built with either setting fails unless the version is the setting's.

It provides what rules_apple's `apple_bundle_version` provides, so either fits
any `version` attribute.""",
)
