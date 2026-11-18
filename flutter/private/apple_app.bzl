"""The target a user names for a Flutter iOS or macOS app.

`ios_application` and `macos_application` change the platform of their own
configuration (to iOS, to macOS), and a target is checked against
`target_compatible_with` in the configuration it is built in. So the
constraints a user puts on the app, or the macro puts on it for the platforms
it is for, are never seen as they were written on the rules_apple target: an
iOS platform has no `@platforms//os:macos` to satisfy, and on a Linux build
the rule is analysed (and fails) before anything compares the platforms.

A target in front of the rules_apple one does not change the platform. It
carries the constraints, so `bazel build //...` on a platform the app is not
for reports it SKIPPED, and forwards what the rules_apple target provides.

It also puts the rules_apple target in the app's configuration
(`swiftpm_app_transition`): in a build whose lock has a plugin whose
`Package.swift` reads the app, the plugins are built for each app, and so is
the runner that imports them (`flutter_apple_app_runner`). With the whole
bundle there, the runner's transition changes nothing, and the bundle and the
runner reach the app's `flutter_application` in one configuration, which
builds it once. In a build with no such plugin, the transition changes nothing.
"""

load(
    "@rules_apple//apple:providers.bzl",
    "AppleBundleInfo",
    "AppleDebugOutputsInfo",
    "AppleDsymBundleInfo",
    "AppleExecutableBinaryInfo",
    "IosApplicationBundleInfo",
    "MacosApplicationBundleInfo",
)
load("//flutter/private:program_analysis.bzl", "BundledProgramInfo", "bundled_program_aspect")
load("//flutter/private:swiftpm_app_settings.bzl", "swiftpm_app_transition")

# What a rules_apple application provides that something downstream reads: a
# test host takes the bundle info, `bazel run` the executable, and a dSYM
# build the debug outputs.
_FORWARDED = [
    AppleBundleInfo,
    AppleDebugOutputsInfo,
    AppleDsymBundleInfo,
    AppleExecutableBinaryInfo,
    IosApplicationBundleInfo,
    MacosApplicationBundleInfo,
    OutputGroupInfo,
    InstrumentedFilesInfo,
]

def _impl(ctx):
    # A transition on a single label gives a list of one.
    app = ctx.attr.app[0]
    archive = app[AppleBundleInfo].archive

    # The archive is named after the rules_apple target, which is private.
    # The one a user asked for is named after this one, as it always was.
    link = ctx.actions.declare_file(ctx.label.name + "." + archive.extension)
    ctx.actions.symlink(output = link, target_file = archive)

    executable = ctx.outputs.executable
    ctx.actions.symlink(
        output = executable,
        target_file = app[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    # The app's own output groups. Its checks are not this target's: they sit
    # under the app, in the configuration it builds its application in, and
    # Bazel runs the validations of every target a build reaches.
    groups = {name: getattr(app[OutputGroupInfo], name) for name in dir(app[OutputGroupInfo]) if name != "to_json"} if OutputGroupInfo in app else {}

    return [
        DefaultInfo(
            executable = executable,
            files = depset([link] + [f for f in app[DefaultInfo].files.to_list() if f != archive]),
            runfiles = app[DefaultInfo].default_runfiles.merge(ctx.runfiles(files = [link])),
        ),
        OutputGroupInfo(**groups),
    ] + [app[provider] for provider in _FORWARDED if provider in app and provider != OutputGroupInfo] + (
        # The program's own Dart files, for rules_dart's analysis: the
        # rules_apple bundle does not pass on what its contents provide, so
        # `bundled_program_aspect` reads them off the bundle's parts.
        [app[BundledProgramInfo].info] if BundledProgramInfo in app else []
    )

flutter_apple_app = rule(
    implementation = _impl,
    attrs = {
        "app": attr.label(
            doc = "The rules_apple application. Not built for this target's platform: it sets its own.",
            mandatory = True,
            providers = [AppleBundleInfo],
            aspects = [bundled_program_aspect],
            cfg = swiftpm_app_transition,
        ),
        "info_plist": attr.string(
            doc = "The label of the Info.plist the app's plugins read, as its " +
                  "`flutter_apple_app_runner`'s. A string, not a dependency: " +
                  "the transition reads the label, and the bundle builds the file.",
        ),
        "swift_package_environment": attr.string_dict(
            doc = "As the app's `flutter_apple_app_runner`'s.",
        ),
    },
    executable = True,
    doc = """The Flutter app a user names: carries `target_compatible_with` in front of a rules_apple application.

Forwards the application's providers and executable, and its archive under this
target's name (`<name>.ipa`, `<name>.zip`), and the `DartAnalyzableInfo` of the
Flutter program inside it.""",
)
