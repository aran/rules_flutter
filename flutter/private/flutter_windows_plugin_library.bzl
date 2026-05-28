"""Compile a Flutter plugin's Windows C++ sources into a runner-link-input.

Wraps the plugin's Windows source layout (`windows/*.cpp`,
`windows/include/`) in a custom provider so the Windows runner's
`cc_common.compile()` can fold them in with the right Flutter Windows
engine + Windows SDK include paths.

Public Tier-2 API: re-exported from `flutter/windows.bzl` so users can
wire a monorepo plugin's BUILD.bazel without going through the `ext/`
overlay system. For pub.dev plugins, `flutter_pub_package` emits this
automatically when `windows/**/*.{cc,cpp,c,h,hh,hpp}` sources are
detected.

Kept distinct from flutter_linux_plugin_library: the two platforms
diverge in include layout, link libs, and runner integration; unifying
would push that divergence into per-rule conditionals.
"""

load("//flutter/private:flutter_desktop_plugin_info.bzl", "FlutterWindowsPluginInfo")

def _flutter_windows_plugin_library_impl(ctx):
    return [
        FlutterWindowsPluginInfo(
            srcs = depset(ctx.files.srcs),
            hdrs = depset(ctx.files.hdrs),
            include_dirs = depset(ctx.attr.includes),
        ),
        DefaultInfo(files = depset(ctx.files.srcs + ctx.files.hdrs)),
    ]

flutter_windows_plugin_library = rule(
    implementation = _flutter_windows_plugin_library_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "C/C++ source files (`.cc`, `.cpp`, `.c`).",
            allow_files = [".cc", ".cpp", ".c"],
        ),
        "hdrs": attr.label_list(
            doc = "Header files (`.h`, `.hh`, `.hpp`).",
            allow_files = [".h", ".hh", ".hpp"],
        ),
        "includes": attr.string_list(
            doc = "Relative include directories under the plugin package " +
                  "root (e.g. `[\"windows/include\"]`). The runner adds them " +
                  "as `-I` flags when compiling plugin srcs.",
        ),
    },
    doc = "Bundle a Flutter Windows plugin's C++ sources for the runner to compile + link.",
)
