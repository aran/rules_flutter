"""Collects what a hot restart reads of an Android app, without building the APK.

A restart needs two things of the app it is restarting: the `flutter_assets`
tree, to see whether an asset moved, and the native libraries the APK packages,
to see whether the process must be replaced rather than restarted. Both are
built well before the APK: the APK is dexed, linked, zipped and signed from
them, which measured 24 s of a 46 s restart on an emulator, none of it needed
when only Dart changed.

The launch target is another rule set's rule (`android_binary`), so no output
group of ours can be added to it. An aspect reaches through it, transitions
included, and meets each dependency in the configuration the APK really used.
Building only its output groups builds only what they hold:

    bazel build <launch target> \\
        --aspects=@rules_flutter//flutter:android_bundle_parts.bzl%flutter_android_bundle_parts_aspect \\
        --output_groups=flutter_android_bundle_parts,flutter_android_native_libs

`flutter_android_bundle_parts` holds the application's `flutter_assets` tree.

`flutter_android_native_libs` holds what `android_binary` takes its native
libraries from, which is more than the Flutter application's own: it links
every `cc_library` (and `cc_import`, `cc_shared_library`) dependency into a
library of its own, packages the shared libraries those bring, and packages
the `jni/` libraries of every AAR below it. So the group holds each such
dependency's linker inputs (static archives, objects and shared libraries) and
each `AndroidNativeLibsInfo` library. A change to any of them is a change to
what the APK carries. It is built in the app's configuration, not the host's:
an exec configuration is left out, since a tool the build runs is not in the
app.

A prebuilt library checked into the workspace (a `cc_import` of a source `.a`
or `.so`) is in it as the source file it is: an output group can hold source
artifacts, and building the group only has to find them, not make them.
"""

load("@rules_android//providers:providers.bzl", "AndroidNativeLibsInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:bundle_parts.bzl", "own_libraries", "parts_of_dependencies", "parts_result")

ANDROID_BUNDLE_PARTS_OUTPUT_GROUP = "flutter_android_bundle_parts"
ANDROID_NATIVE_LIBS_OUTPUT_GROUP = "flutter_android_native_libs"

def _flutter_android_bundle_parts_aspect_impl(target, ctx):
    if ctx.configuration.is_tool_configuration():
        return parts_result([], [], [], ANDROID_BUNDLE_PARTS_OUTPUT_GROUP, ANDROID_NATIVE_LIBS_OUTPUT_GROUP)
    assets = []
    native_libs = []

    # The bundle rule is the one that names the application it packages; the
    # application is also reached by the registrant and by plugin libraries,
    # which would otherwise contribute the same files from other nodes.
    if ctx.rule.kind == "flutter_android_bundle":
        # Built for each ABI of the APK, one in each configuration below
        # `android_binary`'s native code.
        for app in ctx.rule.attr.application:
            if FlutterApplicationInfo in app:
                assets.append(depset([app[FlutterApplicationInfo].flutter_assets]))

    # What `android_binary` links and packages: cc dependencies' own libraries,
    # and the libraries AARs and Android libraries carry (already transitive).
    if CcInfo in target:
        native_libs.append(depset(own_libraries(target[CcInfo], target.label)))
    if AndroidNativeLibsInfo in target:
        native_libs.append(target[AndroidNativeLibsInfo].native_libs)

    return parts_result(
        assets,
        native_libs,
        parts_of_dependencies(ctx.rule.attr),
        ANDROID_BUNDLE_PARTS_OUTPUT_GROUP,
        ANDROID_NATIVE_LIBS_OUTPUT_GROUP,
    )

flutter_android_bundle_parts_aspect = aspect(
    implementation = _flutter_android_bundle_parts_aspect_impl,
    attr_aspects = ["*"],
    doc = "Collects the flutter_assets tree and the native library inputs of an Android app below a launch target, in the configuration each was built in.",
)
