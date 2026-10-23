"""Unit tests for artifact_urls.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:artifact_urls.bzl",
    "dart_sdk_artifact_path",
    "desktop_engine_artifact_path",
    "engine_artifact_url",
    "flutter_source_tarball_url",
    "gen_snapshot_cross_artifact_path",
    "host_artifacts_path",
    "source_strip_prefix",
)

def _engine_artifact_url_test_impl(ctx):
    env = unittest.begin(ctx)
    url = engine_artifact_url(
        "abc123def456abc123def456abc123def456abc1",
        "flutter_patched_sdk.zip",
    )
    asserts.equals(
        env,
        "https://storage.googleapis.com/flutter_infra_release/flutter/abc123def456abc123def456abc123def456abc1/flutter_patched_sdk.zip",
        url,
    )
    return unittest.end(env)

def _dart_sdk_artifact_path_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "dart-sdk-darwin-arm64.zip", dart_sdk_artifact_path("darwin-arm64"))
    asserts.equals(env, "dart-sdk-linux-x64.zip", dart_sdk_artifact_path("linux-x64"))
    asserts.equals(env, "dart-sdk-windows-x64.zip", dart_sdk_artifact_path("windows-x64"))
    return unittest.end(env)

def _gen_snapshot_path_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "android-arm64-release/darwin-x64.zip",
        gen_snapshot_cross_artifact_path("android-arm64", "release", "darwin-x64"),
    )
    asserts.equals(
        env,
        "ios-profile/linux-x64.zip",
        gen_snapshot_cross_artifact_path("ios", "profile", "linux-x64"),
    )
    return unittest.end(env)

def _host_artifacts_path_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "darwin-x64/artifacts.zip", host_artifacts_path("darwin-x64"))
    asserts.equals(env, "linux-x64/artifacts.zip", host_artifacts_path("linux-x64"))
    return unittest.end(env)

def _desktop_engine_artifact_path_test_impl(ctx):
    env = unittest.begin(ctx)

    # macOS release
    asserts.equals(
        env,
        "darwin-x64-release/FlutterMacOS.framework.zip",
        desktop_engine_artifact_path("macos", "x64", "release"),
    )

    # macOS debug (no suffix)
    asserts.equals(
        env,
        "darwin-x64/FlutterMacOS.framework.zip",
        desktop_engine_artifact_path("macos", "x64", "debug"),
    )

    # Linux release
    asserts.equals(
        env,
        "linux-x64-release/linux-x64-flutter-gtk.zip",
        desktop_engine_artifact_path("linux", "x64", "release"),
    )

    # Windows profile
    asserts.equals(
        env,
        "windows-x64-profile/windows-x64-flutter.zip",
        desktop_engine_artifact_path("windows", "x64", "profile"),
    )

    # Unknown OS returns None
    asserts.equals(env, None, desktop_engine_artifact_path("fuchsia", "x64", "release"))

    return unittest.end(env)

_t0_test = unittest.make(_engine_artifact_url_test_impl)
_t1_test = unittest.make(_dart_sdk_artifact_path_test_impl)
_t2_test = unittest.make(_gen_snapshot_path_test_impl)
_t3_test = unittest.make(_host_artifacts_path_test_impl)
_t4_test = unittest.make(_desktop_engine_artifact_path_test_impl)

def _engine_artifact_url_base_override_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "https://eng.example.com/abc123/flutter_patched_sdk.zip",
        engine_artifact_url("abc123", "flutter_patched_sdk.zip", "https://eng.example.com"),
    )
    asserts.equals(
        env,
        "https://storage.googleapis.com/flutter_infra_release/flutter/abc123/flutter_patched_sdk.zip",
        engine_artifact_url("abc123", "flutter_patched_sdk.zip", ""),
    )
    return unittest.end(env)

def _source_tarball_url_override_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "https://github.com/flutter/flutter/archive/refs/tags/3.47.7.tar.gz",
        flutter_source_tarball_url("3.47.7"),
    )
    asserts.equals(
        env,
        "https://eng.example.com/flutter-3.47.70.tar.gz",
        flutter_source_tarball_url("3.47.70", "https://eng.example.com/flutter-3.47.70.tar.gz"),
    )
    return unittest.end(env)

def _source_strip_prefix_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "flutter-3.47.7/", source_strip_prefix("3.47.7"))
    asserts.equals(
        env,
        "flutter-3.47.7/",
        source_strip_prefix("3.47.70", "https://github.com/flutter/flutter/archive/refs/tags/3.47.7.tar.gz"),
    )
    asserts.equals(
        env,
        "flutter-3.47.70/",
        source_strip_prefix("3.47.70", "https://eng.example.com/flutter-3.47.70.tar.gz"),
    )
    return unittest.end(env)

_t5_test = unittest.make(_engine_artifact_url_base_override_test_impl)
_t6_test = unittest.make(_source_tarball_url_override_test_impl)
_t7_test = unittest.make(_source_strip_prefix_test_impl)

def artifact_urls_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test)
