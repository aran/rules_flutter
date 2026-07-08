"""Rebuild an `android_binary` APK under `-c dbg` regardless of the ambient
compilation mode.

`bazel test //...` builds the default configuration, so a plain run never
produces the debug APK — whose contents differ from release, most importantly
the debug variant manifest's `INTERNET` permission that `flutter_android_app`
merges only for `-c dbg`. This rule forces `compilation_mode=dbg` on its APK
dependency via a Starlark transition and re-exposes the resulting APK, so a
default-configuration `dart_test` can inspect a real debug APK. The test target
itself stays in the default configuration and never compiles under `-c dbg`.
"""

def _force_dbg_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "dbg"}

_force_dbg = transition(
    implementation = _force_dbg_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _debug_apk_impl(ctx):
    # A transition on the attribute delivers the dependency as a one-element
    # list. android_binary exposes both the signed `<name>.apk` and an
    # unsigned variant; select the signed APK by name.
    dep = ctx.attr.apk[0]
    want = dep.label.name + ".apk"
    matches = [f for f in dep[DefaultInfo].files.to_list() if f.basename == want]
    if len(matches) != 1:
        fail("expected exactly one %s from %s, found %s" %
             (want, dep.label, [f.basename for f in matches]))
    out = ctx.actions.declare_file(ctx.label.name + ".apk")
    ctx.actions.symlink(output = out, target_file = matches[0])
    return [DefaultInfo(files = depset([out]))]

debug_apk = rule(
    implementation = _debug_apk_impl,
    attrs = {
        "apk": attr.label(
            mandatory = True,
            cfg = _force_dbg,
            doc = "An android_binary whose APK to rebuild under -c dbg.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Re-exposes an android_binary's APK built under -c dbg.",
)
