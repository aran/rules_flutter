"""The split debug info of the snapshots an APK or App Bundle ships, one an ABI.

rules_android's `android_application` and `android_binary` pass on no output
group of their dependencies, so a rule that forwards an App Bundle finds its
`.symbols` with this aspect, and `flutter_android_debug_info` gives an APK
them. It follows an App Bundle's base module, or starts at the APK, to the
`android_binary`'s `assets`, where the `flutter_android_bundle` is built in
the binary's own configuration and splits its application one an ABI, in the
configurations the APK's native code is built in. The `.symbols` it collects
are those of the `libapp.so` of each ABI the bundle ships, and none is
compiled again.
"""

visibility("//flutter/...")

AndroidDebugInfo = provider(
    doc = "The `.symbols` of the snapshots an Android app ships.",
    fields = {"debug_info": "Depset of `.symbols` Files, one an ABI."},
)

# From a forwarded App Bundle to its `android_application`, then its base
# module, the base module's `assets`, and a `filegroup` of the assets (its
# `srcs`) to the Flutter bundle.
_EDGES = ["bundle", "base_module", "assets", "srcs"]

def _android_debug_info_aspect_impl(target, ctx):
    # The first target on the way with a `debug_info` group holds the app's:
    # the Flutter bundle, or a rule that already forwards it.
    if OutputGroupInfo in target and "debug_info" in target[OutputGroupInfo]:
        return [AndroidDebugInfo(debug_info = target[OutputGroupInfo].debug_info)]
    transitive = []
    for edge in _EDGES:
        value = getattr(ctx.rule.attr, edge, None)
        for dep in (value if type(value) == "list" else [value] if value else []):
            if type(dep) == "Target" and AndroidDebugInfo in dep:
                transitive.append(dep[AndroidDebugInfo].debug_info)
    return [AndroidDebugInfo(debug_info = depset(transitive = transitive))]

android_debug_info_aspect = aspect(
    implementation = _android_debug_info_aspect_impl,
    attr_aspects = _EDGES,
    doc = "Collects the `.symbols` of the snapshots an App Bundle ships, one an ABI.",
)

def _flutter_android_debug_info_impl(target, _ctx):
    # A target that already has the group (an App Bundle, a release) keeps
    # its own: an aspect may not provide a group its target has.
    if OutputGroupInfo in target and "debug_info" in target[OutputGroupInfo]:
        return []
    return [OutputGroupInfo(debug_info = target[AndroidDebugInfo].debug_info)]

# Applied to the target the command line names alone; the aspect it requires
# walks to the Flutter bundle.
flutter_android_debug_info = aspect(
    implementation = _flutter_android_debug_info_impl,
    requires = [android_debug_info_aspect],
    doc = """Gives an APK the `.symbols` of the snapshots it ships, in its `debug_info` output group.

rules_android's `android_binary` passes on no output group of its
dependencies, so an APK, `flutter_android_app`'s or one assembled from the
composable rules, has no `debug_info` of its own. Applied from the command
line, this aspect gives it one: with `--@rules_dart//dart:split_debug_info`,
the `.symbols` of each ABI's `libapp.so` in the APK
(`app.android-arm64.symbols`), as `flutter build apk --split-debug-info`
writes them, from the builds the APK packages, so nothing is compiled again:

    bazel build -c opt //:app \\
        --@rules_dart//dart:split_debug_info \\
        --@rules_flutter//flutter:obfuscate \\
        --aspects=@rules_flutter//flutter:android.bzl%flutter_android_debug_info \\
        --output_groups=+debug_info
""",
)
