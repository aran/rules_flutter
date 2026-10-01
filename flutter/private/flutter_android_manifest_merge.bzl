"""AndroidManifest.xml permission merging.

Three callers, one mechanism. `flutter create` declares
`android.permission.INTERNET` only in the debug (and profile) variant
manifests under `android/app/src/debug/`; Gradle's manifest merger folds
them into debug APKs, and `flutter_android_app` reproduces that fold here.
The same rule also backs `flutter_android_app(permissions = [...])`, which
folds the app's *own* permissions in for every compilation mode — the seam a
networked app needs, since the debug variant's INTERNET belongs to the Dart
VM service and never reaches release.

It also lifts the `<uses-permission>` elements of the app's Android
libraries (plugins and AARs) into the app's manifest, as Gradle's merger
does. Bazel's merger drops a library's permissions unless
`--merge_android_manifest_permissions` is set, and an app built without that
flag shipped without them: a plugin's POST_NOTIFICATIONS, say, so Android 13
could never ask to show its notifications.

Each runs the rules_flutter merger tool
(`merge_android_manifests.dart`) over a base manifest and an overlay.

The merger accepts only `<uses-permission>` / `<uses-permission-sdk-23>`
elements in the overlay and hard-fails on anything else, so it can never
silently mis-merge a variant manifest it does not fully understand.
"""

load("@rules_android//providers:providers.bzl", "StarlarkAndroidResourcesInfo")

_TOOL = Label("//flutter/private/tools:merge_android_manifests.dart")

def _exported_library_manifests(libraries):
    """The manifests rules_android would merge into a binary over `libraries`.

    The same selection its merger makes: every resources node in the
    closure that exports its manifest.
    """
    nodes = depset(transitive = [
        d
        for lib in libraries
        if StarlarkAndroidResourcesInfo in lib
        for d in [
            lib[StarlarkAndroidResourcesInfo].direct_resources_nodes,
            lib[StarlarkAndroidResourcesInfo].transitive_resources_nodes,
        ]
    ])
    return [node.manifest for node in nodes.to_list() if node.exports_manifest]

def _flutter_android_manifest_merge_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    tool = ctx.file._merge_tool
    output = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")

    libraries = _exported_library_manifests(ctx.attr.libraries)
    args = ctx.actions.args()
    args.add(tool)
    args.add("--base", ctx.file.base)
    if ctx.file.overlay:
        args.add("--overlay", ctx.file.overlay)
    args.add_all(libraries, before_each = "--library")
    args.add_all(ctx.attr.placeholders, before_each = "--placeholder")
    args.add("--output", output)

    ctx.actions.run(
        executable = flutter_sdk_info.dart,
        arguments = [args],
        inputs = depset(
            direct = [tool, ctx.file.base] + ([ctx.file.overlay] if ctx.file.overlay else []) + libraries,
            transitive = [flutter_sdk_info.tool_files],
        ),
        outputs = [output],
        mnemonic = "FlutterManifestMerge",
        progress_message = "Merging Android variant manifest %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([output]))]

flutter_android_manifest_merge = rule(
    implementation = _flutter_android_manifest_merge_impl,
    attrs = {
        "base": attr.label(
            doc = "The main AndroidManifest.xml (already preprocessed for " +
                  "Gradle variables) the overlay merges into.",
            allow_single_file = True,
            mandatory = True,
        ),
        "overlay": attr.label(
            doc = "A manifest whose <uses-permission> elements merge into " +
                  "the base — either a variant manifest (e.g. " +
                  "android/app/src/debug/AndroidManifest.xml) or one " +
                  "written by flutter_android_permissions_manifest.",
            allow_single_file = True,
        ),
        "libraries": attr.label_list(
            doc = "Android libraries (and AARs) the app is built with; the " +
                  "permissions their manifests export merge into the base.",
        ),
        "placeholders": attr.string_list(
            doc = "The `${name}` placeholders the binary substitutes later " +
                  "(its `manifest_values`): a library permission using one " +
                  "passes through verbatim; any other is an error.",
        ),
        "_merge_tool": attr.label(
            default = _TOOL,
            allow_single_file = True,
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ],
    doc = "Merges an overlay manifest's permissions, and those of the app's Android libraries, into a base manifest.",
)
