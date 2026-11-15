"""Unit tests for versions.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:artifact_urls.bzl",
    "android_engine_artifact_path",
    "dart_sdk_artifact_path",
    "desktop_engine_artifact_path",
    "gen_snapshot_cross_artifact_path",
    "host_artifacts_path",
    "ios_engine_artifact_path",
)
load("//flutter/private:versions.bzl", "ARTIFACT_CHECKSUMS", "FLUTTER_SDK_EXACT_PINS", "FLUTTER_SDK_PACKAGES", "FLUTTER_VERSIONS")

def _latest_version_first_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "3.50.0", FLUTTER_VERSIONS.keys()[0])
    return unittest.end(env)

def _engine_revision_format_test_impl(ctx):
    env = unittest.begin(ctx)
    for version, meta in FLUTTER_VERSIONS.items():
        asserts.equals(
            env,
            40,
            len(meta.engine_revision),
            "engine_revision for {} should be 40-char hex".format(version),
        )
    return unittest.end(env)

def _checksums_exist_for_all_versions_test_impl(ctx):
    env = unittest.begin(ctx)
    for version in FLUTTER_VERSIONS.keys():
        asserts.true(
            env,
            version in ARTIFACT_CHECKSUMS,
            "ARTIFACT_CHECKSUMS missing entry for version {}".format(version),
        )
    return unittest.end(env)

def _checksums_have_key_artifacts_test_impl(ctx):
    env = unittest.begin(ctx)
    required_artifacts = [
        # Patched SDKs
        "flutter_patched_sdk.zip",
        "flutter_patched_sdk_product.zip",
        # Dart SDK sources the analyzer resolves `dart:` URIs from
        "sky_engine.zip",
        # Host Dart SDKs
        "dart-sdk-darwin-arm64.zip",
        "dart-sdk-darwin-x64.zip",
        "dart-sdk-linux-x64.zip",
        "dart-sdk-linux-arm64.zip",
        "dart-sdk-windows-x64.zip",
        # Host tools (frontend_server, gen_snapshot, icudtl.dat)
        "darwin-arm64/artifacts.zip",
        "darwin-x64/artifacts.zip",
        "linux-x64/artifacts.zip",
        "linux-arm64/artifacts.zip",
        "windows-x64/artifacts.zip",
        # Flutter web SDK
        "flutter-web-sdk.zip",
        # Desktop engine runtime libraries (release mode)
        "darwin-x64-release/FlutterMacOS.framework.zip",
        "linux-x64-release/linux-x64-flutter-gtk.zip",
        "windows-x64-release/windows-x64-flutter.zip",
    ]
    for version, checksums in ARTIFACT_CHECKSUMS.items():
        for artifact in required_artifacts:
            asserts.true(
                env,
                artifact in checksums,
                "ARTIFACT_CHECKSUMS[{}] missing {}".format(version, artifact),
            )
    return unittest.end(env)

def _downloaded_artifact_paths():
    """Every engine artifact path the repository rules download.

    Written out per platform rather than derived from the rules, so adding a
    download means adding it here, and a path without a checksum fails the test
    below instead of downloading unverified.
    """
    hosts = ["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64", "windows-x64"]
    modes = ["debug", "profile", "release"]
    paths = [
        "flutter_patched_sdk.zip",
        "flutter_patched_sdk_product.zip",
        "sky_engine.zip",
        "flutter-web-sdk.zip",
        "material_fonts.zip",
        "windows-x64/flutter-cpp-client-wrapper.zip",
    ]
    for host in hosts:
        paths.append(dart_sdk_artifact_path(host))
        paths.append(host_artifacts_path(host))
        paths.append("{}/font-subset.zip".format(host))

    # Only macOS publishes separate release and profile host tools.
    for host in ["darwin-arm64", "darwin-x64"]:
        paths.append(host_artifacts_path(host, "release"))
        paths.append(host_artifacts_path(host, "profile"))

    # macOS engines are x64 on every host; Linux has both architectures.
    for os, arch in [("macos", "x64"), ("linux", "x64"), ("linux", "arm64"), ("windows", "x64")]:
        for mode in modes:
            paths.append(desktop_engine_artifact_path(os, arch, mode))
    for mode in modes:
        paths.append(ios_engine_artifact_path(mode))
    for android_arch in ["arm", "arm64", "x64"]:
        for mode in modes:
            paths.append(android_engine_artifact_path(android_arch, mode))
        for mode in ["profile", "release"]:
            for cross_host in ["darwin-x64", "linux-x64", "windows-x64"]:
                paths.append(gen_snapshot_cross_artifact_path("android-" + android_arch, mode, cross_host))
    return paths

def _every_download_is_checksummed_test_impl(ctx):
    env = unittest.begin(ctx)
    for version, checksums in ARTIFACT_CHECKSUMS.items():
        for path in _downloaded_artifact_paths():
            asserts.true(
                env,
                path in checksums,
                "ARTIFACT_CHECKSUMS[{}] has no checksum for {}; run `bazel run //tools/update_flutter_version -- {}`".format(version, path, version),
            )
    return unittest.end(env)

def _source_sha256_recorded_for_all_versions_test_impl(ctx):
    # Every fetch of the framework source tarball is pinned against this
    # field, so an entry without one cannot be built at all —
    # `flutter_source_sha256()` fails the extension. Asserted against the raw
    # struct rather than through the accessor so an omission surfaces as a
    # test failure naming the version, not as a load-time abort.
    env = unittest.begin(ctx)
    for version, meta in FLUTTER_VERSIONS.items():
        asserts.equals(
            env,
            64,
            len(getattr(meta, "source_sha256", "")),
            "source_sha256 for {} should be 64-char hex (sha256)".format(version),
        )
    return unittest.end(env)

def _checksums_are_sha256_test_impl(ctx):
    env = unittest.begin(ctx)
    for version, checksums in ARTIFACT_CHECKSUMS.items():
        for artifact, sha in checksums.items():
            asserts.equals(
                env,
                64,
                len(sha),
                "checksum for {}:{} should be 64-char hex (sha256)".format(version, artifact),
            )
    return unittest.end(env)

def _sdk_pins_recorded_for_all_versions_test_impl(ctx):
    # The guard that keeps a lock from moving a package past an SDK package's
    # exact pin reads the pins of the default toolchain's version; one without
    # an entry fails the extension.
    env = unittest.begin(ctx)
    asserts.equals(env, sorted(FLUTTER_VERSIONS.keys()), sorted(FLUTTER_SDK_EXACT_PINS.keys()), "FLUTTER_SDK_EXACT_PINS has an entry for every Flutter version")
    for version, pins in FLUTTER_SDK_EXACT_PINS.items():
        for package, pinned in pins.items():
            asserts.true(env, len(pinned) > 0, "{} pins nothing in {}".format(package, version))
            asserts.false(env, "flutter_tools" == package, "flutter_tools is the tool, not an SDK package a lock lists")
    return unittest.end(env)

def _sdk_packages_recorded_for_all_versions_test_impl(ctx):
    # A Flutter SDK package of a lock is fetched only if the release's entry
    # lists it, so a version without one could fetch none of them.
    env = unittest.begin(ctx)
    asserts.equals(env, sorted(FLUTTER_VERSIONS.keys()), sorted(FLUTTER_SDK_PACKAGES.keys()), "FLUTTER_SDK_PACKAGES has an entry for every Flutter version")
    for version, packages in FLUTTER_SDK_PACKAGES.items():
        asserts.equals(env, sorted(packages), packages, "FLUTTER_SDK_PACKAGES[{}] is sorted".format(version))
        for package in ["flutter_test", "integration_test"]:
            asserts.true(env, package in packages, "FLUTTER_SDK_PACKAGES[{}] lacks {}".format(version, package))
    return unittest.end(env)

_t0_test = unittest.make(_latest_version_first_test_impl)
_t1_test = unittest.make(_engine_revision_format_test_impl)
_t2_test = unittest.make(_checksums_exist_for_all_versions_test_impl)
_t3_test = unittest.make(_checksums_have_key_artifacts_test_impl)
_t4_test = unittest.make(_checksums_are_sha256_test_impl)
_t5_test = unittest.make(_source_sha256_recorded_for_all_versions_test_impl)
_t6_test = unittest.make(_every_download_is_checksummed_test_impl)
_t7_test = unittest.make(_sdk_pins_recorded_for_all_versions_test_impl)
_t8_test = unittest.make(_sdk_packages_recorded_for_all_versions_test_impl)

def versions_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test)
