"""Shared engine helpers for Flutter repository rules.

Centralizes engine filegroup templates, binary name detection, platform
mapping, and the macOS double zip, used by the repositories of the engine
artifacts.
"""

# -- Engine filegroup templates ------------------------------------------------
# One template per OS. `{name}` is the target's name, which says the build
# mode of the engine it holds (see `engine_filegroup_for_os`); `{dir}` is where
# that engine was extracted.
#
# Each glob is strict: every pattern must match a file, so a repo that lacks a
# download fails when its package loads, naming the pattern, instead of
# building and failing later in a rule that finds no header or library.

_MACOS_ENGINE_FILEGROUP = """
filegroup(
    name = "{name}",
    srcs = glob(["{dir}/FlutterMacOS.framework/**"]),
    visibility = ["//visibility:public"],
)
"""

_LINUX_ENGINE_FILEGROUP = """
filegroup(
    name = "{name}",
    srcs = glob(["{dir}/libflutter_linux_gtk.so", "{dir}/flutter_linux/*.h"]),
    visibility = ["//visibility:public"],
)
"""

_WINDOWS_ENGINE_FILEGROUP = """
filegroup(
    name = "{name}",
    srcs = glob(
        [
            "{dir}/flutter_windows.dll",
            "{dir}/flutter_windows.dll.lib",
            "{dir}/flutter_windows.h",
            "{dir}/flutter_export.h",
            "{dir}/flutter_messenger.h",
            "{dir}/flutter_plugin_registrar.h",
            "{dir}/flutter_texture_registrar.h",
            "cpp-client-wrapper/cpp_client_wrapper/include/flutter/*.h",
            "cpp-client-wrapper/cpp_client_wrapper/*.h",
            "cpp-client-wrapper/cpp_client_wrapper/*.cc",
        ],
    ),
    visibility = ["//visibility:public"],
)
"""

_ENGINE_FILEGROUPS = {
    "macos": _MACOS_ENGINE_FILEGROUP,
    "linux": _LINUX_ENGINE_FILEGROUP,
    "windows": _WINDOWS_ENGINE_FILEGROUP,
}

ENGINE_MODES = ["release", "debug", "profile"]

def engine_target_name(mode):
    """The name of the target that holds the engine of one build mode.

    A repo that holds engines names each for its mode, so a plain name never
    stands for one mode. The plain `engine_library` is only ever the engine of
    the build mode, chosen by a `select()`.

    Args:
        mode: One of "release", "debug" or "profile".

    Returns:
        "engine_release_library", "engine_debug_library" or "engine_profile_library".
    """
    if mode not in ENGINE_MODES:
        fail("Unsupported engine mode: {}".format(mode))
    return "engine_{}_library".format(mode)

def engine_filegroup_for_os(target_os, mode, dir = "engine"):
    """Return the filegroup of the engine of one build mode for the given OS.

    Args:
        target_os: One of "macos", "linux", or "windows".
        mode: One of "release", "debug" or "profile"; names the target
            (`engine_target_name`).
        dir: The directory the engine archive was extracted into.

    Returns:
        A BUILD file snippet defining the `engine_<mode>_library` filegroup.
    """
    template = _ENGINE_FILEGROUPS.get(target_os)
    if not template:
        fail("Unsupported target OS for engine filegroup: {}".format(target_os))
    return template.format(name = engine_target_name(mode), dir = dir)

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

def gen_snapshot_binary_name(platform):
    """Return the gen_snapshot binary filename for the given host platform.

    Args:
        platform: Host platform string (e.g. "darwin-arm64", "windows-x64").

    Returns:
        "gen_snapshot.exe" on Windows, "gen_snapshot" otherwise.
    """
    if platform.startswith("windows"):
        return "gen_snapshot.exe"
    return "gen_snapshot"

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
    On Apple Silicon the x64 binary runs via Rosetta 2. Linux arm64 hosts
    have no cross toolchain (see `CROSS_COMPILATION_PAIRS`).

    Args:
        host_platform: Host platform string (e.g. "darwin-arm64", "linux-x64").

    Returns:
        The platform string to use when downloading gen_snapshot
        (e.g. "darwin-x64" for "darwin-arm64").
    """
    _FALLBACK = {
        "darwin-arm64": "darwin-x64",
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

def macos_inner_framework(base_dir = "engine"):
    """The inner FlutterMacOS.framework.zip of a macOS engine download.

    macOS engine artifacts are double-zipped: the outer zip contains
    FlutterMacOS.framework.zip, which is extracted in its place to get the
    actual .framework directory.

    Args:
        base_dir: Directory where the outer zip was extracted (default "engine").

    Returns:
        A `nested_archives` entry of `archive_repo`.
    """
    return {base_dir + "/FlutterMacOS.framework.zip": base_dir + "/FlutterMacOS.framework"}

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
