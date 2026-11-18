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

Given a `namespace`, the same action writes the manifest's relative component
class names (`.MainActivity`, `.sub.Receiver`, a bare `MainActivity`) in full
against it, as AGP's manifest merger does, so they do not resolve against the
application id instead: one `flutter create` runner can then ship under any
application id.

Given `set_version`, it writes the app's version onto the root
`<manifest>` as `android:versionCode` and `android:versionName`, from
`build_number` and `build_name` or the application's, the attributes Gradle
writes from `flutter.versionCode` and `flutter.versionName`. Done here rather
than through `android_binary`'s `manifest_values` so that the values may be a
`select()`. A base that declares either attribute must declare that value.

Given `uncompressed_native_libs`, it marks `<application>` with
`android:extractNativeLibs="false"`, as AGP does for an app whose native
libraries it stores uncompressed (`jniLibs.useLegacyPackaging = false`, its
default from a minimum SDK of 23).

Each runs the rules_flutter merger tool
(`merge_android_manifests.dart`) over a base manifest and an overlay.

The merger accepts only `<uses-permission>` / `<uses-permission-sdk-23>`
elements in the overlay and hard-fails on anything else, so it can never
silently mis-merge a variant manifest it does not fully understand.
"""

load("@rules_android//providers:providers.bzl", "StarlarkAndroidResourcesInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter/private:app_version.bzl", "android_version")
load("//flutter/private:application_version.bzl", "APPLICATION_VERSION_ATTR", "application_version", "version_names")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")

visibility("//flutter/...")

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
    tools = portable_tools(ctx)

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
    if ctx.attr.namespace:
        args.add("--namespace", ctx.attr.namespace)
    if ctx.attr.set_version:
        given = application_version(
            ctx.label,
            ctx.attr.application,
            ctx.attr.build_name,
            ctx.attr.build_number,
            stated_as = ctx.attr.version_stated_as,
        )
        version = android_version(given.build_name, given.build_number, version_names(given.settings))
        if version.error:
            fail("%s: %s" % (ctx.label, version.error))

        # The program reports these, defaults included, so a value the base
        # declares must be the same.
        args.add("--version-code", version.version_code)
        args.add("--version-name", version.version_name)
        for attribute, flag in [("build_number", "--version-code-setting"), ("build_name", "--version-name-setting")]:
            if attribute in given.settings:
                args.add(flag, given.settings[attribute])
    if ctx.attr.uncompressed_native_libs:
        args.add("--uncompressed-native-libs")
    args.add("--output", output)

    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(
            direct = [tool, ctx.file.base] + ([ctx.file.overlay] if ctx.file.overlay else []) + libraries,
            transitive = [tools.sdk_files.run],
        ),
        outputs = [output],
        mnemonic = "FlutterManifestMerge",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Merging Android variant manifest %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([output]))]

flutter_android_manifest_merge = rule(
    implementation = _flutter_android_manifest_merge_impl,
    attrs = APPLICATION_VERSION_ATTR | {
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
        "namespace": attr.string(
            doc = "The package the app's code lives in (Gradle's " +
                  "`namespace`). Relative class names in the base " +
                  "(`.MainActivity`, `.a.B`, `C`) are written out in full " +
                  "against it, rather than left to resolve against the " +
                  "application id. Empty leaves them as they are.",
        ),
        "set_version": attr.bool(
            doc = "Write `android:versionCode` and `android:versionName` " +
                  "onto the root `<manifest>` from `build_number` and " +
                  "`build_name`.",
        ),
        "build_name": attr.string(
            doc = "versionName, as `flutter build --build-name`. Empty is " +
                  "the application's, else `1.0.0`.",
        ),
        "build_number": attr.string(
            doc = "versionCode, as `flutter build --build-number`: a whole " +
                  "number from 1 to 2100000000. Empty is the application's, " +
                  "else `1`.",
        ),
        "version_stated_as": attr.string_dict(
            doc = "How the app states `build_name` or `build_number`, by " +
                  "attribute, where it is not that argument of its macro, " +
                  "such as `{\"build_number\": \"`versionCode` in " +
                  "`manifest_values`\"}`: for the message when it is not the " +
                  "application's.",
        ),
        "uncompressed_native_libs": attr.bool(
            doc = "Set `android:extractNativeLibs=\"false\"` on " +
                  "`<application>`, for an APK that stores its native " +
                  "libraries uncompressed (`android_binary`'s " +
                  "`nocompress_extensions = [\".so\"]`), as AGP does. A " +
                  "base that declares `\"true\"` is an error.",
        ),
        "_merge_tool": attr.label(
            default = _TOOL,
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Merges an overlay manifest's permissions, and those of the app's Android libraries, into a base manifest, qualifies its relative class names against a namespace, sets the app's version, and marks its native libraries as not to be extracted.",
)
