"""URL construction helpers for Flutter engine artifacts.

All Flutter engine artifacts are hosted on Google Cloud Storage at:
    https://storage.googleapis.com/flutter_infra_release/flutter/{engine_revision}/{artifact_path}
"""

_GCS_BASE = "https://storage.googleapis.com/flutter_infra_release/flutter"

def engine_artifact_url(engine_revision, artifact_path):
    """Constructs the full GCS download URL for a Flutter engine artifact.

    Args:
        engine_revision: The engine commit hash (40-char hex string).
        artifact_path: Path relative to the engine revision directory
            (e.g. "flutter_patched_sdk.zip", "darwin-x64/artifacts.zip").

    Returns:
        The full HTTPS URL to download the artifact.
    """
    return "{base}/{revision}/{path}".format(
        base = _GCS_BASE,
        revision = engine_revision,
        path = artifact_path,
    )

def dart_sdk_artifact_path(host_platform):
    """Returns the artifact path for the Flutter-bundled Dart SDK.

    Args:
        host_platform: Host platform string (e.g. "darwin-arm64", "linux-x64").

    Returns:
        Artifact path like "dart-sdk-darwin-arm64.zip".
    """
    return "dart-sdk-{platform}.zip".format(platform = host_platform)

def gen_snapshot_cross_artifact_path(target_platform, mode, host_platform):
    """Returns the artifact path for a cross-compile gen_snapshot archive.

    gen_snapshot is the AOT compiler. For cross-compilation (e.g. building
    Android on macOS), the binary is in a zip at:
        {target}-{mode}/{host}.zip

    Args:
        target_platform: Target platform (e.g. "android-arm64", "android-x64",
            "ios", "darwin-x64", "linux-x64").
        mode: Build mode ("profile" or "release").
        host_platform: Host platform where gen_snapshot runs
            (e.g. "darwin-x64", "linux-x64").

    Returns:
        Artifact path like "android-arm64-release/darwin-x64.zip".
    """
    return "{target}-{mode}/{host}.zip".format(
        target = target_platform,
        mode = mode,
        host = host_platform,
    )

def android_engine_artifact_path(android_arch, mode):
    """Returns the artifact path for the Android engine (flutter.jar).

    flutter.jar is a fat jar containing the Java embedding classes and
    the native libflutter.so for the target ABI.

    Args:
        android_arch: Android architecture (e.g. "arm64", "x64", "arm").
        mode: Build mode ("debug", "profile", "release").

    Returns:
        Artifact path like "android-arm64-release/artifacts.zip".
    """
    platform_dir = "android-{arch}".format(arch = android_arch)
    if mode != "debug":
        platform_dir = "{dir}-{mode}".format(dir = platform_dir, mode = mode)
    return "{dir}/artifacts.zip".format(dir = platform_dir)

def ios_engine_artifact_path(mode):
    """Returns the artifact path for the iOS engine (Flutter.xcframework).

    Args:
        mode: Build mode ("debug", "profile", "release").

    Returns:
        Artifact path like "ios-release/artifacts.zip".
    """
    platform_dir = "ios"
    if mode != "debug":
        platform_dir = "{dir}-{mode}".format(dir = platform_dir, mode = mode)
    return "{dir}/artifacts.zip".format(dir = platform_dir)

def host_artifacts_path(host_platform, mode = "debug"):
    """Returns the artifact path for host-platform tools archive.

    The host artifacts archive contains tools like gen_snapshot (for host),
    frontend_server, and other build tools.

    Args:
        host_platform: Host platform string (e.g. "darwin-x64", "linux-x64").
        mode: Build mode ("debug" or "release"). Debug archives contain the
            full toolset; release archives contain only gen_snapshot (product mode).

    Returns:
        Artifact path like "darwin-x64/artifacts.zip" or
        "darwin-x64-release/artifacts.zip".
    """
    platform_dir = host_platform
    if mode != "debug":
        platform_dir = "{dir}-{mode}".format(dir = platform_dir, mode = mode)
    return "{platform}/artifacts.zip".format(platform = platform_dir)

def desktop_engine_artifact_path(os, arch, mode):
    """Returns the artifact path for a desktop Flutter engine runtime library.

    Desktop engine artifacts contain the Flutter engine shared library needed
    to run Flutter applications on desktop platforms:
    - macOS: FlutterMacOS.framework.zip
    - Linux: linux-{arch}-flutter-gtk.zip
    - Windows: windows-{arch}-flutter.zip

    Args:
        os: Target OS ("macos", "linux", "windows").
        arch: Target architecture ("x64", "arm64").
        mode: Build mode ("debug", "profile", "release").

    Returns:
        Artifact path string, or None if the combination is not available.
    """

    # Map OS names to the platform directory prefix used by Flutter's GCS layout.
    os_prefix = {
        "macos": "darwin",
        "linux": "linux",
        "windows": "windows",
    }.get(os)
    if os_prefix == None:
        return None

    platform_dir = "{os}-{arch}".format(os = os_prefix, arch = arch)

    # macOS debug engine has no mode suffix (darwin-x64/framework.zip).
    # Linux and Windows desktop engines always include mode suffix, even for
    # debug (linux-x64-debug/, windows-x64-debug/).
    # See Flutter's LinuxEngineArtifacts.getBinaryDirs() and
    # WindowsEngineArtifacts.getBinaryDirs() in flutter_cache.dart.
    if os == "macos":
        if mode != "debug":
            platform_dir = "{dir}-{mode}".format(dir = platform_dir, mode = mode)
    else:
        platform_dir = "{dir}-{mode}".format(dir = platform_dir, mode = mode)

    if os == "macos":
        return "{dir}/FlutterMacOS.framework.zip".format(dir = platform_dir)
    elif os == "linux":
        return "{dir}/linux-{arch}-flutter-gtk.zip".format(dir = platform_dir, arch = arch)
    elif os == "windows":
        return "{dir}/windows-{arch}-flutter.zip".format(dir = platform_dir, arch = arch)
    return None
