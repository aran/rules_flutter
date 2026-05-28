"""Shared engine helpers for Flutter repository rules.

Centralizes engine filegroup templates, binary name detection, platform
mapping, and macOS double-zip extraction used by repositories.bzl,
flutter_desktop_engine_repo.bzl, flutter_cross_repo.bzl, and
flutter_desktop_cross_repo.bzl.
"""

# -- Engine filegroup templates ------------------------------------------------
# Each template defines a filegroup named "engine_library" for a given OS.

MACOS_ENGINE_FILEGROUP = """
filegroup(
    name = "engine_library",
    srcs = glob(["engine/FlutterMacOS.framework/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)
"""

LINUX_ENGINE_FILEGROUP = """
filegroup(
    name = "engine_library",
    srcs = glob(
        ["engine/libflutter_linux_gtk.so", "engine/flutter_linux/*.h"],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

WINDOWS_ENGINE_FILEGROUP = """
filegroup(
    name = "engine_library",
    srcs = glob(
        [
            "engine/flutter_windows.dll",
            "engine/flutter_windows.dll.lib",
            "engine/flutter_windows.h",
            "engine/flutter_export.h",
            "engine/flutter_messenger.h",
            "engine/flutter_plugin_registrar.h",
            "engine/flutter_texture_registrar.h",
            "cpp-client-wrapper/cpp_client_wrapper/include/flutter/*.h",
            "cpp-client-wrapper/cpp_client_wrapper/*.h",
            "cpp-client-wrapper/cpp_client_wrapper/*.cc",
        ],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

LINUX_ENGINE_DEBUG_FILEGROUP = """
filegroup(
    name = "engine_debug_library",
    srcs = glob(
        ["engine-debug/libflutter_linux_gtk.so", "engine-debug/flutter_linux/*.h"],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

WINDOWS_ENGINE_DEBUG_FILEGROUP = """
filegroup(
    name = "engine_debug_library",
    srcs = glob(
        [
            "engine-debug/flutter_windows.dll",
            "engine-debug/flutter_windows.dll.lib",
            "engine-debug/flutter_windows.h",
            "engine-debug/flutter_export.h",
            "engine-debug/flutter_messenger.h",
            "engine-debug/flutter_plugin_registrar.h",
            "engine-debug/flutter_texture_registrar.h",
            "cpp-client-wrapper/cpp_client_wrapper/include/flutter/*.h",
            "cpp-client-wrapper/cpp_client_wrapper/*.h",
            "cpp-client-wrapper/cpp_client_wrapper/*.cc",
        ],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

MACOS_ENGINE_DEBUG_FILEGROUP = """
filegroup(
    name = "engine_debug_library",
    srcs = glob(["engine-debug/FlutterMacOS.framework/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)
"""

def engine_debug_filegroup_for_os(target_os):
    """Return the debug engine filegroup template string for the given OS.

    Args:
        target_os: One of "macos", "linux", or "windows".

    Returns:
        A BUILD file snippet defining the engine_debug_library filegroup, or empty string.
    """
    if target_os == "macos":
        return MACOS_ENGINE_DEBUG_FILEGROUP
    elif target_os == "linux":
        return LINUX_ENGINE_DEBUG_FILEGROUP
    elif target_os == "windows":
        return WINDOWS_ENGINE_DEBUG_FILEGROUP
    return ""

def engine_filegroup_for_os(target_os):
    """Return the engine filegroup template string for the given OS.

    Args:
        target_os: One of "macos", "linux", or "windows".

    Returns:
        A BUILD file snippet defining the engine_library filegroup.
    """
    if target_os == "macos":
        return MACOS_ENGINE_FILEGROUP
    elif target_os == "linux":
        return LINUX_ENGINE_FILEGROUP
    elif target_os == "windows":
        return WINDOWS_ENGINE_FILEGROUP
    else:
        fail("Unsupported target OS for engine filegroup: {}".format(target_os))

# -- Binary name helpers -------------------------------------------------------

def dart_binary_name(platform):
    """Return the dart binary filename for the given host platform.

    Args:
        platform: Host platform string (e.g. "darwin-arm64", "windows-x64").

    Returns:
        "dart.exe" on Windows, "dart" otherwise.
    """
    if platform.startswith("windows"):
        return "dart.exe"
    return "dart"

def dartaotruntime_binary_name(platform):
    """Return the dartaotruntime binary filename for the given host platform.

    Args:
        platform: Host platform string (e.g. "darwin-arm64", "windows-x64").

    Returns:
        "dartaotruntime.exe" on Windows, "dartaotruntime" otherwise.
    """
    if platform.startswith("windows"):
        return "dartaotruntime.exe"
    return "dartaotruntime"

# -- Platform mapping ----------------------------------------------------------

# Maps Flutter artifact URL platform prefix to canonical OS name.
PLATFORM_PREFIX_TO_OS = {
    "darwin": "macos",
    "linux": "linux",
    "windows": "windows",
}

def platform_to_os(platform):
    """Extract the OS name from a platform string like "darwin-arm64".

    Args:
        platform: Platform string with format "{os_prefix}-{arch}".

    Returns:
        Canonical OS name: "macos", "linux", or "windows".
    """
    prefix = platform.split("-")[0]
    return PLATFORM_PREFIX_TO_OS.get(prefix, prefix)

def platform_to_arch(platform):
    """Extract the architecture from a platform string like "darwin-arm64".

    Args:
        platform: Platform string with format "{os_prefix}-{arch}".

    Returns:
        Architecture string (e.g. "arm64", "x64"), or empty if no dash.
    """
    if "-" in platform:
        return platform.split("-")[1]
    return ""

def gen_snapshot_host_platform(host_platform):
    """Map a host platform to the gen_snapshot artifact host platform.

    Flutter only publishes x64 gen_snapshot binaries for cross-compilation.
    On arm64 hosts (macOS Apple Silicon, Linux aarch64), the x64 binary
    runs via Rosetta 2 (macOS) or qemu (Linux).

    Args:
        host_platform: Host platform string (e.g. "darwin-arm64", "linux-x64").

    Returns:
        The platform string to use when downloading gen_snapshot
        (e.g. "darwin-x64" for "darwin-arm64").
    """
    _FALLBACK = {
        "darwin-arm64": "darwin-x64",
        "linux-arm64": "linux-x64",
    }
    return _FALLBACK.get(host_platform, host_platform)

def engine_arch_for_os(os_name, arch):
    """Return the engine architecture, applying platform-specific overrides.

    macOS ARM64 uses x64 engine artifacts (no arm64 build on CDN).

    Args:
        os_name: Canonical OS name ("macos", "linux", "windows").
        arch: Architecture string (e.g. "arm64", "x64").

    Returns:
        The effective engine architecture string.
    """
    if os_name == "macos":
        return "x64"
    return arch

# -- macOS double-zip extraction -----------------------------------------------

def extract_macos_inner_framework(repository_ctx, base_dir = "engine"):
    """Extract the inner FlutterMacOS.framework.zip from a macOS engine download.

    macOS engine artifacts are double-zipped: the outer zip contains
    FlutterMacOS.framework.zip which must be extracted to get the actual
    .framework directory.

    Args:
        repository_ctx: The repository_rule context.
        base_dir: Directory where the outer zip was extracted (default "engine").
    """
    repository_ctx.extract(
        archive = base_dir + "/FlutterMacOS.framework.zip",
        output = base_dir + "/FlutterMacOS.framework",
    )
    repository_ctx.delete(base_dir + "/FlutterMacOS.framework.zip")

# -- Engine file discovery helpers for desktop rules --------------------------

def find_macos_framework_dir(engine_files):
    """Find the -F search path for FlutterMacOS.framework.

    Scans engine files for the framework binary and returns the parent
    directory of FlutterMacOS.framework/ (i.e. the -F flag value).

    Args:
        engine_files: List of Files from the engine_library filegroup.

    Returns:
        The directory path to pass to -F, or fails if not found.
    """
    for f in engine_files:
        if f.path.endswith("FlutterMacOS.framework/FlutterMacOS") or \
           f.path.endswith("FlutterMacOS.framework/Versions/A/FlutterMacOS"):
            parts = f.path.split("FlutterMacOS.framework")[0]
            return parts.rstrip("/")
    fail("Could not find FlutterMacOS.framework in engine files. " +
         "Expected a file matching FlutterMacOS.framework/FlutterMacOS or FlutterMacOS.framework/Versions/A/FlutterMacOS.")

def find_engine_lib_dir(engine_files, basename):
    """Find the directory containing a named engine library.

    Args:
        engine_files: List of Files from the engine_library filegroup.
        basename: The filename to search for (e.g. "libflutter_linux_gtk.so").

    Returns:
        The dirname of the matching file, or fails if not found.
    """
    for f in engine_files:
        if f.basename == basename:
            return f.dirname
    fail("Could not find {} in engine files.".format(basename))

# -- Linux multiarch triple mapping -------------------------------------------

def linux_multiarch_triple(arch):
    """Return the Debian multiarch triple for a Linux architecture.

    Args:
        arch: Architecture string ("x64" or "arm64").

    Returns:
        The multiarch triple (e.g. "x86_64-linux-gnu").
    """
    _TRIPLES = {
        "x64": "x86_64-linux-gnu",
        "arm64": "aarch64-linux-gnu",
    }
    triple = _TRIPLES.get(arch)
    if not triple:
        fail("No multiarch triple for architecture: {}".format(arch))
    return triple

def find_engine_header_dir(engine_files, header_suffix):
    """Find the parent directory of an engine header.

    Args:
        engine_files: List of Files from the engine_library filegroup.
        header_suffix: Path suffix to match (e.g. "flutter_linux/flutter_linux.h").

    Returns:
        The parent directory above the suffix match, or None if not found.
    """
    for f in engine_files:
        if f.path.endswith(header_suffix):
            idx = f.path.rfind(header_suffix)
            return f.path[:idx].rstrip("/")
    return None
