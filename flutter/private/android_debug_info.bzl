"""The split debug info of the snapshots an App Bundle ships, one an ABI.

rules_android's `android_application` and `android_binary` pass on no output
group of their dependencies, so a rule that forwards an App Bundle finds its
`.symbols` with this aspect. It follows the bundle's base module to the
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
