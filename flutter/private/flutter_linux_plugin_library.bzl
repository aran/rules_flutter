"""Compile a Flutter plugin's Linux C++ sources into a runner-link-input.

Wraps the plugin's Linux source layout (`linux/*.cc`, `linux/include/`) in
a custom provider so the Linux runner's `cc_common.compile()` can fold
them in with the right Flutter Linux engine + GTK3 sysroot include paths.

Public Tier-2 API: re-exported from `flutter/linux.bzl` so users can
wire a monorepo plugin's BUILD.bazel without going through the `flutter/ext/`
overlay system. For pub.dev plugins, `flutter_pub_package` emits this
automatically when `linux/**/*.{cc,cpp,c,h,hh,hpp}` sources are
detected.

Why a custom provider instead of cc_library: the Flutter Linux runner
already wires the engine + GTK3 sysroot include dirs via cc_common.
Compiling each plugin separately into its own cc_library would require
threading the same include dirs into every plugin's compile, which is
brittle. Shipping the plugin as srcs+hdrs+includes lets the runner do
one compilation pass that already has the right system includes.

Kept distinct from flutter_windows_plugin_library: the two platforms
diverge in include layout, link libs, and runner integration; unifying
would push that divergence into per-rule conditionals.
"""

load("//flutter/private:flutter_desktop_plugin_info.bzl", "FlutterLinuxPluginInfo")

visibility("//flutter/...")

def _flutter_linux_plugin_library_impl(ctx):
    return [
        FlutterLinuxPluginInfo(
            srcs = depset(ctx.files.srcs),
            hdrs = depset(ctx.files.hdrs),
            include_dirs = depset(ctx.attr.includes),
            linkopts = ctx.attr.linkopts,
            link_errors = ctx.attr.link_errors,
        ),
        DefaultInfo(files = depset(ctx.files.srcs + ctx.files.hdrs)),
    ]

flutter_linux_plugin_library = rule(
    implementation = _flutter_linux_plugin_library_impl,
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
                  "root (e.g. `[\"linux/include\"]`). The runner adds them as " +
                  "`-I` flags when compiling plugin srcs.",
        ),
        "linkopts": attr.string_list(
            doc = "Linker flags for the system libraries the plugin's code needs, " +
                  "added to the runner's link (`[\"-lm\"]`). Pub plugins get these " +
                  "from their CMakeLists.txt `target_link_libraries`; a plugin " +
                  "overlay sets them by hand.",
        ),
        "link_errors": attr.string_list(
            doc = "Link libraries of the plugin's CMakeLists.txt that could not be " +
                  "translated into `linkopts`. Set by `flutter_pub_package`; the " +
                  "runner fails on them, naming each line.",
        ),
    },
    doc = "Bundle a Flutter Linux plugin's C++ sources for the runner to compile + link.",
)
