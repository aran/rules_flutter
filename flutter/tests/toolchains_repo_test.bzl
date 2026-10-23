"""Unit and analysis tests for toolchains_repo.bzl and Apple AOT gen_snapshot wiring."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:repositories.bzl", "resolve_aot_gen_snapshot")
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_macho_action")
load("//flutter/private:flutter_aot_target.bzl", "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_cross_repo.bzl", "generate_cross_repo_build")
load(
    "//flutter/private:toolchains_repo.bzl",
    "AOT_CROSS_COMPILATION_PAIRS",
    "CROSS_COMPILATION_PAIRS",
    "DESKTOP_CROSS_PAIRS",
    "HOST_PLATFORMS",
    "TARGET_PLATFORMS",
    "generate_toolchains_build",
    "supports_aot_cross_compilation",
)
load(
    "//flutter/private:xtool_darwin_sdk_repo.bzl",
    "XTOOL_DARWIN_TARGETS",
    "generate_xtool_darwin_sdk_build",
    "render_xtool_wrapper_scripts",
    "resolve_darwin_artifactbundle_sdk_paths",
    "resolve_darwin_sdk_from_modules",
    "validate_darwin_sdk_config",
)
load("//flutter/settings:apple_backend.bzl", "APPLE_BACKEND_VALUES")

def _desktop_cross_pairs_keys_are_host_platforms_test_impl(ctx):
    """Every key in DESKTOP_CROSS_PAIRS must be a valid HOST_PLATFORMS key."""
    env = unittest.begin(ctx)
    for host in DESKTOP_CROSS_PAIRS.keys():
        asserts.true(
            env,
            host in HOST_PLATFORMS,
            "DESKTOP_CROSS_PAIRS key '{}' is not in HOST_PLATFORMS".format(host),
        )
    return unittest.end(env)

def _desktop_cross_pairs_targets_are_host_platforms_test_impl(ctx):
    """Every target in DESKTOP_CROSS_PAIRS must be a valid HOST_PLATFORMS key."""
    env = unittest.begin(ctx)
    for host, targets in DESKTOP_CROSS_PAIRS.items():
        for target in targets:
            asserts.true(
                env,
                target in HOST_PLATFORMS,
                "DESKTOP_CROSS_PAIRS[{}] target '{}' is not in HOST_PLATFORMS".format(host, target),
            )
    return unittest.end(env)

def _desktop_cross_pairs_no_self_pairs_test_impl(ctx):
    """No host should target itself in DESKTOP_CROSS_PAIRS."""
    env = unittest.begin(ctx)
    for host, targets in DESKTOP_CROSS_PAIRS.items():
        asserts.true(
            env,
            host not in targets,
            "DESKTOP_CROSS_PAIRS[{}] contains self-pair".format(host),
        )
    return unittest.end(env)

def _desktop_cross_pairs_no_same_os_test_impl(ctx):
    """No host should target a platform with the same OS (e.g. darwin-arm64 → darwin-x64)."""
    env = unittest.begin(ctx)
    for host, targets in DESKTOP_CROSS_PAIRS.items():
        host_os = HOST_PLATFORMS[host].os
        for target in targets:
            target_os = HOST_PLATFORMS[target].os
            asserts.true(
                env,
                host_os != target_os,
                "DESKTOP_CROSS_PAIRS[{}] targets same-OS platform '{}' (both {})".format(host, target, host_os),
            )
    return unittest.end(env)

def _desktop_cross_pairs_all_hosts_covered_test_impl(ctx):
    """Every HOST_PLATFORMS entry should have a DESKTOP_CROSS_PAIRS entry."""
    env = unittest.begin(ctx)
    for host in HOST_PLATFORMS.keys():
        asserts.true(
            env,
            host in DESKTOP_CROSS_PAIRS,
            "HOST_PLATFORMS key '{}' missing from DESKTOP_CROSS_PAIRS".format(host),
        )
    return unittest.end(env)

def _cross_compilation_pairs_valid_test_impl(ctx):
    """Every (host, target) in CROSS_COMPILATION_PAIRS must reference valid platforms and wire the right gen_snapshot."""
    env = unittest.begin(ctx)
    for host, targets in CROSS_COMPILATION_PAIRS.items():
        asserts.true(
            env,
            host in HOST_PLATFORMS,
            "CROSS_COMPILATION_PAIRS key '{}' is not in HOST_PLATFORMS".format(host),
        )
        for target in targets:
            asserts.true(
                env,
                target in TARGET_PLATFORMS,
                "CROSS_COMPILATION_PAIRS[{}] target '{}' is not in TARGET_PLATFORMS".format(host, target),
            )
            aot = resolve_aot_gen_snapshot("flutter", host, target)
            if target.startswith("android-"):
                asserts.true(
                    env,
                    supports_aot_cross_compilation(host, target),
                    "{} -> {} must support AOT cross-compilation".format(host, target),
                )
                asserts.equals(
                    env,
                    "@flutter_cross_{}_{}//:gen_snapshot".format(host, target),
                    aot.release,
                )
                asserts.equals(
                    env,
                    "@flutter_cross_{}_{}_profile//:gen_snapshot".format(host, target),
                    aot.profile,
                )
            elif target == "ios-arm64" and host.startswith("darwin-"):
                asserts.true(env, supports_aot_cross_compilation(host, target))
                asserts.equals(env, "@flutter_ios_engine//:gen_snapshot_arm64", aot.release)
                asserts.equals(env, "@flutter_ios_engine_profile//:gen_snapshot_arm64", aot.profile)
            elif target == "ios-x64" and host.startswith("darwin-"):
                asserts.true(env, supports_aot_cross_compilation(host, target))
                asserts.equals(
                    env,
                    "@flutter_host_tools_release_darwin-x64//:host-tools-release/gen_snapshot",
                    aot.release,
                )
                asserts.equals(
                    env,
                    "@flutter_darwin-x64_profile//:host-tools/gen_snapshot",
                    aot.profile,
                )
            else:
                asserts.false(
                    env,
                    supports_aot_cross_compilation(host, target),
                    "{} -> {} must NOT register an AOT cross toolchain".format(host, target),
                )
                asserts.equals(
                    env,
                    None,
                    aot,
                    "{} -> {} must have no AOT gen_snapshot wired".format(host, target),
                )

    for linux_host in ("linux-x64", "linux-arm64"):
        asserts.true(
            env,
            "ios-arm64" in CROSS_COMPILATION_PAIRS[linux_host],
            "{} must support ios-arm64 debug/JIT in CROSS_COMPILATION_PAIRS".format(linux_host),
        )
        asserts.true(
            env,
            "ios-x64" in CROSS_COMPILATION_PAIRS[linux_host],
            "{} must support ios-x64 debug/JIT in CROSS_COMPILATION_PAIRS".format(linux_host),
        )
        asserts.false(
            env,
            "ios-arm64" in AOT_CROSS_COMPILATION_PAIRS[linux_host],
            "{} must NOT support ios-arm64 AOT in AOT_CROSS_COMPILATION_PAIRS".format(linux_host),
        )
        asserts.false(
            env,
            "ios-x64" in AOT_CROSS_COMPILATION_PAIRS[linux_host],
            "{} must NOT support ios-x64 AOT in AOT_CROSS_COMPILATION_PAIRS".format(linux_host),
        )
        asserts.true(
            env,
            "darwin-arm64" in DESKTOP_CROSS_PAIRS[linux_host],
            "{} must support darwin-arm64 debug/JIT in DESKTOP_CROSS_PAIRS".format(linux_host),
        )
        asserts.true(
            env,
            "darwin-x64" in DESKTOP_CROSS_PAIRS[linux_host],
            "{} must support darwin-x64 debug/JIT in DESKTOP_CROSS_PAIRS".format(linux_host),
        )
    return unittest.end(env)

def _apple_aot_matrix_by_host_target_mode_test_impl(ctx):
    """Per (host OS, Apple target, mode), asserts which Darwin gen_snapshot repo is wired or that the pair is unavailable."""
    env = unittest.begin(ctx)

    apple_targets = ["ios-arm64", "ios-x64", "darwin-arm64", "darwin-x64"]

    expected_apple_aot = {
        ("darwin-arm64", "darwin-arm64"): struct(
            release = "@flutter_host_tools_release_darwin-arm64//:host-tools-release/gen_snapshot",
            profile = "@flutter_darwin-arm64_profile//:host-tools/gen_snapshot",
        ),
        ("darwin-x64", "darwin-x64"): struct(
            release = "@flutter_host_tools_release_darwin-x64//:host-tools-release/gen_snapshot",
            profile = "@flutter_darwin-x64_profile//:host-tools/gen_snapshot",
        ),
        ("darwin-arm64", "ios-arm64"): struct(
            release = "@flutter_ios_engine//:gen_snapshot_arm64",
            profile = "@flutter_ios_engine_profile//:gen_snapshot_arm64",
        ),
        ("darwin-x64", "ios-arm64"): struct(
            release = "@flutter_ios_engine//:gen_snapshot_arm64",
            profile = "@flutter_ios_engine_profile//:gen_snapshot_arm64",
        ),
        ("darwin-arm64", "ios-x64"): struct(
            release = "@flutter_host_tools_release_darwin-x64//:host-tools-release/gen_snapshot",
            profile = "@flutter_darwin-x64_profile//:host-tools/gen_snapshot",
        ),
        ("darwin-x64", "ios-x64"): struct(
            release = "@flutter_host_tools_release_darwin-x64//:host-tools-release/gen_snapshot",
            profile = "@flutter_darwin-x64_profile//:host-tools/gen_snapshot",
        ),
    }

    for host in HOST_PLATFORMS.keys():
        for target in apple_targets:
            actual = resolve_aot_gen_snapshot("flutter", host, target)
            expected = expected_apple_aot.get((host, target), None)
            if expected == None:
                asserts.equals(
                    env,
                    None,
                    actual,
                    "Expected ({}, {}) Apple AOT to be unavailable, got {}".format(host, target, actual),
                )
            else:
                asserts.true(
                    env,
                    actual != None,
                    "Expected ({}, {}) Apple AOT to be available".format(host, target),
                )
                if actual != None:
                    asserts.equals(
                        env,
                        expected.release,
                        actual.release,
                        "Wrong release gen_snapshot for ({}, {})".format(host, target),
                    )
                    asserts.equals(
                        env,
                        expected.profile,
                        actual.profile,
                        "Wrong profile gen_snapshot for ({}, {})".format(host, target),
                    )
                    for mode_label in (actual.release, actual.profile):
                        asserts.false(
                            env,
                            "android" in mode_label,
                            "Apple AOT ({}, {}) must never wire an Android gen_snapshot: {}".format(host, target, mode_label),
                        )
                        asserts.false(
                            env,
                            "linux" in mode_label,
                            "Apple AOT ({}, {}) must never wire a Linux gen_snapshot: {}".format(host, target, mode_label),
                        )
                        asserts.false(
                            env,
                            "windows" in mode_label,
                            "Apple AOT ({}, {}) must never wire a Windows gen_snapshot: {}".format(host, target, mode_label),
                        )

    # Verify generated BUILD.bazel in @flutter_toolchains only registers AOT toolchains
    # for supported AOT pairs and never for Linux->iOS or desktop cross-compilation.
    toolchains_build = generate_toolchains_build("flutter")
    for darwin_host in ("darwin-arm64", "darwin-x64"):
        for ios_target in ("ios-arm64", "ios-x64"):
            asserts.true(
                env,
                'name = "{}_to_{}_aot_toolchain"'.format(darwin_host, ios_target) in toolchains_build,
                "Expected {}_to_{}_aot_toolchain in toolchains BUILD".format(darwin_host, ios_target),
            )
    for linux_host in ("linux-x64", "linux-arm64"):
        for ios_target in ("ios-arm64", "ios-x64"):
            asserts.true(
                env,
                'name = "{}_to_{}_toolchain"'.format(linux_host, ios_target) in toolchains_build,
                "Expected debug/JIT {}_to_{}_toolchain in toolchains BUILD".format(linux_host, ios_target),
            )
            asserts.false(
                env,
                'name = "{}_to_{}_aot_toolchain"'.format(linux_host, ios_target) in toolchains_build,
                "Must not register {}_to_{}_aot_toolchain in toolchains BUILD".format(linux_host, ios_target),
            )
    asserts.false(
        env,
        "_desktop_aot_toolchain" in toolchains_build,
        "Must not register any _desktop_aot_toolchain in toolchains BUILD",
    )

    # Verify generate_cross_repo_build omits flutter_aot_toolchain when no AOT gen_snapshot is available,
    # and wires both release and profile when available.
    linux_ios_build = generate_cross_repo_build(
        flutter_version = "3.47.7",
        engine_revision = "deadbeef",
        host_platform = "linux-x64",
        target_platform = "ios-arm64",
        host_repo_name = "flutter_linux-x64",
    )
    asserts.false(
        env,
        "flutter_aot_toolchain" in linux_ios_build,
        "linux-x64 -> ios-arm64 cross repo must not declare flutter_aot_toolchain",
    )

    darwin_sim_aot = resolve_aot_gen_snapshot("flutter", "darwin-arm64", "ios-x64")
    darwin_ios_x64_build = generate_cross_repo_build(
        flutter_version = "3.47.7",
        engine_revision = "deadbeef",
        host_platform = "darwin-arm64",
        target_platform = "ios-x64",
        host_repo_name = "flutter_darwin-arm64",
        gen_snapshot_label = darwin_sim_aot.release,
        profile_gen_snapshot_label = darwin_sim_aot.profile,
    )
    asserts.true(
        env,
        "@flutter_host_tools_release_darwin-x64//:host-tools-release/gen_snapshot" in darwin_ios_x64_build,
        "darwin-arm64 -> ios-x64 release must wire darwin-x64 release gen_snapshot",
    )
    asserts.true(
        env,
        "@flutter_darwin-x64_profile//:host-tools/gen_snapshot" in darwin_ios_x64_build,
        "darwin-arm64 -> ios-x64 profile must wire darwin-x64 profile gen_snapshot",
    )
    asserts.false(
        env,
        "@flutter_darwin-arm64//:host-tools/gen_snapshot" in darwin_ios_x64_build,
        "darwin-arm64 -> ios-x64 must not wire darwin-arm64 host debug gen_snapshot",
    )
    return unittest.end(env)

def _xtool_darwin_sdk_build_test_impl(ctx):
    """generate_xtool_darwin_sdk_build emits all 5 Darwin targets in both configured and stub modes."""
    env = unittest.begin(ctx)
    asserts.equals(env, ["rules_apple", "xtool"], APPLE_BACKEND_VALUES)
    expected_triples = {
        "ios_arm64": "arm64-apple-ios14.0",
        "ios_sim_arm64": "arm64-apple-ios14.0-simulator",
        "ios_x64": "x86_64-apple-ios14.0-simulator",
        "macos_arm64": "arm64-apple-macosx11.0",
        "macos_x64": "x86_64-apple-macosx11.0",
    }
    for key, triple in expected_triples.items():
        asserts.true(env, key in XTOOL_DARWIN_TARGETS, "Missing target key %s" % key)
        asserts.equals(env, triple, XTOOL_DARWIN_TARGETS[key].triple)

    stub_build = generate_xtool_darwin_sdk_build(sdk_available = False)
    asserts.true(env, "SDK_AVAILABLE = False" in stub_build, "Expected SDK_AVAILABLE = False in stub build")
    for key in expected_triples.keys():
        asserts.true(
            env,
            'name = "%s_cc_toolchain"' % key in stub_build,
            "Expected %s_cc_toolchain in stub build" % key,
        )

    configured_build = generate_xtool_darwin_sdk_build(
        sdk_available = True,
        sdk_paths = {
            "iPhoneOS": "sdk/iPhoneOS.sdk",
            "iPhoneSimulator": "sdk/iPhoneSimulator.sdk",
            "MacOSX": "sdk/MacOSX.sdk",
        },
        swift_bin_dir = "swift_bin",
    )
    asserts.true(env, "SDK_AVAILABLE = True" in configured_build, "Expected SDK_AVAILABLE = True")
    asserts.true(env, "sdk/iPhoneOS.sdk" in configured_build, "Expected iPhoneOS.sdk path")
    asserts.true(env, "sdk/MacOSX.sdk" in configured_build, "Expected MacOSX.sdk path")
    asserts.true(env, "xtool_darwin_sdk_status(" in configured_build, "Expected xtool_darwin_sdk_status target")
    asserts.true(env, '"llvm/**"' in configured_build, "Expected llvm/** in sdk_files glob")
    asserts.true(env, 'ar_files = ":sdk_files"' in configured_build, "Expected ar_files = :sdk_files on cc_toolchain")
    asserts.true(env, 'as_files = ":sdk_files"' in configured_build, "Expected as_files = :sdk_files on cc_toolchain")

    forbidden_bare = (
        "exec clang ",
        "exec clang++ ",
        "exec ld64.lld ",
        "exec llvm-ar ",
        "exec llvm-cov ",
        "exec llvm-nm ",
        "exec llvm-objdump ",
        "exec llvm-strip ",
        "exec swiftc ",
    )
    for scripts in (
        render_xtool_wrapper_scripts(sdk_available = False),
        render_xtool_wrapper_scripts(
            sdk_available = True,
            sdk_paths = {
                "iPhoneOS": "sdk/iPhoneOS.sdk",
                "iPhoneSimulator": "sdk/iPhoneSimulator.sdk",
                "MacOSX": "sdk/MacOSX.sdk",
            },
            swift_bin_dir = "swift_bin",
        ),
    ):
        for tool in ("llvm-ar", "llvm-cov", "llvm-nm", "llvm-objdump", "llvm-strip"):
            body = scripts["bin/%s" % tool]
            asserts.true(
                env,
                '"${REPO_ROOT}/llvm/bin/%s"' % tool in body,
                "Expected hermetic llvm path in bin/%s, got:\n%s" % (tool, body),
            )
        for key in expected_triples.keys():
            asserts.true(
                env,
                '"${REPO_ROOT}/llvm/bin/clang"' in scripts["bin/clang_%s" % key],
                "Expected hermetic clang path in bin/clang_%s" % key,
            )
            asserts.true(
                env,
                '"${REPO_ROOT}/llvm/bin/clang++"' in scripts["bin/clang-cpp_%s" % key],
                "Expected hermetic clang++ path in bin/clang-cpp_%s" % key,
            )
            asserts.true(
                env,
                '"${REPO_ROOT}/llvm/bin/ld64.lld"' in scripts["bin/ld64.lld_%s" % key],
                "Expected hermetic ld64.lld path in bin/ld64.lld_%s" % key,
            )
        for script_path, body in scripts.items():
            for bare in forbidden_bare:
                asserts.false(
                    env,
                    bare in body,
                    "Forbidden bare tool invocation %r in %s:\n%s" % (bare, script_path, body),
                )

    info_json = json.encode({
        "schemaVersion": "1.0",
        "artifacts": {
            "iphoneos": {
                "type": "sdk",
                "variants": [{"path": "iPhoneOS17.4.sdk"}],
            },
            "iphonesimulator": {
                "type": "sdk",
                "variants": [{"path": "iPhoneSimulator17.4.sdk"}],
            },
            "macosx": {
                "type": "sdk",
                "variants": [{"path": "MacOSX14.4.sdk"}],
            },
        },
    })
    resolved_paths = resolve_darwin_artifactbundle_sdk_paths(info_json, "sdk")
    asserts.equals(env, "sdk/iPhoneOS17.4.sdk", resolved_paths["iPhoneOS"])
    asserts.equals(env, "sdk/iPhoneSimulator17.4.sdk", resolved_paths["iPhoneSimulator"])
    asserts.equals(env, "sdk/MacOSX14.4.sdk", resolved_paths["MacOSX"])
    return unittest.end(env)

def _darwin_sdk_module_resolution_test_impl(ctx):
    """Validates root-module darwin_sdk resolution for url+sha256, local path, and unconfigured defaults."""
    env = unittest.begin(ctx)

    unconfigured = resolve_darwin_sdk_from_modules([
        struct(name = "my_app", is_root = True, tags = struct(darwin_sdk = [])),
        struct(name = "dep_mod", is_root = False, tags = struct(darwin_sdk = [])),
    ])
    asserts.equals(env, "", unconfigured.path)
    asserts.equals(env, "", unconfigured.url)
    asserts.equals(env, "", unconfigured.sha256)

    hermetic = resolve_darwin_sdk_from_modules([
        struct(
            name = "my_app",
            is_root = True,
            tags = struct(darwin_sdk = [
                struct(
                    path = "",
                    url = "https://example.com/darwin.artifactbundle.tar.gz",
                    sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                    swift_toolchain_path = "",
                ),
            ]),
        ),
    ])
    asserts.equals(env, "https://example.com/darwin.artifactbundle.tar.gz", hermetic.url)
    asserts.equals(
        env,
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        hermetic.sha256,
    )

    local_path = validate_darwin_sdk_config(
        path = "/some/local/darwin.artifactbundle",
        url = "",
        sha256 = "",
        swift_toolchain_path = "/some/local/swift",
    )
    asserts.equals(env, "/some/local/darwin.artifactbundle", local_path.path)
    asserts.equals(env, "/some/local/swift", local_path.swift_toolchain_path)
    return unittest.end(env)

def _darwin_sdk_validation_probe_impl(ctx):
    if ctx.attr.scenario == "non_root":
        resolve_darwin_sdk_from_modules([
            struct(name = "root_mod", is_root = True, tags = struct(darwin_sdk = [])),
            struct(
                name = "rogue_dep",
                is_root = False,
                tags = struct(darwin_sdk = [
                    struct(
                        path = "/rogue/sdk",
                        url = "",
                        sha256 = "",
                        swift_toolchain_path = "",
                    ),
                ]),
            ),
        ])
    elif ctx.attr.scenario == "url_without_sha256":
        resolve_darwin_sdk_from_modules([
            struct(
                name = "root_mod",
                is_root = True,
                tags = struct(darwin_sdk = [
                    struct(
                        path = "",
                        url = "https://example.com/darwin.artifactbundle.zip",
                        sha256 = "",
                        swift_toolchain_path = "",
                    ),
                ]),
            ),
        ])
    elif ctx.attr.scenario == "url_and_path":
        resolve_darwin_sdk_from_modules([
            struct(
                name = "root_mod",
                is_root = True,
                tags = struct(darwin_sdk = [
                    struct(
                        path = "/local/darwin.artifactbundle",
                        url = "https://example.com/darwin.artifactbundle.zip",
                        sha256 = "abc123",
                        swift_toolchain_path = "",
                    ),
                ]),
            ),
        ])
    elif ctx.attr.scenario == "multiple_tags":
        resolve_darwin_sdk_from_modules([
            struct(
                name = "root_mod",
                is_root = True,
                tags = struct(darwin_sdk = [
                    struct(path = "/sdk1", url = "", sha256 = "", swift_toolchain_path = ""),
                    struct(path = "/sdk2", url = "", sha256 = "", swift_toolchain_path = ""),
                ]),
            ),
        ])
    return [DefaultInfo()]

_darwin_sdk_validation_probe = rule(
    implementation = _darwin_sdk_validation_probe_impl,
    attrs = {
        "scenario": attr.string(mandatory = True),
    },
)

def _expect_analysis_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

_expect_analysis_failure_test = analysistest.make(
    _expect_analysis_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_error": attr.string(mandatory = True),
    },
)

_BackendProbeInfo = provider(
    doc = "Test probe provider recording the selected Apple backend.",
    fields = ["backend"],
)

def _backend_probe_impl(ctx):
    return [_BackendProbeInfo(backend = ctx.attr.selected_backend)]

_backend_probe = rule(
    implementation = _backend_probe_impl,
    attrs = {
        "selected_backend": attr.string(mandatory = True),
    },
)

def _apple_backend_xtool_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.equals(env, "xtool", tut[_BackendProbeInfo].backend)
    return analysistest.end(env)

_apple_backend_xtool_test = analysistest.make(
    _apple_backend_xtool_test_impl,
    config_settings = {
        str(Label("//flutter/settings:apple_backend")): "xtool",
    },
)

def _apple_backend_rules_apple_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.equals(env, "rules_apple", tut[_BackendProbeInfo].backend)
    return analysistest.end(env)

_apple_backend_rules_apple_test = analysistest.make(
    _apple_backend_rules_apple_test_impl,
    config_settings = {
        str(Label("//flutter/settings:apple_backend")): "rules_apple",
    },
)

_apple_backend_default_test = analysistest.make(_apple_backend_rules_apple_test_impl)

def _macho_aot_probe_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".dylib")
    flutter_aot_macho_action(
        ctx = ctx,
        gen_snapshot = ctx.file.gen_snapshot,
        kernel_dill = ctx.file.kernel_dill,
        output = out,
        strip = True,
        min_os_version = ctx.attr.min_os_version if ctx.attr.min_os_version else None,
    )
    return [DefaultInfo(files = depset([out]))]

_macho_aot_probe = rule(
    implementation = _macho_aot_probe_impl,
    attrs = {
        "gen_snapshot": attr.label(allow_single_file = True, mandatory = True),
        "kernel_dill": attr.label(allow_single_file = True, mandatory = True),
        "min_os_version": attr.string(default = "14.0"),
    },
)

def _macho_aot_flags_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterAotMacho"]
    asserts.equals(env, 1, len(actions), "Expected one FlutterAotMacho action")
    if actions:
        argv = actions[0].argv
        asserts.true(
            env,
            "--macho-install-name=@rpath/App.framework/App" in argv,
            "Expected --macho-install-name in argv, got: %s" % argv,
        )
        asserts.true(
            env,
            "--macho-min-os-version=14.0" in argv,
            "Expected --macho-min-os-version=14.0 in argv, got: %s" % argv,
        )
        asserts.true(
            env,
            "--macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks" in argv,
            "Expected --macho-rpath in argv, got: %s" % argv,
        )
    return analysistest.end(env)

_macho_aot_flags_test = analysistest.make(_macho_aot_flags_test_impl)

def _apple_debug_cross_succeeds_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    mnemonics = [a.mnemonic for a in actions]
    asserts.true(
        env,
        "FlutterKernelCompile" in mnemonics,
        "Expected FlutterKernelCompile in debug mode, got: %s" % mnemonics,
    )
    asserts.false(
        env,
        "FlutterAotMacho" in mnemonics or "FlutterAotElf" in mnemonics,
        "Expected no AOT action in debug mode, got: %s" % mnemonics,
    )
    return analysistest.end(env)

def _make_apple_debug_test(platform_label):
    return analysistest.make(
        _apple_debug_cross_succeeds_test_impl,
        config_settings = {
            "//command_line_option:compilation_mode": "dbg",
            "//command_line_option:platforms": str(Label(platform_label)),
            str(Label("//flutter:profile")): False,
        },
    )

_ios_arm64_dbg_test = _make_apple_debug_test("//flutter/platforms:ios_arm64")
_ios_x64_dbg_test = _make_apple_debug_test("//flutter/platforms:ios_x64")
_macos_arm64_dbg_test = _make_apple_debug_test("//flutter/platforms:macos_arm64")
_macos_x64_dbg_test = _make_apple_debug_test("//flutter/platforms:macos_x64")

def _ios_aot_unavailable_on_non_macos_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "No target-compatible AOT gen_snapshot toolchain is registered")
    return analysistest.end(env)

def _macos_aot_cross_unavailable_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "AOT cross-compilation between desktop platforms is not supported")
    return analysistest.end(env)

def _make_ios_aot_unavailable_test(platform_label, profile = False):
    settings = {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:platforms": str(Label(platform_label)),
        str(Label("//flutter:profile")): profile,
    }
    return analysistest.make(
        _ios_aot_unavailable_on_non_macos_test_impl,
        expect_failure = True,
        config_settings = settings,
    )

def _make_macos_aot_cross_unavailable_test(platform_label, profile = False):
    settings = {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:platforms": str(Label(platform_label)),
        str(Label("//flutter:profile")): profile,
    }
    return analysistest.make(
        _macos_aot_cross_unavailable_test_impl,
        expect_failure = True,
        config_settings = settings,
    )

_ios_arm64_release_unavailable_test = _make_ios_aot_unavailable_test("//flutter/platforms:ios_arm64", profile = False)
_ios_arm64_profile_unavailable_test = _make_ios_aot_unavailable_test("//flutter/platforms:ios_arm64", profile = True)
_ios_x64_release_unavailable_test = _make_ios_aot_unavailable_test("//flutter/platforms:ios_x64", profile = False)
_ios_x64_profile_unavailable_test = _make_ios_aot_unavailable_test("//flutter/platforms:ios_x64", profile = True)
_macos_arm64_release_unavailable_test = _make_macos_aot_cross_unavailable_test("//flutter/platforms:macos_arm64", profile = False)
_macos_arm64_profile_unavailable_test = _make_macos_aot_cross_unavailable_test("//flutter/platforms:macos_arm64", profile = True)
_macos_x64_release_unavailable_test = _make_macos_aot_cross_unavailable_test("//flutter/platforms:macos_x64", profile = False)
_macos_x64_profile_unavailable_test = _make_macos_aot_cross_unavailable_test("//flutter/platforms:macos_x64", profile = True)

_t0_test = unittest.make(_desktop_cross_pairs_keys_are_host_platforms_test_impl)
_t1_test = unittest.make(_desktop_cross_pairs_targets_are_host_platforms_test_impl)
_t2_test = unittest.make(_desktop_cross_pairs_no_self_pairs_test_impl)
_t3_test = unittest.make(_desktop_cross_pairs_no_same_os_test_impl)
_t4_test = unittest.make(_desktop_cross_pairs_all_hosts_covered_test_impl)
_t5_test = unittest.make(_cross_compilation_pairs_valid_test_impl)
_t6_test = unittest.make(_xtool_darwin_sdk_build_test_impl)
_t7_test = unittest.make(_apple_aot_matrix_by_host_target_mode_test_impl)
_t8_test = unittest.make(_darwin_sdk_module_resolution_test_impl)

def toolchains_repo_test_suite(name):
    """Defines unit and analysis tests for `toolchains_repo.bzl`, `xtool_darwin_sdk_repo.bzl`, and Apple AOT toolchains.

    Args:
      name: The test_suite target name.
    """
    _backend_probe(
        name = name + "_backend_probe",
        selected_backend = select({
            "//flutter/settings:use_xtool_backend": "xtool",
            "//conditions:default": "rules_apple",
        }),
        tags = ["manual"],
    )
    _apple_backend_default_test(
        name = name + "_apple_backend_default",
        target_under_test = ":" + name + "_backend_probe",
    )
    _apple_backend_xtool_test(
        name = name + "_apple_backend_xtool",
        target_under_test = ":" + name + "_backend_probe",
    )
    _apple_backend_rules_apple_test(
        name = name + "_apple_backend_rules_apple",
        target_under_test = ":" + name + "_backend_probe",
    )

    write_file(
        name = name + "_fake_gen_snapshot",
        out = name + "_fake_gen_snapshot.bin",
        content = [""],
        tags = ["manual"],
    )
    write_file(
        name = name + "_fake_dill",
        out = name + "_fake.dill",
        content = [""],
        tags = ["manual"],
    )
    _macho_aot_probe(
        name = name + "_macho_aot_probe",
        gen_snapshot = ":" + name + "_fake_gen_snapshot",
        kernel_dill = ":" + name + "_fake_dill",
        min_os_version = "14.0",
        tags = ["manual"],
    )
    _macho_aot_flags_test(
        name = name + "_macho_aot_flags",
        target_under_test = ":" + name + "_macho_aot_probe",
    )

    flutter_application(
        name = name + "_apple_cross_app",
        package_name = "apple_cross_fixture",
        main = "lib/language_version_main.dart",
        min_os_version = "14.0",
        tags = ["manual"],
    )
    flutter_aot_target(
        name = name + "_apple_cross_aot",
        package_name = "apple_cross_fixture",
        main = "lib/language_version_main.dart",
        defines = ["TEST=1"],
        min_os_version = "14.0",
        tags = ["manual"],
    )

    analysis_tests = []
    for suffix, dbg_rule in [
        ("ios_arm64_dbg", _ios_arm64_dbg_test),
        ("ios_x64_dbg", _ios_x64_dbg_test),
        ("macos_arm64_dbg", _macos_arm64_dbg_test),
        ("macos_x64_dbg", _macos_x64_dbg_test),
    ]:
        t_app = "%s_app_%s" % (name, suffix)
        dbg_rule(name = t_app, target_under_test = ":" + name + "_apple_cross_app")
        analysis_tests.append(":" + t_app)

        t_aot = "%s_aot_%s" % (name, suffix)
        dbg_rule(name = t_aot, target_under_test = ":" + name + "_apple_cross_aot")
        analysis_tests.append(":" + t_aot)

    for suffix, fail_rule in [
        ("ios_arm64_release_unavailable", _ios_arm64_release_unavailable_test),
        ("ios_arm64_profile_unavailable", _ios_arm64_profile_unavailable_test),
        ("ios_x64_release_unavailable", _ios_x64_release_unavailable_test),
        ("ios_x64_profile_unavailable", _ios_x64_profile_unavailable_test),
        ("macos_arm64_release_unavailable", _macos_arm64_release_unavailable_test),
        ("macos_arm64_profile_unavailable", _macos_arm64_profile_unavailable_test),
        ("macos_x64_release_unavailable", _macos_x64_release_unavailable_test),
        ("macos_x64_profile_unavailable", _macos_x64_profile_unavailable_test),
    ]:
        t_app = "%s_app_%s" % (name, suffix)
        fail_rule(
            name = t_app,
            target_under_test = ":" + name + "_apple_cross_app",
            target_compatible_with = ["@platforms//os:linux"],
        )
        analysis_tests.append(":" + t_app)

        t_aot = "%s_aot_%s" % (name, suffix)
        fail_rule(
            name = t_aot,
            target_under_test = ":" + name + "_apple_cross_aot",
            target_compatible_with = ["@platforms//os:linux"],
        )
        analysis_tests.append(":" + t_aot)

    build_test(
        name = name + "_xtool_sdk_status_build",
        targets = [
            "@flutter_xtool_darwin_sdk//:sdk_status",
        ],
    )
    _expect_analysis_failure_test(
        name = name + "_unconfigured_sdk_files_fails",
        target_under_test = "@flutter_xtool_darwin_sdk//:sdk_files",
        expected_error = "xtool Darwin SDK (@flutter_xtool_darwin_sdk) is not configured",
    )
    _expect_analysis_failure_test(
        name = name + "_unconfigured_ios_cc_toolchain_fails",
        target_under_test = "@flutter_xtool_darwin_sdk//:ios_arm64_cc_toolchain_config",
        expected_error = "flutter.darwin_sdk",
    )
    _expect_analysis_failure_test(
        name = name + "_unconfigured_macos_cc_toolchain_fails",
        target_under_test = "@flutter_xtool_darwin_sdk//:macos_arm64_cc_toolchain_config",
        expected_error = "flutter.darwin_sdk",
    )
    _expect_analysis_failure_test(
        name = name + "_unconfigured_swift_wrapper_fails",
        target_under_test = "@flutter_xtool_darwin_sdk//:ios_arm64_swift_wrapper",
        expected_error = "flutter.darwin_sdk",
    )

    _darwin_sdk_validation_probe(
        name = name + "_probe_non_root",
        scenario = "non_root",
        tags = ["manual"],
    )
    _expect_analysis_failure_test(
        name = name + "_darwin_sdk_non_root_rejected",
        target_under_test = ":" + name + "_probe_non_root",
        expected_error = "Only the root module may set the flutter.darwin_sdk tag",
    )

    _darwin_sdk_validation_probe(
        name = name + "_probe_url_without_sha256",
        scenario = "url_without_sha256",
        tags = ["manual"],
    )
    _expect_analysis_failure_test(
        name = name + "_darwin_sdk_url_without_sha256_rejected",
        target_under_test = ":" + name + "_probe_url_without_sha256",
        expected_error = "'sha256' is required when 'url' is set",
    )

    _darwin_sdk_validation_probe(
        name = name + "_probe_url_and_path",
        scenario = "url_and_path",
        tags = ["manual"],
    )
    _expect_analysis_failure_test(
        name = name + "_darwin_sdk_url_and_path_rejected",
        target_under_test = ":" + name + "_probe_url_and_path",
        expected_error = "specify either 'url' (with 'sha256') or 'path', not both",
    )

    _darwin_sdk_validation_probe(
        name = name + "_probe_multiple_tags",
        scenario = "multiple_tags",
        tags = ["manual"],
    )
    _expect_analysis_failure_test(
        name = name + "_darwin_sdk_multiple_tags_rejected",
        target_under_test = ":" + name + "_probe_multiple_tags",
        expected_error = "flutter.darwin_sdk may be specified at most once in the root module",
    )

    _xtool_hermetic_llvm_probe(
        name = name + "_xtool_hermetic_llvm_probe",
        tags = ["manual"],
    )
    build_test(
        name = name + "_xtool_hermetic_llvm_build",
        targets = [
            ":" + name + "_xtool_hermetic_llvm_probe",
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
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_apple_backend_default",
            ":" + name + "_apple_backend_xtool",
            ":" + name + "_apple_backend_rules_apple",
            ":" + name + "_macho_aot_flags",
            ":" + name + "_xtool_sdk_status_build",
            ":" + name + "_xtool_hermetic_llvm_build",
            ":" + name + "_unconfigured_sdk_files_fails",
            ":" + name + "_unconfigured_ios_cc_toolchain_fails",
            ":" + name + "_unconfigured_macos_cc_toolchain_fails",
            ":" + name + "_unconfigured_swift_wrapper_fails",
            ":" + name + "_darwin_sdk_non_root_rejected",
            ":" + name + "_darwin_sdk_url_without_sha256_rejected",
            ":" + name + "_darwin_sdk_url_and_path_rejected",
            ":" + name + "_darwin_sdk_multiple_tags_rejected",
        ] + analysis_tests,
    )

def _xtool_hermetic_llvm_probe_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".dylib")
    work_dir = ctx.actions.declare_directory(ctx.label.name + "_work")
    clang_wrapper = None
    clang_include_dir = None
    for f in ctx.files.toolchain_files:
        if f.path.endswith("/bin/clang_macos_arm64"):
            clang_wrapper = f
        if f.path.endswith("/include/stdint.h") and "/llvm/lib/clang/" in f.path:
            clang_include_dir = f.dirname
    if not clang_wrapper:
        fail("Missing bin/clang_macos_arm64 in @flutter_xtool_darwin_sdk//:toolchain_files")
    if not clang_include_dir:
        fail("Missing llvm/lib/clang/*/include/stdint.h in @flutter_xtool_darwin_sdk//:toolchain_files")
    repo_root = clang_wrapper.dirname[:-len("/bin")]
    ctx.actions.run_shell(
        inputs = ctx.files.toolchain_files,
        outputs = [out, work_dir],
        mnemonic = "FlutterXtoolHermeticLlvmProbe",
        env = {"TMPDIR": "/tmp"},
        use_default_shell_env = False,
        command = """set -euo pipefail
REPO_ROOT="{repo_root}"
CLANG_INCLUDE_DIR="{clang_include_dir}"
WORK="{work_dir}"
OUT="{out}"
mkdir -p "$WORK/decoy_bin" "$WORK/MacOSX.sdk/usr/include"
for tool in clang clang++ ld64.lld llvm-ar llvm-cov llvm-nm llvm-objdump llvm-strip; do
  cat > "$WORK/decoy_bin/$tool" <<'EOF'
#!/bin/bash
echo "ERROR: non-hermetic PATH fallback invoked: $0" >&2
exit 99
EOF
  chmod +x "$WORK/decoy_bin/$tool"
done

cat > "$WORK/MacOSX.sdk/usr/include/TargetConditionals.h" <<'EOF'
#ifndef __TARGETCONDITIONALS__
#define __TARGETCONDITIONALS__
#define TARGET_OS_MAC 1
#define TARGET_OS_OSX 1
#endif
EOF

cat > "$WORK/sample.c" <<'EOF'
#include <stdint.h>
#include <TargetConditionals.h>
int32_t xtool_test_add(int32_t a, int32_t b) {{
  return a + b;
}}
EOF

export PATH="$WORK/decoy_bin"
"$REPO_ROOT/bin/clang_macos_arm64" -nostdinc --sysroot="$WORK/MacOSX.sdk" -isysroot "$WORK/MacOSX.sdk" -isystem "$CLANG_INCLUDE_DIR" -isystem "$WORK/MacOSX.sdk/usr/include" -MD -MF "$WORK/sample.d" -c "$WORK/sample.c" -o "$WORK/sample.o"
PATH="" "$REPO_ROOT/bin/clang_macos_arm64" -nostdinc --sysroot="$WORK/MacOSX.sdk" -isysroot "$WORK/MacOSX.sdk" -isystem "$CLANG_INCLUDE_DIR" -isystem "$WORK/MacOSX.sdk/usr/include" -MD -MF "$WORK/sample_empty_path.d" -c "$WORK/sample.c" -o "$WORK/sample_empty_path.o"
"$REPO_ROOT/bin/clang_macos_arm64" -I"$WORK/MacOSX.sdk/usr/include" -MD -MF "$WORK/sample_default.d" -c "$WORK/sample.c" -o "$WORK/sample_default.o"
for depfile in "$WORK/sample.d" "$WORK/sample_empty_path.d" "$WORK/sample_default.d"; do
  while IFS= read -r line || [[ -n "$line" ]]; do
    for tok in $line; do
      if [[ "$tok" == /usr/* ]]; then
        echo "ERROR: non-hermetic host /usr header read ($tok) in $depfile" >&2
        exit 98
      fi
    done
  done < "$depfile"
done
"$REPO_ROOT/bin/llvm-ar" rcs "$WORK/libsample.a" "$WORK/sample.o"
"$REPO_ROOT/bin/llvm-nm" "$WORK/libsample.a" > "$WORK/nm.txt"
"$REPO_ROOT/bin/ld64.lld_macos_arm64" -arch arm64 -platform_version macos 11.0.0 11.0.0 -dylib "$WORK/sample.o" -o "$WORK/libsample_unstripped.dylib"
PATH="" "$REPO_ROOT/bin/ld64.lld_macos_arm64" -arch arm64 -platform_version macos 11.0.0 11.0.0 -dylib "$WORK/sample_empty_path.o" -o "$WORK/libsample_empty_path.dylib"
"$REPO_ROOT/bin/llvm-objdump" --macho --private-headers "$WORK/libsample_unstripped.dylib" > "$WORK/objdump.txt"
"$REPO_ROOT/bin/llvm-strip" -x "$WORK/libsample_unstripped.dylib" -o "$OUT"
"$REPO_ROOT/bin/llvm-cov" --version > "$WORK/cov.txt"
""".format(
            repo_root = repo_root,
            clang_include_dir = clang_include_dir,
            work_dir = work_dir.path,
            out = out.path,
        ),
    )
    return [DefaultInfo(files = depset([out]))]

_xtool_hermetic_llvm_probe = rule(
    implementation = _xtool_hermetic_llvm_probe_impl,
    attrs = {
        "toolchain_files": attr.label(
            default = Label("@flutter_xtool_darwin_sdk//:toolchain_files"),
            allow_files = True,
        ),
    },
)
