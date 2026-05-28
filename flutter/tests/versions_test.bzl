"""Unit tests for versions.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:versions.bzl", "ARTIFACT_CHECKSUMS", "FLUTTER_VERSIONS")

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

_t0_test = unittest.make(_latest_version_first_test_impl)
_t1_test = unittest.make(_engine_revision_format_test_impl)
_t2_test = unittest.make(_checksums_exist_for_all_versions_test_impl)
_t3_test = unittest.make(_checksums_have_key_artifacts_test_impl)
_t4_test = unittest.make(_checksums_are_sha256_test_impl)

def versions_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test)
