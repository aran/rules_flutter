"""Every byte rules_flutter downloads has a pinned digest in the tables.

The property: for every pinned Flutter version, every archive the repository
rules fetch (engine artifacts for each host, cross target, desktop target,
build mode and ABI; the framework source tarball; the Linux sysroot) has a
recorded sha256 that is exactly 64 lowercase hex characters, and so does each
host's Chrome for Testing archive.

Why this form. `versions_test.bzl` checks the tables against a list of paths
written out in the test, so a download added to a repository rule but not to
that list is invisible to it. This test instead walks the same tables
`flutter_register_toolchains` iterates (`HOST_PLATFORMS`,
`CROSS_COMPILATION_PAIRS`, `DESKTOP_CROSS_PAIRS`, `ENGINE_MODES`) and builds each
path with the helpers the rules use, so the set of downloads grows when those
tables do. It also checks the digest's *shape*: Bazel treats a digest it cannot
parse as an error, but a table entry that is blank or has the wrong case would
have to be caught here before any fetch.

What it cannot see is whether a repository rule *uses* the digest it is given.
That is `//tools/download_guard` (the sources) and the fetch tests in
`tools/dev_tool/test/e2e/digest_*` (the behaviour).
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:artifact_urls.bzl",
    "android_emulator_url",
    "android_engine_artifact_path",
    "android_system_image_url",
    "chrome_for_testing_url",
    "cpp_client_wrapper_artifact_path",
    "dart_sdk_artifact_path",
    "desktop_engine_artifact_path",
    "engine_artifact_url",
    "flutter_source_tarball_url",
    "gen_snapshot_cross_artifact_path",
    "host_artifacts_path",
    "ios_engine_artifact_path",
    "ios_usb_dependency_url",
)
load(
    "//flutter/private:engine_helpers.bzl",
    "ENGINE_MODES",
    "PLATFORM_PREFIX_TO_OS",
    "engine_arch_for_os",
    "gen_snapshot_host_platform",
)
load("//flutter/private:flutter_linux_runtime_repo.bzl", "debian_package_urls")
load("//flutter/private:linux_runtime_pins.bzl", "LINUX_RUNTIME")
load("//flutter/private:pinned.bzl", "digest_problem")
load(
    "//flutter/private:toolchains_repo.bzl",
    "CROSS_COMPILATION_PAIRS",
    "DESKTOP_CROSS_PAIRS",
    "HOST_PLATFORMS",
)
load(
    "//flutter/private:versions.bzl",
    "ANDROID_EMULATOR",
    "ANDROID_SYSTEM_IMAGE",
    "ARTIFACT_CHECKSUMS",
    "CHROME_FOR_TESTING",
    "FLUTTER_VERSIONS",
    "IOS_USB_DEPENDENCIES",
    "LINUX_SYSROOT_CHECKSUMS",
)

def _is_sha256(value):
    """True for what the repository rules accept as a pinned digest."""
    return digest_problem(value) == None

def _engine_artifact_paths():
    """Every engine artifact path some repository rule downloads, per tables.

    Mirrors what `flutter_register_toolchains` declares, walking its tables
    rather than a hand-kept list.
    """
    paths = {}

    # Host repos (flutter_engine_artifacts) and their profile repos.
    for platform in HOST_PLATFORMS.keys():
        os_name = PLATFORM_PREFIX_TO_OS[platform.split("-")[0]]
        engine_arch = engine_arch_for_os(os_name, platform.split("-")[1])
        paths[dart_sdk_artifact_path(platform)] = "host Dart SDK of " + platform
        paths[host_artifacts_path(platform)] = "host tools of " + platform
        paths["{}/font-subset.zip".format(platform)] = "font-subset tools of " + platform
        if os_name == "macos":
            for mode in ["release", "profile"]:
                paths[host_artifacts_path(platform, mode = mode)] = "{} host tools of {}".format(mode, platform)
        for mode in ENGINE_MODES:
            paths[desktop_engine_artifact_path(os_name, engine_arch, mode)] = "{} engine of {}".format(mode, platform)
        if os_name == "windows":
            paths[cpp_client_wrapper_artifact_path(platform)] = "C++ client wrapper of " + platform

    paths["flutter_patched_sdk.zip"] = "patched SDK"
    paths["flutter_patched_sdk_product.zip"] = "product patched SDK"
    paths["material_fonts.zip"] = "Material fonts"
    paths["sky_engine.zip"] = "sky_engine"
    paths["flutter-web-sdk.zip"] = "web SDK"

    # Desktop cross-compilation engines, one per target and mode.
    for targets in DESKTOP_CROSS_PAIRS.values():
        for target in targets:
            os_name = PLATFORM_PREFIX_TO_OS[target.split("-")[0]]
            engine_arch = engine_arch_for_os(os_name, target.split("-")[1])
            for mode in ENGINE_MODES:
                paths[desktop_engine_artifact_path(os_name, engine_arch, mode)] = "{} engine for {}".format(mode, target)
            if os_name == "windows":
                paths[cpp_client_wrapper_artifact_path(target)] = "C++ client wrapper for " + target

    # Mobile cross targets: gen_snapshot per host, and the engines.
    for host, targets in CROSS_COMPILATION_PAIRS.items():
        for target in targets:
            if target.startswith("android-"):
                for mode in ["release", "profile"]:
                    path = gen_snapshot_cross_artifact_path(target, mode, gen_snapshot_host_platform(host))
                    paths[path] = "{} gen_snapshot for {} on {}".format(mode, target, host)
                arch = target.split("-")[1]
                for mode in ENGINE_MODES:
                    paths[android_engine_artifact_path(arch, mode)] = "{} Android engine for {}".format(mode, target)
            elif target.startswith("ios"):
                for mode in ENGINE_MODES:
                    paths[ios_engine_artifact_path(mode)] = "{} iOS engine".format(mode)
    return paths

def _every_derived_download_has_a_digest_test_impl(ctx):
    env = unittest.begin(ctx)
    paths = _engine_artifact_paths()
    asserts.true(env, len(paths) > 40, "the walk found only {} downloads; it has lost a table".format(len(paths)))
    for version, meta in FLUTTER_VERSIONS.items():
        checksums = ARTIFACT_CHECKSUMS.get(version, {})
        for path, what in paths.items():
            url = engine_artifact_url(meta.engine_revision, path)
            asserts.true(
                env,
                _is_sha256(checksums.get(path)),
                ("Flutter {}: no valid sha256 for the {} ({}); a fetch of it would be unverified. " +
                 "Run `bazel run //tools/update_flutter_version -- {}`").format(version, what, url, version),
            )
    return unittest.end(env)

def _no_stray_or_blank_table_entries_test_impl(ctx):
    # A blank or oddly cased entry is a digest the rules would pass on as-is.
    env = unittest.begin(ctx)
    for version, checksums in ARTIFACT_CHECKSUMS.items():
        for path, digest in checksums.items():
            asserts.true(
                env,
                _is_sha256(digest),
                "ARTIFACT_CHECKSUMS[{}][{}] = {} is not 64 lowercase hex characters".format(version, path, repr(digest)),
            )
    return unittest.end(env)

def _source_tarball_and_sysroot_digests_test_impl(ctx):
    env = unittest.begin(ctx)
    for version, meta in FLUTTER_VERSIONS.items():
        asserts.true(
            env,
            _is_sha256(getattr(meta, "source_sha256", None)),
            "Flutter {}: source_sha256 for {} is not 64 lowercase hex characters".format(
                version,
                flutter_source_tarball_url(version),
            ),
        )
    for deb_arch, digest in LINUX_SYSROOT_CHECKSUMS.items():
        asserts.true(
            env,
            _is_sha256(digest),
            "LINUX_SYSROOT_CHECKSUMS[{}] is not 64 lowercase hex characters".format(deb_arch),
        )
    return unittest.end(env)

def _every_version_has_a_table_test_impl(ctx):
    # `ARTIFACT_CHECKSUMS.get(version, {})` is how the rules read the table, so
    # a version missing from it gives every download a blank digest.
    env = unittest.begin(ctx)
    for version in FLUTTER_VERSIONS.keys():
        asserts.true(env, version in ARTIFACT_CHECKSUMS, "no ARTIFACT_CHECKSUMS table for Flutter " + version)
    for version in ARTIFACT_CHECKSUMS.keys():
        asserts.true(env, version in FLUTTER_VERSIONS, "ARTIFACT_CHECKSUMS has a table for unknown Flutter " + version)
    return unittest.end(env)

def _chrome_for_testing_digests_test_impl(ctx):
    # The runtime web integration tests run in: one archive per host it exists
    # for, fetched only when a test needs it, and pinned like everything else.
    env = unittest.begin(ctx)
    asserts.true(env, CHROME_FOR_TESTING.version, "CHROME_FOR_TESTING has no version")
    asserts.true(env, len(CHROME_FOR_TESTING.sha256) > 0, "CHROME_FOR_TESTING pins no host")
    for platform, digest in CHROME_FOR_TESTING.sha256.items():
        asserts.true(
            env,
            _is_sha256(digest),
            ("CHROME_FOR_TESTING.sha256[{}] is not 64 lowercase hex characters; a fetch of {} would be unverified. " +
             "Run `bazel run //tools/update_chrome_for_testing`").format(
                platform,
                chrome_for_testing_url(CHROME_FOR_TESTING.version, platform),
            ),
        )
    return unittest.end(env)

def _linux_runtime_digests_test_impl(ctx):
    # The runtime Linux integration tests run with: each architecture's Debian
    # packages, pinned like everything else, at one snapshot, held to one floor.
    env = unittest.begin(ctx)
    asserts.true(env, LINUX_RUNTIME.snapshot, "LINUX_RUNTIME has no snapshot")
    asserts.true(env, len(LINUX_RUNTIME.floor) > 0, "LINUX_RUNTIME has no floor")
    asserts.equals(env, ["amd64", "arm64"], sorted(LINUX_RUNTIME.packages.keys()))
    for arch, packages in LINUX_RUNTIME.packages.items():
        asserts.true(env, len(packages) > 0, "LINUX_RUNTIME pins no package for " + arch)
        for name, _, path, digest in packages:
            asserts.true(
                env,
                _is_sha256(digest),
                ("LINUX_RUNTIME's {} for {} is pinned with a digest that is not 64 lowercase hex " +
                 "characters; a fetch of {} would be unverified. Run `bazel run //tools/update_linux_runtime`").format(
                    name,
                    arch,
                    debian_package_urls(LINUX_RUNTIME.snapshot, path)[0],
                ),
            )
    return unittest.end(env)

_t0_test = unittest.make(_every_derived_download_has_a_digest_test_impl)
_t1_test = unittest.make(_no_stray_or_blank_table_entries_test_impl)
_t2_test = unittest.make(_source_tarball_and_sysroot_digests_test_impl)
_t3_test = unittest.make(_every_version_has_a_table_test_impl)

def _android_emulator_digests_test_impl(ctx):
    # What Android integration tests run on by default: the emulator of each
    # host it is pinned for and the system image of each ABI, fetched only when
    # a test runs on the emulator, and pinned like everything else.
    env = unittest.begin(ctx)
    asserts.equals(env, ["darwin_aarch64", "linux_x64"], sorted(ANDROID_EMULATOR.sha256.keys()))
    asserts.equals(env, ["arm64-v8a", "x86_64"], sorted(ANDROID_SYSTEM_IMAGE.sha256.keys()))
    for host, digest in ANDROID_EMULATOR.sha256.items():
        asserts.true(
            env,
            _is_sha256(digest),
            "ANDROID_EMULATOR.sha256[{}] is not 64 lowercase hex characters; a fetch of {} would be unverified.".format(
                host,
                android_emulator_url(ANDROID_EMULATOR.build_id, host),
            ),
        )
    for abi, digest in ANDROID_SYSTEM_IMAGE.sha256.items():
        asserts.true(
            env,
            _is_sha256(digest),
            "ANDROID_SYSTEM_IMAGE.sha256[{}] is not 64 lowercase hex characters; a fetch of {} would be unverified.".format(
                abi,
                android_system_image_url(ANDROID_SYSTEM_IMAGE.api_level, ANDROID_SYSTEM_IMAGE.tag, abi, ANDROID_SYSTEM_IMAGE.revision),
            ),
        )
    return unittest.end(env)

def _ios_usb_digests_test_impl(ctx):
    # The iproxy the dev tool forwards a wired iPhone's VM service through, and
    # the libraries it loads: the three archives its repository extracts.
    env = unittest.begin(ctx)
    asserts.equals(env, ["libimobiledeviceglue", "libplist", "libusbmuxd"], sorted(IOS_USB_DEPENDENCIES.keys()))
    for name, pin in IOS_USB_DEPENDENCIES.items():
        asserts.true(env, pin.version, "IOS_USB_DEPENDENCIES[{}] has no version".format(name))
        asserts.true(
            env,
            _is_sha256(pin.sha256),
            ("IOS_USB_DEPENDENCIES[{}].sha256 is not 64 lowercase hex characters; a fetch of {} would be " +
             "unverified. Run `bazel run //tools/update_flutter_version -- <version>`").format(
                name,
                ios_usb_dependency_url(name, pin.version),
            ),
        )
    return unittest.end(env)

_t4_test = unittest.make(_chrome_for_testing_digests_test_impl)
_t5_test = unittest.make(_linux_runtime_digests_test_impl)
_t6_test = unittest.make(_android_emulator_digests_test_impl)
_t7_test = unittest.make(_ios_usb_digests_test_impl)

def download_digests_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test)
