"""Hermetic Apple framework import and application bundle rules for the `xtool` backend.

Provides:
  - `flutter_darwin_xcframework_import`: Host-agnostic `.xcframework` /
    `.framework` import rule returning `DefaultInfo`, `CcInfo`,
    `AppleFrameworkImportInfo`, and `FlutterDarwinFrameworkInfo`.
  - `flutter_xtool_ios_bundle`: Assembles an unsigned `.ipa`
    (`Payload/<App>.app`) using `//flutter/private/tools:xtool_pack` without
    Xcode, or signs it when `zsign` is provided.
  - `flutter_xtool_macos_bundle`: Assembles an unsigned `.app.zip`
    (`<App>.app/Contents/...`) using `//flutter/private/tools:xtool_pack`
    without Xcode, or signs it when `zsign` is provided.
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
# buildifier: disable=bzl-visibility
load("@rules_apple//apple/internal:framework_import_support.bzl", "framework_import_support")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:providers.bzl", "FlutterDarwinFrameworkInfo")
load(":constants.bzl", "IOS_MINIMUM_OS_VERSION", "MACOS_MINIMUM_OS_VERSION")
load(":xtool_darwin_sdk_repo.bzl", "FlutterXtoolSdkInfo")

# -- Transitions ---------------------------------------------------------------

def _xtool_ios_transition_impl(settings, _attr):
    comp_mode = settings["//command_line_option:compilation_mode"]
    current_platforms = settings["//command_line_option:platforms"]
    target_platform = str(Label("//flutter/platforms:ios_arm64"))
    if comp_mode == "dbg":
        target_platform = str(Label("//flutter/platforms:ios_x64"))
    for p in current_platforms:
        p_str = str(p)
        if p_str.endswith(":ios_arm64") or p_str.endswith(":ios_x64"):
            target_platform = p_str
            break
    return {
        "//command_line_option:platforms": [target_platform],
        "//flutter/settings:apple_backend": "xtool",
    }

_xtool_ios_transition = transition(
    implementation = _xtool_ios_transition_impl,
    inputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
    ],
    outputs = [
        "//command_line_option:platforms",
        "//flutter/settings:apple_backend",
    ],
)

def _xtool_macos_transition_impl(settings, _attr):
    current_platforms = settings["//command_line_option:platforms"]
    target_platform = str(Label("//flutter/platforms:macos_arm64"))
    for p in current_platforms:
        p_str = str(p)
        if p_str.endswith(":macos_arm64") or p_str.endswith(":macos_x64"):
            target_platform = p_str
            break
    return {
        "//command_line_option:platforms": [target_platform],
        "//flutter/settings:apple_backend": "xtool",
    }

_xtool_macos_transition = transition(
    implementation = _xtool_macos_transition_impl,
    inputs = [
        "//command_line_option:platforms",
    ],
    outputs = [
        "//command_line_option:platforms",
        "//flutter/settings:apple_backend",
    ],
)

# -- flutter_darwin_xcframework_import -----------------------------------------

def _infer_framework_name(files, explicit_name, fallback_name):
    if explicit_name:
        return explicit_name
    for f in files:
        for segment in f.path.split("/"):
            if segment.endswith(".framework"):
                return segment[:-len(".framework")]
            if segment.endswith(".xcframework"):
                return segment[:-len(".xcframework")]
    return fallback_name

def _select_framework_dir_and_headers(files, target_arch, is_simulator):
    framework_dirs = []
    headers = []
    include_dirs = {}
    framework_search_dirs = {}

    for f in files:
        path = f.path
        if f.is_directory and (path.endswith(".framework") or path.endswith(".xcframework")):
            if path not in framework_dirs:
                framework_dirs.append(path)

        parts = path.split("/")
        for idx, part in enumerate(parts):
            if part.endswith(".framework"):
                fw_dir = "/".join(parts[:idx + 1])
                parent_dir = "/".join(parts[:idx])
                if fw_dir not in framework_dirs:
                    framework_dirs.append(fw_dir)
                if parent_dir:
                    framework_search_dirs[parent_dir] = True
            if part == "Headers" and idx > 0 and (
                parts[idx - 1].endswith(".framework") or
                (idx >= 3 and parts[idx - 2] == "Versions")
            ):
                include_dirs["/".join(parts[:idx + 1])] = True

        if path.endswith(".h"):
            headers.append(f)

    # Prefer a slice matching simulator vs device when multiple slices exist in an xcframework.
    chosen_dir = ""
    if framework_dirs:
        chosen_dir = framework_dirs[0]
        for candidate in framework_dirs:
            lower = candidate.lower()
            if is_simulator and "simulator" in lower:
                chosen_dir = candidate
                break
            if not is_simulator and "ios-" in lower and "simulator" not in lower:
                chosen_dir = candidate
                break
            if "macos-" in lower:
                chosen_dir = candidate
                break
            if target_arch and target_arch in lower and "simulator" not in lower:
                chosen_dir = candidate

    if not chosen_dir and files:
        chosen_dir = files[0].dirname

    return chosen_dir, headers, include_dirs.keys(), framework_search_dirs.keys()

def _flutter_darwin_xcframework_import_impl(ctx):
    all_files = ctx.files.xcframework_imports
    target_arch = apple_support.target_arch_from_rule_ctx(ctx)
    is_simulator = (target_arch == "x86_64") and ("ios" in ctx.bin_dir.path)

    framework_name = _infer_framework_name(
        all_files,
        ctx.attr.framework_name,
        ctx.label.name,
    )
    framework_dir, headers, include_dirs, fw_search_dirs = _select_framework_dir_and_headers(
        all_files,
        target_arch,
        is_simulator,
    )

    cc_info = CcInfo(
        compilation_context = cc_common.create_compilation_context(
            headers = depset(headers),
            includes = depset(include_dirs),
            framework_includes = depset(fw_search_dirs),
        ),
    )

    return [
        DefaultInfo(files = depset(all_files)),
        cc_info,
        framework_import_support.framework_import_info_with_dependencies(
            build_archs = [target_arch] if target_arch else ["arm64"],
            deps = [],
            framework_imports = all_files,
        ),
        FlutterDarwinFrameworkInfo(
            framework_name = framework_name,
            framework_files = depset(all_files),
            framework_dir = framework_dir,
            headers = depset(headers),
            is_dynamic = ctx.attr.is_dynamic,
        ),
    ]

flutter_darwin_xcframework_import = rule(
    implementation = _flutter_darwin_xcframework_import_impl,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        {
            "xcframework_imports": attr.label_list(
                allow_files = True,
                mandatory = True,
                doc = "Files comprising the .xcframework or .framework bundle.",
            ),
            "framework_name": attr.string(
                default = "",
                doc = "Explicit framework name (e.g. 'Flutter' or 'FlutterMacOS'). Inferred when omitted.",
            ),
            "is_dynamic": attr.bool(
                default = True,
                doc = "Whether the imported framework is a dynamic framework.",
            ),
        },
    ),
    provides = [
        DefaultInfo,
        CcInfo,
        FlutterDarwinFrameworkInfo,
    ],
    doc = "Host-agnostic Darwin .xcframework / .framework import rule for the xtool backend.",
)

# -- Shared bundle helpers -----------------------------------------------------

def _collect_framework_args_and_inputs(framework_targets):
    framework_dirs = []
    seen_dirs = {}
    direct_inputs = []
    transitive_inputs = []

    for target in framework_targets:
        if FlutterDarwinFrameworkInfo in target:
            fw_info = target[FlutterDarwinFrameworkInfo]
            transitive_inputs.append(fw_info.framework_files)
            if fw_info.framework_dir and fw_info.framework_dir not in seen_dirs:
                seen_dirs[fw_info.framework_dir] = True
                framework_dirs.append(fw_info.framework_dir)
        else:
            files = target[DefaultInfo].files.to_list()
            direct_inputs.extend(files)
            for f in files:
                if f.is_directory:
                    if f.path not in seen_dirs:
                        seen_dirs[f.path] = True
                        framework_dirs.append(f.path)
                else:
                    parts = f.path.split("/")
                    for idx, part in enumerate(parts):
                        if part.endswith(".xcframework") or part.endswith(".framework"):
                            candidate = "/".join(parts[:idx + 1])
                            if candidate not in seen_dirs:
                                seen_dirs[candidate] = True
                                framework_dirs.append(candidate)
                            break

    return framework_dirs, direct_inputs, transitive_inputs

def _collect_runner_compile_inputs(ctx):
    sources = []
    headers = []
    modulemaps = []
    seen = {}
    transitive_sets = []

    def _add_file(f):
        if f.path in seen:
            return
        seen[f.path] = True
        if f.path.endswith(".swift") or f.path.endswith(".m") or f.path.endswith(".mm") or f.path.endswith(".c") or f.path.endswith(".cc") or f.path.endswith(".cpp"):
            sources.append(f)
        elif f.path.endswith(".h"):
            headers.append(f)
        elif f.path.endswith(".modulemap"):
            modulemaps.append(f)

    for f in ctx.files.srcs:
        _add_file(f)
    for f in ctx.files.registrant:
        _add_file(f)

    for target in ctx.attr.plugins + ctx.attr.deps:
        for f in target[DefaultInfo].files.to_list():
            _add_file(f)
        if CcInfo in target:
            cc_hdrs = target[CcInfo].compilation_context.headers
            transitive_sets.append(cc_hdrs)
            for f in cc_hdrs.to_list():
                _add_file(f)

    return sources, headers, modulemaps, transitive_sets

def _run_xtool_pack_bundle(
        ctx,
        *,
        platform,
        archive_ext,
        mnemonic,
        extra_resources = []):
    app_name = ctx.attr.app_name if ctx.attr.app_name else ctx.label.name
    archive_file = ctx.actions.declare_file("%s%s" % (ctx.label.name, archive_ext))
    app_dir = ctx.actions.declare_directory("%s_bundle/%s.app" % (ctx.label.name, app_name))

    infoplists = ctx.files.infoplists
    resources = ctx.files.resources + extra_resources

    fw_dirs, fw_direct_inputs, fw_transitive_inputs = _collect_framework_args_and_inputs(
        ctx.attr.frameworks,
    )

    target_arch = apple_support.target_arch_from_rule_ctx(ctx)
    arch = target_arch if target_arch in ("arm64", "x86_64") else "arm64"

    executable_file = ctx.file.executable
    if not executable_file:
        executable_file = ctx.actions.declare_file("%s_runner_bin" % ctx.label.name)
        sources, headers, modulemaps, plugin_transitive_sets = _collect_runner_compile_inputs(ctx)

        sdk_available = False
        sdk_transitive = []
        if ctx.attr._xtool_sdk_status and FlutterXtoolSdkInfo in ctx.attr._xtool_sdk_status:
            sdk_info = ctx.attr._xtool_sdk_status[FlutterXtoolSdkInfo]
            sdk_available = sdk_info.sdk_available
            sdk_transitive.append(sdk_info.sdk_files)

        runner_args = ctx.actions.args()
        runner_args.add("compile-runner")
        runner_args.add("--platform", platform)
        runner_args.add("--arch", arch)
        runner_args.add("--app-name", app_name)
        runner_args.add("--minimum-os-version", ctx.attr.minimum_os_version)
        runner_args.add("--sdk-available", "true" if sdk_available else "false")
        runner_args.add("--output", executable_file.path)

        for src in sources:
            runner_args.add("--source", src.path)
        for hdr in headers:
            runner_args.add("--header", hdr.path)
        for mm in modulemaps:
            runner_args.add("--modulemap", mm.path)
        for fw_dir in fw_dirs:
            runner_args.add("--framework", fw_dir)

        ctx.actions.run(
            executable = ctx.executable._xtool_pack,
            arguments = [runner_args],
            inputs = depset(
                direct = sources + headers + modulemaps + fw_direct_inputs,
                transitive = fw_transitive_inputs + plugin_transitive_sets + sdk_transitive,
            ),
            outputs = [executable_file],
            mnemonic = "FlutterXtoolRunner",
            progress_message = "Compiling runner executable for %s (%s) via xtool_pack" % (ctx.label, platform),
        )

    args = ctx.actions.args()
    args.add("bundle")
    args.add("--platform", platform)
    args.add("--app-name", app_name)
    args.add("--bundle-id", ctx.attr.bundle_id)
    args.add("--executable", executable_file.path)
    args.add("--minimum-os-version", ctx.attr.minimum_os_version)
    args.add("--output-archive", archive_file.path)
    args.add("--output-app-dir", app_dir.path)

    for plist in infoplists:
        args.add("--info-plist", plist.path)

    for fw_dir in fw_dirs:
        args.add("--framework", fw_dir)

    for res in resources:
        args.add("--resource", res.path)

    direct_inputs = [executable_file] + infoplists + resources + fw_direct_inputs

    if ctx.file.provisioning_profile:
        args.add("--provisioning-profile", ctx.file.provisioning_profile.path)
        direct_inputs.append(ctx.file.provisioning_profile)

    if ctx.file.entitlements:
        args.add("--entitlements", ctx.file.entitlements.path)
        direct_inputs.append(ctx.file.entitlements)

    if ctx.executable.zsign:
        args.add("--zsign", ctx.executable.zsign.path)
        direct_inputs.append(ctx.executable.zsign)

    if ctx.file.certificate:
        args.add("--certificate", ctx.file.certificate.path)
        direct_inputs.append(ctx.file.certificate)

    if ctx.attr.certificate_password:
        args.add("--certificate-password", ctx.attr.certificate_password)

    ctx.actions.run(
        executable = ctx.executable._xtool_pack,
        arguments = [args],
        inputs = depset(
            direct = direct_inputs,
            transitive = fw_transitive_inputs,
        ),
        outputs = [archive_file, app_dir],
        mnemonic = mnemonic,
        progress_message = "Packaging %s (%s) via xtool_pack" % (ctx.label, platform),
    )

    return [
        DefaultInfo(
            files = depset([archive_file]),
            runfiles = ctx.runfiles(files = [archive_file]),
        ),
        OutputGroupInfo(
            archive = depset([archive_file]),
            app_dir = depset([app_dir]),
            runner_binary = depset([executable_file]),
        ),
    ]

# -- flutter_xtool_ios_bundle --------------------------------------------------

def _flutter_xtool_ios_bundle_impl(ctx):
    target_arch = apple_support.target_arch_from_rule_ctx(ctx)
    is_sim = (target_arch == "x86_64") or (ctx.var.get("COMPILATION_MODE", "") == "dbg")
    platform = "ios_sim" if is_sim else "ios"
    return _run_xtool_pack_bundle(
        ctx,
        platform = platform,
        archive_ext = ".ipa",
        mnemonic = "FlutterXtoolIosBundle",
    )

_COMMON_BUNDLE_ATTRS = {
    "app_name": attr.string(
        default = "",
        doc = "Application bundle name (`<app_name>.app`). Defaults to the target name.",
    ),
    "bundle_id": attr.string(
        mandatory = True,
        doc = "Bundle identifier (e.g. `com.example.app`).",
    ),
    "infoplists": attr.label_list(
        allow_files = [".plist"],
        default = [],
        doc = "List of `Info.plist` files to merge and variable-substitute into the bundle.",
    ),
    "executable": attr.label(
        allow_single_file = True,
        doc = "Optional pre-compiled Mach-O main executable binary. When omitted, `FlutterXtoolRunner` compiles/synthesizes the runner from `srcs`, `registrant`, `plugins`, and `deps`.",
    ),
    "srcs": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Runner Swift/ObjC source files compiled by `FlutterXtoolRunner` when `executable` is omitted.",
    ),
    "registrant": attr.label(
        allow_files = True,
        doc = "GeneratedPluginRegistrant target compiled into the runner.",
    ),
    "plugins": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Apple plugin aggregator or plugin library targets linked into the runner.",
    ),
    "deps": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Additional runner library targets.",
    ),
    "_xtool_sdk_status": attr.label(
        default = Label("@flutter_xtool_darwin_sdk//:sdk_status"),
    ),
    "frameworks": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Framework targets (`FlutterDarwinFrameworkInfo` or `.framework`/`.xcframework` files) to embed in `Frameworks/`.",
    ),
    "resources": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Additional resource files or directories to copy into the bundle.",
    ),
    "provisioning_profile": attr.label(
        allow_single_file = True,
        doc = "Optional `.mobileprovision` file to embed as `embedded.mobileprovision`.",
    ),
    "entitlements": attr.label(
        allow_single_file = [".plist", ".entitlements"],
        doc = "Optional entitlements plist passed to `zsign` when signing.",
    ),
    "zsign": attr.label(
        executable = True,
        cfg = "exec",
        doc = "Optional `zsign` executable for cryptographic code signing.",
    ),
    "certificate": attr.label(
        allow_single_file = True,
        doc = "Optional signing certificate (`.p12` or `.pem`) for `zsign`.",
    ),
    "certificate_password": attr.string(
        default = "",
        doc = "Optional password for `certificate`.",
    ),
    "_xtool_pack": attr.label(
        default = Label("//flutter/private/tools:xtool_pack"),
        executable = True,
        cfg = "exec",
    ),
    "_allowlist_function_transition": attr.label(
        default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
    ),
}

flutter_xtool_ios_bundle = rule(
    implementation = _flutter_xtool_ios_bundle_impl,
    cfg = _xtool_ios_transition,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        _COMMON_BUNDLE_ATTRS,
        {
            "minimum_os_version": attr.string(
                default = IOS_MINIMUM_OS_VERSION,
                doc = "Minimum iOS deployment target version.",
            ),
        },
    ),
    doc = "Packages an iOS application into an unsigned `.ipa` (`Payload/<App>.app`) using the host-agnostic `xtool_pack` bundler, or signs it when `zsign` is provided.",
)

# -- flutter_xtool_macos_bundle ------------------------------------------------

def _flutter_xtool_macos_bundle_impl(ctx):
    return _run_xtool_pack_bundle(
        ctx,
        platform = "macos",
        archive_ext = ".app.zip",
        mnemonic = "FlutterXtoolMacosBundle",
        extra_resources = ctx.files.native_libs,
    )

flutter_xtool_macos_bundle = rule(
    implementation = _flutter_xtool_macos_bundle_impl,
    cfg = _xtool_macos_transition,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        _COMMON_BUNDLE_ATTRS,
        {
            "minimum_os_version": attr.string(
                default = MACOS_MINIMUM_OS_VERSION,
                doc = "Minimum macOS deployment target version.",
            ),
            "native_libs": attr.label_list(
                allow_files = True,
                default = [],
                doc = "Optional staged native dynamic libraries (`flutter_macos_native_libs`).",
            ),
        },
    ),
    doc = "Packages a macOS application into an unsigned `.app.zip` (`<App>.app/Contents/...`) using the host-agnostic `xtool_pack` bundler, or signs it when `zsign` is provided.",
)
