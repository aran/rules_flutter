"""Repository rule and C++/Swift cross-toolchain definitions for xtool Darwin SDKs on Linux.

Downloads a checksummed `xtool` `darwin.artifactbundle` archive (`url` +
`sha256`, hermetic) or symlinks an explicitly configured local bundle (`path`,
non-hermetic), containing `iPhoneOS.sdk`, `iPhoneSimulator.sdk`, and
`MacOSX.sdk`, and emits Bazel `cc_toolchain`, Swift wrapper targets, and
`toolchain` definitions for:
  - `ios_arm64` (`arm64-apple-ios14.0`)
  - `ios_sim_arm64` (`arm64-apple-ios14.0-simulator`)
  - `ios_x64` (`x86_64-apple-ios14.0-simulator`)
  - `macos_arm64` (`arm64-apple-macosx11.0`)
  - `macos_x64` (`x86_64-apple-macosx11.0`)

No host environment variables, `HOME`, `PATH`, `which`, or well-known host
directories are probed. When neither `url` nor `path` is configured, the
repository rule still instantiates with `SDK_AVAILABLE = False` so that
`bazel test //...` works, but any target that requires the SDK fails at
analysis with instructions on how to configure `flutter.darwin_sdk`.
"""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "feature",
    "flag_group",
    "flag_set",
    "tool_path",
)
load("@rules_cc//cc:defs.bzl", "CcToolchainConfigInfo")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load(":artifact_urls.bzl", "require_sha256")

XTOOL_DARWIN_TARGETS = {
    "ios_arm64": struct(
        triple = "arm64-apple-ios14.0",
        sdk_name = "iPhoneOS",
        os_constraint = "@platforms//os:ios",
        cpu_constraint = "@platforms//cpu:arm64",
        target_cpu = "ios_arm64",
        target_system_name = "arm64-apple-ios14.0",
    ),
    "ios_sim_arm64": struct(
        triple = "arm64-apple-ios14.0-simulator",
        sdk_name = "iPhoneSimulator",
        os_constraint = "@platforms//os:ios",
        cpu_constraint = "@platforms//cpu:arm64",
        target_cpu = "ios_sim_arm64",
        target_system_name = "arm64-apple-ios14.0-simulator",
    ),
    "ios_x64": struct(
        triple = "x86_64-apple-ios14.0-simulator",
        sdk_name = "iPhoneSimulator",
        os_constraint = "@platforms//os:ios",
        cpu_constraint = "@platforms//cpu:x86_64",
        target_cpu = "ios_x86_64",
        target_system_name = "x86_64-apple-ios14.0-simulator",
    ),
    "macos_arm64": struct(
        triple = "arm64-apple-macosx11.0",
        sdk_name = "MacOSX",
        os_constraint = "@platforms//os:macos",
        cpu_constraint = "@platforms//cpu:arm64",
        target_cpu = "darwin_arm64",
        target_system_name = "arm64-apple-macosx11.0",
    ),
    "macos_x64": struct(
        triple = "x86_64-apple-macosx11.0",
        sdk_name = "MacOSX",
        os_constraint = "@platforms//os:macos",
        cpu_constraint = "@platforms//cpu:x86_64",
        target_cpu = "darwin_x86_64",
        target_system_name = "x86_64-apple-macosx11.0",
    ),
}

_UNCONFIGURED_SDK_ERROR = (
    "The xtool Darwin SDK (@flutter_xtool_darwin_sdk) is not configured. " +
    "Configure it in your root MODULE.bazel with a checksummed archive:\n" +
    "    flutter = use_extension(\"@rules_flutter//flutter:extensions.bzl\", \"flutter\")\n" +
    "    flutter.darwin_sdk(\n" +
    "        url = \"https://.../darwin.artifactbundle.tar.gz\",\n" +
    "        sha256 = \"<sha256>\",\n" +
    "    )\n" +
    "or, for a local non-hermetic SDK:\n" +
    "    flutter.darwin_sdk(path = \"<path-to-darwin.artifactbundle>\")"
)

_COMPILE_ACTIONS = [
    ACTION_NAMES.c_compile,
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.objc_compile,
    ACTION_NAMES.objcpp_compile,
    ACTION_NAMES.assemble,
    ACTION_NAMES.preprocess_assemble,
]

_LINK_ACTIONS = [
    ACTION_NAMES.cpp_link_executable,
    ACTION_NAMES.cpp_link_dynamic_library,
    ACTION_NAMES.cpp_link_nodeps_dynamic_library,
    ACTION_NAMES.objc_executable,
]

def _xtool_darwin_cc_toolchain_config_impl(ctx):
    if not ctx.attr.sdk_available or not ctx.attr.sdk_path:
        fail(_UNCONFIGURED_SDK_ERROR)

    compile_flags = [
        "-target",
        ctx.attr.triple,
        "-isysroot",
        ctx.attr.sdk_path,
    ]
    link_flags = [
        "-target",
        ctx.attr.triple,
        "-fuse-ld=lld",
        "-isysroot",
        ctx.attr.sdk_path,
    ]

    default_flags_feature = feature(
        name = "xtool_darwin_default_flags",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = compile_flags)],
            ),
            flag_set(
                actions = _LINK_ACTIONS,
                flag_groups = [flag_group(flags = link_flags)],
            ),
        ],
    )

    tool_paths = [
        tool_path(name = "gcc", path = "bin/clang_%s" % ctx.attr.target_key),
        tool_path(name = "ld", path = "bin/ld64.lld_%s" % ctx.attr.target_key),
        tool_path(name = "ar", path = "bin/llvm-ar"),
        tool_path(name = "cpp", path = "bin/clang-cpp_%s" % ctx.attr.target_key),
        tool_path(name = "gcov", path = "bin/llvm-cov"),
        tool_path(name = "nm", path = "bin/llvm-nm"),
        tool_path(name = "objdump", path = "bin/llvm-objdump"),
        tool_path(name = "strip", path = "bin/llvm-strip"),
    ]

    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        features = [default_flags_feature],
        toolchain_identifier = "xtool_darwin_%s" % ctx.attr.target_key,
        host_system_name = "x86_64-unknown-linux-gnu",
        target_system_name = ctx.attr.triple,
        target_cpu = ctx.attr.target_cpu,
        target_libc = "macosx",
        compiler = "clang",
        abi_version = "darwin",
        abi_libc_version = "darwin",
        tool_paths = tool_paths,
    )

xtool_darwin_cc_toolchain_config = rule(
    implementation = _xtool_darwin_cc_toolchain_config_impl,
    attrs = {
        "sdk_available": attr.bool(default = True),
        "target_key": attr.string(mandatory = True),
        "triple": attr.string(mandatory = True),
        "target_cpu": attr.string(mandatory = True),
        "sdk_path": attr.string(default = ""),
    },
    provides = [CcToolchainConfigInfo],
)

def _xtool_darwin_sdk_target_impl(ctx):
    if not ctx.attr.sdk_available:
        fail(_UNCONFIGURED_SDK_ERROR)
    return [DefaultInfo(files = depset(ctx.files.srcs))]

xtool_darwin_sdk_target = rule(
    implementation = _xtool_darwin_sdk_target_impl,
    attrs = {
        "sdk_available": attr.bool(mandatory = True),
        "srcs": attr.label_list(allow_files = True, default = []),
    },
    doc = "Exposes files from @flutter_xtool_darwin_sdk or fails at analysis when the SDK is not configured.",
)

FlutterXtoolSdkInfo = provider(
    doc = "Metadata and status for the configured xtool Darwin SDK (`darwin.artifactbundle`).",
    fields = {
        "sdk_available": "bool: Whether a darwin.artifactbundle was explicitly configured.",
        "sdk_paths": "dict: Mapping from SDK name (iPhoneOS, iPhoneSimulator, MacOSX) to path.",
        "swift_bin_dir": "string: Relative path to the Swift/Clang toolchain bin directory.",
        "sdk_files": "depset: Files in the SDK repository.",
    },
)

def _xtool_darwin_sdk_status_impl(ctx):
    sdk_files = depset(ctx.files.sdk_files)
    return [
        DefaultInfo(files = sdk_files),
        FlutterXtoolSdkInfo(
            sdk_available = ctx.attr.sdk_available,
            sdk_paths = ctx.attr.sdk_paths,
            swift_bin_dir = ctx.attr.swift_bin_dir,
            sdk_files = sdk_files,
        ),
    ]

xtool_darwin_sdk_status = rule(
    implementation = _xtool_darwin_sdk_status_impl,
    attrs = {
        "sdk_available": attr.bool(mandatory = True),
        "sdk_paths": attr.string_dict(default = {}),
        "swift_bin_dir": attr.string(default = ""),
        "sdk_files": attr.label_list(allow_files = True, default = []),
    },
    provides = [FlutterXtoolSdkInfo],
)

def validate_darwin_sdk_config(
        *,
        url = "",
        sha256 = "",
        path = "",
        swift_toolchain_path = "",
        require_configured = False,
        context = "flutter.darwin_sdk"):
    """Validates xtool Darwin SDK configuration attributes.

    Args:
        url: Archive download URL (hermetic when paired with `sha256`).
        sha256: Expected SHA-256 hex digest for `url`.
        path: Local filesystem path to `darwin.artifactbundle` (non-hermetic).
        swift_toolchain_path: Optional local path to the Linux Swift toolchain.
        require_configured: When True (e.g. an explicit `flutter.darwin_sdk()`
            tag), requires either `url` or `path` to be non-empty.
        context: Prefix used in failure messages.

    Returns:
        struct(url, sha256, path, swift_toolchain_path, configured)
    """
    if url and path:
        fail("%s: specify either 'url' (with 'sha256') or 'path', not both." % context)
    if sha256 and not url:
        fail("%s: 'sha256' requires 'url' to be set." % context)
    if url:
        if not sha256:
            fail("%s: 'sha256' is required when 'url' is set (%s)." % (context, url))
        require_sha256(sha256, url)
    if require_configured and not url and not path:
        fail("%s: must specify either 'url' (with 'sha256') or 'path'." % context)
    return struct(
        url = url,
        sha256 = sha256,
        path = path,
        swift_toolchain_path = swift_toolchain_path,
        configured = bool(url or path),
    )

def resolve_darwin_sdk_from_modules(modules):
    """Extracts and validates `flutter.darwin_sdk` tags across Bzlmod modules.

    Only the root module (`mod.is_root`) may set `flutter.darwin_sdk`, and at
    most once.

    Args:
        modules: Iterable of Bzlmod module objects (`module_ctx.modules`).

    Returns:
        struct(url, sha256, path, swift_toolchain_path, configured)
    """
    found = None
    for mod in modules:
        tags = getattr(mod.tags, "darwin_sdk", [])
        if not tags:
            continue
        if not mod.is_root:
            mod_name = getattr(mod, "name", "") or "<non-root>"
            fail(
                "Only the root module may set the flutter.darwin_sdk tag " +
                "(found in non-root module '%s')." % mod_name,
            )
        if len(tags) > 1 or found != None:
            fail("flutter.darwin_sdk may be specified at most once in the root module.")
        sdk_tag = tags[0]
        found = validate_darwin_sdk_config(
            url = getattr(sdk_tag, "url", ""),
            sha256 = getattr(sdk_tag, "sha256", ""),
            path = getattr(sdk_tag, "path", ""),
            swift_toolchain_path = getattr(sdk_tag, "swift_toolchain_path", ""),
            require_configured = True,
            context = "flutter.darwin_sdk",
        )

    if found != None:
        return found
    return struct(
        url = "",
        sha256 = "",
        path = "",
        swift_toolchain_path = "",
        configured = False,
    )

def resolve_darwin_artifactbundle_sdk_paths(info_json_text, bundle_root):
    """Parses `darwin.artifactbundle/info.json` and returns a dict of SDK paths.

    Maps `"iPhoneOS"`, `"iPhoneSimulator"`, and `"MacOSX"` to their resolved
    directory paths under `bundle_root`.
    """
    prefix = bundle_root.rstrip("/")
    resolved = {
        "iPhoneOS": "%s/iPhoneOS.sdk" % prefix,
        "iPhoneSimulator": "%s/iPhoneSimulator.sdk" % prefix,
        "MacOSX": "%s/MacOSX.sdk" % prefix,
    }
    if not info_json_text:
        return resolved

    parsed = json.decode(info_json_text)
    if type(parsed) != "dict":
        return resolved
    artifacts = parsed.get("artifacts", {})
    if type(artifacts) != "dict":
        return resolved

    mapping = {
        "iphoneos": "iPhoneOS",
        "iphonesimulator": "iPhoneSimulator",
        "macosx": "MacOSX",
    }
    for key, val in artifacts.items():
        if type(val) != "dict":
            continue
        variants = val.get("variants", [])
        if type(variants) != "list":
            continue
        key_lower = key.lower()
        for variant in variants:
            if type(variant) != "dict":
                continue
            rel_path = variant.get("path", "")
            if not rel_path:
                continue
            path_lower = rel_path.lower()
            for prefix_key, sdk_name in mapping.items():
                if key_lower.startswith(prefix_key) or prefix_key in path_lower:
                    resolved[sdk_name] = "%s/%s" % (prefix, rel_path)
    return resolved

def generate_xtool_darwin_sdk_build(
        sdk_available,
        sdk_paths = {},
        swift_bin_dir = ""):
    """Generates the BUILD.bazel content for `@flutter_xtool_darwin_sdk`.

    Pure Starlark function suitable for unit testing both the configured
    (`sdk_available = True`) and unconfigured (`sdk_available = False`) states.

    Args:
        sdk_available: bool indicating whether `darwin.artifactbundle` was configured.
        sdk_paths: optional dict mapping SDK name (`iPhoneOS`, `iPhoneSimulator`,
            `MacOSX`) to its relative path inside the repository.
        swift_bin_dir: optional relative path to the Swift toolchain `bin` directory.

    Returns:
        String containing the complete `BUILD.bazel` file.
    """
    resolved_sdk_paths = {}
    for sdk_name in ("iPhoneOS", "iPhoneSimulator", "MacOSX"):
        resolved_sdk_paths[sdk_name] = sdk_paths.get(
            sdk_name,
            "sdk/%s.sdk" % sdk_name if sdk_available else "",
        )

    status_sdk_files = '[":sdk_files"]' if sdk_available else "[]"

    lines = [
        "# Generated by flutter/private/xtool_darwin_sdk_repo.bzl",
        'load("@rules_cc//cc:defs.bzl", "cc_toolchain")',
        'load("@rules_flutter//flutter/private:xtool_darwin_sdk_repo.bzl", "xtool_darwin_cc_toolchain_config", "xtool_darwin_sdk_status", "xtool_darwin_sdk_target")',
        "",
        "package(default_visibility = [\"//visibility:public\"])",
        "",
        "SDK_AVAILABLE = %s" % ("True" if sdk_available else "False"),
        "SWIFT_BIN_DIR = %r" % swift_bin_dir,
        "",
        "xtool_darwin_sdk_target(",
        '    name = "sdk_files",',
        "    sdk_available = SDK_AVAILABLE,",
        '    srcs = glob(["sdk/**", "bin/**", "swift_bin/**"], allow_empty = True),',
        ")",
        "",
        "filegroup(",
        '    name = "empty",',
        "    srcs = [],",
        ")",
        "",
        "xtool_darwin_sdk_status(",
        '    name = "sdk_status",',
        "    sdk_available = SDK_AVAILABLE,",
        "    sdk_paths = %r," % resolved_sdk_paths,
        "    swift_bin_dir = SWIFT_BIN_DIR,",
        "    sdk_files = %s," % status_sdk_files,
        ")",
        "",
        'exports_files(glob(["bin/**"], allow_empty = True))',
    ]

    for target_key in sorted(XTOOL_DARWIN_TARGETS.keys()):
        meta = XTOOL_DARWIN_TARGETS[target_key]
        sdk_path = sdk_paths.get(meta.sdk_name, "sdk/%s.sdk" % meta.sdk_name if sdk_available else "")
        lines.extend([
            "",
            "xtool_darwin_cc_toolchain_config(",
            '    name = "%s_cc_toolchain_config",' % target_key,
            "    sdk_available = SDK_AVAILABLE,",
            '    target_key = "%s",' % target_key,
            '    triple = "%s",' % meta.triple,
            '    target_cpu = "%s",' % meta.target_cpu,
            '    sdk_path = "%s",' % sdk_path,
            ")",
            "",
            "cc_toolchain(",
            '    name = "%s_cc_toolchain_impl",' % target_key,
            '    toolchain_identifier = "xtool_darwin_%s",' % target_key,
            '    toolchain_config = ":%s_cc_toolchain_config",' % target_key,
            '    all_files = ":sdk_files",',
            '    compiler_files = ":sdk_files",',
            '    dwp_files = ":empty",',
            '    linker_files = ":sdk_files",',
            '    objcopy_files = ":sdk_files",',
            '    strip_files = ":sdk_files",',
            "    supports_param_files = 1,",
            ")",
            "",
            "toolchain(",
            '    name = "%s_cc_toolchain",' % target_key,
            '    exec_compatible_with = ["@platforms//os:linux"],',
            "    target_compatible_with = [",
            '        "%s",' % meta.os_constraint,
            '        "%s",' % meta.cpu_constraint,
            "    ],",
            "    target_settings = [",
            '        "@rules_flutter//flutter/settings:use_xtool_backend",',
            "    ],",
            '    toolchain = ":%s_cc_toolchain_impl",' % target_key,
            '    toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",',
            ")",
            "",
            "xtool_darwin_sdk_target(",
            '    name = "%s_swift_wrapper",' % target_key,
            "    sdk_available = SDK_AVAILABLE,",
            '    srcs = ["bin/swiftc_%s"],' % target_key,
            ")",
        ])

    return "\n".join(lines) + "\n"

def _write_wrapper_scripts(repository_ctx, sdk_available, sdk_paths, swift_bin_dir):
    bin_prefix = (swift_bin_dir.rstrip("/") + "/") if swift_bin_dir else ""
    for tool in ("llvm-ar", "llvm-cov", "llvm-nm", "llvm-objdump", "llvm-strip"):
        repository_ctx.file(
            "bin/%s" % tool,
            """#!/usr/bin/env bash
set -euo pipefail
exec "{bin_prefix}{tool}" "$@"
""".format(bin_prefix = bin_prefix, tool = tool),
            executable = True,
        )

    for target_key, meta in XTOOL_DARWIN_TARGETS.items():
        sdk_path = sdk_paths.get(meta.sdk_name, "")
        if sdk_available and sdk_path:
            clang_body = """#!/usr/bin/env bash
set -euo pipefail
exec "{bin_prefix}clang" -target "{triple}" -isysroot "{sdk_path}" "$@"
""".format(bin_prefix = bin_prefix, triple = meta.triple, sdk_path = sdk_path)
            cpp_body = """#!/usr/bin/env bash
set -euo pipefail
exec "{bin_prefix}clang++" -target "{triple}" -isysroot "{sdk_path}" "$@"
""".format(bin_prefix = bin_prefix, triple = meta.triple, sdk_path = sdk_path)
            ld_body = """#!/usr/bin/env bash
set -euo pipefail
exec "{bin_prefix}ld64.lld" "$@"
""".format(bin_prefix = bin_prefix)
            swiftc_body = """#!/usr/bin/env bash
set -euo pipefail
exec "{bin_prefix}swiftc" -target "{triple}" -sdk "{sdk_path}" -Xcc -isysroot -Xcc "{sdk_path}" -use-ld=lld "$@"
""".format(bin_prefix = bin_prefix, triple = meta.triple, sdk_path = sdk_path)
        else:
            stub_err = """#!/usr/bin/env bash
echo "ERROR: xtool Darwin SDK (@flutter_xtool_darwin_sdk) is not configured for {target_key} ({triple})." >&2
echo "Configure flutter.darwin_sdk(url = ..., sha256 = ...) or flutter.darwin_sdk(path = ...) in your root MODULE.bazel." >&2
exit 1
""".format(target_key = target_key, triple = meta.triple)
            clang_body = stub_err
            cpp_body = stub_err
            ld_body = stub_err
            swiftc_body = stub_err

        repository_ctx.file("bin/clang_%s" % target_key, clang_body, executable = True)
        repository_ctx.file("bin/clang-cpp_%s" % target_key, cpp_body, executable = True)
        repository_ctx.file("bin/ld64.lld_%s" % target_key, ld_body, executable = True)
        repository_ctx.file("bin/swiftc_%s" % target_key, swiftc_body, executable = True)

def _resolve_bundle_sdk_paths(repository_ctx):
    direct_info = repository_ctx.path("sdk/info.json")
    nested_info = repository_ctx.path("sdk/darwin.artifactbundle/info.json")
    if direct_info.exists:
        return resolve_darwin_artifactbundle_sdk_paths(repository_ctx.read(direct_info), "sdk")
    if nested_info.exists:
        return resolve_darwin_artifactbundle_sdk_paths(
            repository_ctx.read(nested_info),
            "sdk/darwin.artifactbundle",
        )
    if repository_ctx.path("sdk/darwin.artifactbundle").exists:
        return resolve_darwin_artifactbundle_sdk_paths("", "sdk/darwin.artifactbundle")
    return resolve_darwin_artifactbundle_sdk_paths("", "sdk")

def _xtool_darwin_sdk_repo_impl(repository_ctx):
    cfg = validate_darwin_sdk_config(
        url = repository_ctx.attr.url,
        sha256 = repository_ctx.attr.sha256,
        path = repository_ctx.attr.path,
        swift_toolchain_path = repository_ctx.attr.swift_toolchain_path,
        require_configured = False,
        context = "xtool_darwin_sdk_repo",
    )

    sdk_available = False
    sdk_paths = {}
    swift_bin_dir = ""

    if cfg.url:
        repository_ctx.download_and_extract(
            url = cfg.url,
            sha256 = require_sha256(cfg.sha256, cfg.url),
            output = "sdk",
        )
        sdk_available = True
        sdk_paths = _resolve_bundle_sdk_paths(repository_ctx)
    elif cfg.path:
        bundle_path = repository_ctx.path(cfg.path)
        if not bundle_path.exists:
            fail(
                "xtool_darwin_sdk_repo: configured darwin.artifactbundle path '%s' does not exist." % cfg.path,
            )
        repository_ctx.symlink(bundle_path, "sdk")
        sdk_available = True
        sdk_paths = _resolve_bundle_sdk_paths(repository_ctx)

    if cfg.swift_toolchain_path:
        tc_path = repository_ctx.path(cfg.swift_toolchain_path)
        if not tc_path.exists:
            fail(
                "xtool_darwin_sdk_repo: configured swift_toolchain_path '%s' does not exist." % cfg.swift_toolchain_path,
            )
        usr_bin = tc_path.get_child("usr").get_child("bin")
        bin_dir = tc_path.get_child("bin")
        bin_target = usr_bin if usr_bin.exists else (bin_dir if bin_dir.exists else tc_path)
        repository_ctx.symlink(bin_target, "swift_bin")
        swift_bin_dir = "swift_bin"

    _write_wrapper_scripts(repository_ctx, sdk_available, sdk_paths, swift_bin_dir)
    repository_ctx.file(
        "BUILD.bazel",
        generate_xtool_darwin_sdk_build(
            sdk_available = sdk_available,
            sdk_paths = sdk_paths,
            swift_bin_dir = swift_bin_dir,
        ),
    )

xtool_darwin_sdk_repo = repository_rule(
    implementation = _xtool_darwin_sdk_repo_impl,
    attrs = {
        "path": attr.string(
            doc = "Optional local filesystem path to `darwin.artifactbundle` (local, non-hermetic).",
            default = "",
        ),
        "url": attr.string(
            doc = "Optional URL to download `darwin.artifactbundle` archive (hermetic; requires `sha256`).",
            default = "",
        ),
        "sha256": attr.string(
            doc = "Required SHA-256 checksum when `url` is specified.",
            default = "",
        ),
        "swift_toolchain_path": attr.string(
            doc = "Optional local path to the Linux Swift toolchain root directory (non-hermetic).",
            default = "",
        ),
    },
    doc = "Configures the xtool Darwin SDK (iPhoneOS.sdk, iPhoneSimulator.sdk, MacOSX.sdk) and Linux -> Darwin C++/Swift cross-toolchains.",
)
