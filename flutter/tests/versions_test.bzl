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
load("//flutter/private:versions.bzl", "ARTIFACT_CHECKSUMS", "FLUTTER_VERSIONS", "custom_engine_base_url", "custom_source_url", "flutter_artifact_sha256", "flutter_source_sha256", "merge_custom_versions")

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

def _custom_tag(version = "3.47.70", is_root = True, engine_revision = "0" * 40, source_url = "", engine_base_url = ""):
    return struct(
        version = version,
        engine_revision = engine_revision,
        source_sha256 = "1" * 64,
        material_fonts_url = "flutter_infra_release/flutter/fonts/0/fonts.zip",
        artifact_sha256 = {"linux-x64/artifacts.zip": "2" * 64},
        engine_base_url = engine_base_url,
        source_url = source_url,
        is_root = is_root,
    )

def _merge_empty_tags_test_impl(ctx):
    env = unittest.begin(ctx)
    merged = merge_custom_versions([])
    asserts.equals(env, FLUTTER_VERSIONS.keys(), merged.versions.keys())
    asserts.equals(env, {}, merged.source_urls)
    asserts.equals(env, {}, merged.engine_base_urls)
    asserts.equals(env, "", custom_source_url("3.47.7", merged.source_urls))
    asserts.equals(env, "", custom_engine_base_url("3.47.7", merged.engine_base_urls))
    return unittest.end(env)

def _merge_custom_version_test_impl(ctx):
    env = unittest.begin(ctx)
    merged = merge_custom_versions([_custom_tag(
        source_url = "",
        engine_base_url = "",
    )])
    asserts.true(env, "3.47.70" in merged.versions)
    asserts.equals(env, "0" * 40, merged.versions["3.47.70"].engine_revision)
    asserts.equals(
        env,
        "1" * 64,
        flutter_source_sha256("3.47.70", merged.versions),
    )
    asserts.equals(
        env,
        "2" * 64,
        flutter_artifact_sha256("3.47.70", "linux-x64/artifacts.zip", merged.checksums),
    )

    # The stock tables are untouched by the merge.
    asserts.true(env, "3.47.70" not in FLUTTER_VERSIONS)
    asserts.equals(env, "3.47.7", FLUTTER_VERSIONS.keys()[-1])
    return unittest.end(env)

def _merge_custom_urls_test_impl(ctx):
    env = unittest.begin(ctx)
    merged = merge_custom_versions([struct(
        version = "3.47.70",
        engine_revision = "0" * 40,
        source_sha256 = "1" * 64,
        material_fonts_url = "flutter_infra_release/flutter/fonts/0/fonts.zip",
        artifact_sha256 = {},
        engine_base_url = "https://eng.example.com",
        source_url = "https://eng.example.com/flutter-3.47.70.tar.gz",
        is_root = True,
    )])
    asserts.equals(
        env,
        "https://eng.example.com/flutter-3.47.70.tar.gz",
        custom_source_url("3.47.70", merged.source_urls),
    )
    asserts.equals(
        env,
        "https://eng.example.com",
        custom_engine_base_url("3.47.70", merged.engine_base_urls),
    )
    return unittest.end(env)

_t8_test = unittest.make(_merge_empty_tags_test_impl)
_t9_test = unittest.make(_merge_custom_version_test_impl)
_t10_test = unittest.make(_merge_custom_urls_test_impl)

def _merge_probe_impl(ctx):
    merge_custom_versions([struct(
        version = ctx.attr.version,
        engine_revision = ctx.attr.engine_revision,
        source_sha256 = ctx.attr.source_sha256,
        material_fonts_url = ctx.attr.material_fonts_url,
        artifact_sha256 = {},
        engine_base_url = "",
        source_url = "",
        is_root = ctx.attr.is_root,
    )])
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "ok")
    return [DefaultInfo(files = depset([out]))]

_merge_probe = rule(
    implementation = _merge_probe_impl,
    attrs = {
        "version": attr.string(default = "3.47.70"),
        "engine_revision": attr.string(default = "0" * 40),
        "source_sha256": attr.string(default = "1" * 64),
        "material_fonts_url": attr.string(default = "flutter_infra_release/flutter/fonts/0/fonts.zip"),
        "is_root": attr.bool(default = True),
    },
)

def _custom_missing_checksum_probe_impl(ctx):
    merged = merge_custom_versions([_custom_tag(version = ctx.attr.version)])
    sha = flutter_artifact_sha256(ctx.attr.version, ctx.attr.artifact_path, merged.checksums)
    out = ctx.actions.declare_file(ctx.label.name + ".sha256")
    ctx.actions.write(out, sha)
    return [DefaultInfo(files = depset([out]))]

_custom_missing_checksum_probe = rule(
    implementation = _custom_missing_checksum_probe_impl,
    attrs = {
        "version": attr.string(default = "3.47.70"),
        "artifact_path": attr.string(default = "missing/artifact.zip"),
    },
)

def _merge_acme_sky_engine_test_impl(ctx):
    env = unittest.begin(ctx)
    merged = merge_custom_versions([struct(
        version = "3.44.1-acme",
        engine_revision = "0" * 40,
        source_sha256 = "1" * 64,
        material_fonts_url = "flutter_infra_release/flutter/fonts/0/fonts.zip",
        artifact_sha256 = {"sky_engine.zip": "3" * 64},
        engine_base_url = "",
        source_url = "",
        is_root = True,
    )])
    asserts.equals(
        env,
        "3" * 64,
        flutter_artifact_sha256("3.44.1-acme", "sky_engine.zip", merged.checksums),
    )
    return unittest.end(env)

_merge_acme_sky_engine_test = unittest.make(_merge_acme_sky_engine_test_impl)

_t11_test = _merge_acme_sky_engine_test

def versions_test_suite(name):
    """Defines unit and analysis tests for `versions.bzl` and artifact SHA-256 verification.

    Args:
      name: The test_suite target name.
    """
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

    _merge_probe(
        name = name + "_merge_nonroot_probe",
        is_root = False,
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_merge_nonroot_fails",
        target_under_test = ":" + name + "_merge_nonroot_probe",
        expected_substrings = ["Only the root module may register a custom Flutter version"],
    )

    _merge_probe(
        name = name + "_merge_duplicate_probe",
        version = "3.47.7",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_merge_duplicate_fails",
        target_under_test = ":" + name + "_merge_duplicate_probe",
        expected_substrings = ["already listed"],
    )

    _merge_probe(
        name = name + "_merge_missing_field_probe",
        engine_revision = "",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_merge_missing_field_fails",
        target_under_test = ":" + name + "_merge_missing_field_probe",
        expected_substrings = ["missing a required field"],
    )

    _custom_missing_checksum_probe(
        name = name + "_custom_missing_checksum_probe",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_custom_missing_checksum_fails",
        target_under_test = ":" + name + "_custom_missing_checksum_probe",
        expected_substrings = [
            "No sha256 recorded for missing/artifact.zip in Flutter 3.47.70",
            "missing/artifact.zip",
            "3.47.70",
            "that tag's artifact_sha256 in the root module",
        ],
    )

    _custom_missing_checksum_probe(
        name = name + "_acme_missing_sky_probe",
        version = "3.44.1-acme",
        artifact_path = "sky_engine.zip",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_acme_missing_sky_fails",
        target_under_test = ":" + name + "_acme_missing_sky_probe",
        expected_substrings = [
            "No sha256 recorded for sky_engine.zip in Flutter 3.44.1-acme",
            "sky_engine.zip",
            "3.44.1-acme",
            "that tag's artifact_sha256 in the root module",
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
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_missing_artifact_fails",
            ":" + name + "_missing_version_fails",
            ":" + name + "_missing_source_sha_fails",
            ":" + name + "_merge_nonroot_fails",
            ":" + name + "_merge_duplicate_fails",
            ":" + name + "_merge_missing_field_fails",
            ":" + name + "_custom_missing_checksum_fails",
            ":" + name + "_acme_missing_sky_fails",
        ],
    )
