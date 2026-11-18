"""Per-platform providers for Flutter desktop plugin source bundles.

Linux and Windows plugin libraries propagate their source files through
distinct providers so the runner aggregator at the application level
can filter by platform without inspecting type names. Kept in a shared
module so the providers themselves are loadable from both
flutter_linux_plugin_library.bzl and flutter_windows_plugin_library.bzl
plus the runner machinery in flutter_linux_application.bzl /
flutter_windows_application.bzl.
"""

load("//flutter/private:unbuilt_native_code.bzl", "fail_on_unbuilt_native_code")

visibility("//flutter/...")

FlutterLinuxPluginInfo = provider(
    doc = "Source bundle for a Flutter plugin's Linux C++ implementation.",
    fields = {
        "srcs": "depset[File]: source files to compile.",
        "hdrs": "depset[File]: header files (made available on the include path).",
        "include_dirs": "depset[str]: relative include directories under the plugin package root.",
        "linkopts": "list[str]: linker flags the runner needs for this plugin's system libraries.",
        "link_errors": "list[str]: the plugin's link libraries that rules_flutter could not translate. The runner fails on them.",
    },
)

FlutterWindowsPluginInfo = provider(
    doc = "Source bundle for a Flutter plugin's Windows C++ implementation.",
    fields = {
        "srcs": "depset[File]: source files to compile.",
        "hdrs": "depset[File]: header files (made available on the include path).",
        "include_dirs": "depset[str]: relative include directories under the plugin package root.",
        "linkopts": "list[str]: linker flags the runner needs for this plugin's system libraries.",
        "link_errors": "list[str]: the plugin's link libraries that rules_flutter could not translate. The runner fails on them.",
    },
)

def plugin_link_flags(entries, platform):
    """The linker flags the runner needs for its plugins' system libraries.

    Args:
        entries: The `linux_plugin_libraries` or `windows_plugin_libraries` of
            the application: structs with `linkopts`, `link_errors`,
            `unbuilt_native_code` and `package`.
        platform: "Linux" or "Windows", for the failure message.

    Returns:
        The flags, in plugin order, without duplicates. Fails, listing every
        plugin, when a plugin declares link libraries that could not be
        translated, and before that when its CMake build makes a library
        rules_flutter does not (`unbuilt_native_code`).
    """
    fail_on_unbuilt_native_code(entries)
    flags = []
    errors = {}
    for entry in entries:
        for flag in entry.linkopts:
            if flag not in flags:
                flags.append(flag)
        if entry.link_errors:
            errors[entry.package] = entry.link_errors
    if errors:
        groups = [
            "    package:%s\n        %s" % (pkg, "\n        ".join(errors[pkg]))
            for pkg in sorted(errors.keys())
        ]
        fail((
            "These {platform} plugins link libraries rules_flutter cannot " +
            "translate. It reads plain system library names from the plugin's " +
            "CMakeLists.txt `target_link_libraries` call for the plugin's " +
            "own library; the rest needs CMake:\n\n{groups}\n\n" +
            "Provide a plugin overlay for each package " +
            "(flutter_pub.plugin_overlays in MODULE.bazel): " +
            "<root>/<package>/BUILD.bazel.tpl, declaring the plugin's " +
            "`flutter_{lower}_plugin_library` with the `linkopts` its " +
            "sources need."
        ).format(platform = platform, lower = platform.lower(), groups = "\n".join(groups)))
    return flags
