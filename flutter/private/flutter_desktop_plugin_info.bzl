"""Per-platform providers for Flutter desktop plugin source bundles.

Linux and Windows plugin libraries propagate their source files through
distinct providers so the runner aggregator at the application level
can filter by platform without inspecting type names. Kept in a shared
module so the providers themselves are loadable from both
flutter_linux_plugin_library.bzl and flutter_windows_plugin_library.bzl
plus the runner machinery in flutter_linux_application.bzl /
flutter_windows_application.bzl.
"""

FlutterLinuxPluginInfo = provider(
    doc = "Source bundle for a Flutter plugin's Linux C++ implementation.",
    fields = {
        "srcs": "depset[File]: source files to compile.",
        "hdrs": "depset[File]: header files (made available on the include path).",
        "include_dirs": "depset[str]: relative include directories under the plugin package root.",
    },
)

FlutterWindowsPluginInfo = provider(
    doc = "Source bundle for a Flutter plugin's Windows C++ implementation.",
    fields = {
        "srcs": "depset[File]: source files to compile.",
        "hdrs": "depset[File]: header files (made available on the include path).",
        "include_dirs": "depset[str]: relative include directories under the plugin package root.",
    },
)
