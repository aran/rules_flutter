"""Unit tests for versions.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//flutter/private:artifact_urls.bzl",
    "android_engine_artifact_path",
    "dart_sdk_artifact_path",
    "desktop_engine_artifact_path",
    "gen_snapshot_cross_artifact_path",
    "host_artifacts_path",
    "ios_engine_artifact_path",
)
load("//flutter/private:versions.bzl", "ARTIFACT_CHECKSUMS", "FLUTTER_VERSIONS", "flutter_artifact_sha256", "flutter_source_sha256")

def _latest_version_first_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "3.41.2", FLUTTER_VERSIONS.keys()[0])
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
    for android_arch in ["arm64", "x64"]:
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
            flutter_artifact_sha256(version, path)
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

def _artifact_sha256_returns_recorded_value_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ARTIFACT_CHECKSUMS["3.47.5"]["linux-x64/artifacts.zip"],
        flutter_artifact_sha256("3.47.5", "linux-x64/artifacts.zip"),
    )
    return unittest.end(env)

def _artifact_checksum_probe_impl(ctx):
    sha = flutter_artifact_sha256(ctx.attr.flutter_version, ctx.attr.artifact_path)
    out = ctx.actions.declare_file(ctx.label.name + ".sha256")
    ctx.actions.write(out, sha)
    return [DefaultInfo(files = depset([out]))]

_artifact_checksum_probe = rule(
    implementation = _artifact_checksum_probe_impl,
    attrs = {
        "flutter_version": attr.string(mandatory = True),
        "artifact_path": attr.string(mandatory = True),
    },
)

def _source_checksum_probe_impl(ctx):
    sha = flutter_source_sha256(
        ctx.attr.flutter_version,
        versions = {
            ctx.attr.flutter_version: struct(engine_revision = "0" * 40),
        },
    )
    out = ctx.actions.declare_file(ctx.label.name + ".sha256")
    ctx.actions.write(out, sha)
    return [DefaultInfo(files = depset([out]))]

_source_checksum_probe = rule(
    implementation = _source_checksum_probe_impl,
    attrs = {
        "flutter_version": attr.string(mandatory = True),
    },
)

def _expect_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_substrings": attr.string_list(mandatory = True),
    },
)

_t0_test = unittest.make(_latest_version_first_test_impl)
_t1_test = unittest.make(_engine_revision_format_test_impl)
_t2_test = unittest.make(_checksums_exist_for_all_versions_test_impl)
_t3_test = unittest.make(_checksums_have_key_artifacts_test_impl)
_t4_test = unittest.make(_checksums_are_sha256_test_impl)
_t5_test = unittest.make(_source_sha256_recorded_for_all_versions_test_impl)
_t6_test = unittest.make(_every_download_is_checksummed_test_impl)
_t7_test = unittest.make(_artifact_sha256_returns_recorded_value_test_impl)

def versions_test_suite(name):
    _artifact_checksum_probe(
        name = name + "_missing_artifact_probe",
        flutter_version = "3.47.5",
        artifact_path = "missing/artifact.zip",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_missing_artifact_fails",
        target_under_test = ":" + name + "_missing_artifact_probe",
        expected_substrings = [
            "No sha256 recorded for missing/artifact.zip in Flutter 3.47.5",
            "missing/artifact.zip",
            "3.47.5",
        ],
    )

    _artifact_checksum_probe(
        name = name + "_missing_version_probe",
        flutter_version = "9.99.9",
        artifact_path = "linux-x64/artifacts.zip",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_missing_version_fails",
        target_under_test = ":" + name + "_missing_version_probe",
        expected_substrings = [
            "No sha256 recorded for linux-x64/artifacts.zip in Flutter 9.99.9",
            "linux-x64/artifacts.zip",
            "9.99.9",
        ],
    )

    _source_checksum_probe(
        name = name + "_missing_source_sha_probe",
        flutter_version = "9.99.9",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_missing_source_sha_fails",
        target_under_test = ":" + name + "_missing_source_sha_probe",
        expected_substrings = [
            "No source tarball checksum recorded for Flutter 9.99.9",
            "9.99.9",
        ],
    )

    unittest.suite(
        name + "_unit",
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_missing_artifact_fails",
            ":" + name + "_missing_version_fails",
            ":" + name + "_missing_source_sha_fails",
        ],
    )
