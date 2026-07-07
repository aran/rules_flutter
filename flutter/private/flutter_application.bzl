"""Common Flutter application compilation pipeline.

Chains: sources → kernel .dill → AOT native code → asset bundle.

In debug mode (-c dbg): produces kernel .dill + assets (JIT, no gen_snapshot).
In fastbuild/opt mode: produces AOT native code + assets (release).

This rule produces outputs that platform-specific wrappers consume:
1. AOT compiled native code (.so/.dylib) or kernel .dill (debug)
2. flutter_assets/ tree artifact
3. ICU data file (icudtl.dat)
"""

load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterInfo")
load("//flutter/private:common.bzl", "FLUTTER_APPLICATION_ATTRS", "PLATFORM_CONSTRAINT_ATTRS", "collect_native_libs", "detect_target_platform", "flutter_build_assets", "flutter_compile_kernel", "flutter_compile_shaders", "host_target_arch")
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_elf_action", "flutter_aot_macho_action")
load("//flutter/private:flutter_library.bzl", "dedup_plugins")
load("//flutter/private:flutter_native_assets.bzl", "collect_bundled_code_asset_files", "write_native_assets_manifest")

def _flutter_application_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    bazel_mode = ctx.var["COMPILATION_MODE"]
    is_profile = ctx.attr.profile
    is_debug = bazel_mode == "dbg" and not is_profile
    strip = bazel_mode == "opt" and not is_profile

    # Guard: AOT cross-compilation between desktop OSes is not supported.
    # gen_snapshot can only produce native code for the host OS.
    # target_os is non-empty only for cross-compilation toolchains.
    if not is_debug and flutter_sdk_info.target_os in ("linux", "macos", "windows"):
        fail(
            "AOT cross-compilation between desktop platforms is not supported. " +
            "Flutter's gen_snapshot can only produce native code for the host OS. " +
            "Build on the target platform, or use debug mode (-c dbg).",
        )

    # Detect the target platform for platform-aware plugin registration.
    is_macos = ctx.target_platform_has_constraint(
        ctx.attr._macos_constraint[platform_common.ConstraintValueInfo],
    )
    is_ios = ctx.target_platform_has_constraint(
        ctx.attr._ios_constraint[platform_common.ConstraintValueInfo],
    )
    is_linux = ctx.target_platform_has_constraint(
        ctx.attr._linux_constraint[platform_common.ConstraintValueInfo],
    )
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    is_android = ctx.target_platform_has_constraint(
        ctx.attr._android_constraint[platform_common.ConstraintValueInfo],
    )
    target_platform = detect_target_platform(is_ios, is_macos, is_linux, is_windows, is_android)

    # Aggregate transitive Native Assets so the manifest exists before
    # kernel compile (the frontend_server reads it via --native-assets).
    transitive_native_asset_depsets = []
    transitive_data_asset_depsets = []
    for dep in ctx.attr.deps:
        if FlutterInfo not in dep:
            continue
        info = dep[FlutterInfo]
        if hasattr(info, "native_assets") and info.native_assets != None:
            transitive_native_asset_depsets.append(info.native_assets)
        if hasattr(info, "data_assets") and info.data_assets != None:
            transitive_data_asset_depsets.append(info.data_assets)
    transitive_native_assets = depset(transitive = transitive_native_asset_depsets)
    transitive_data_assets = depset(transitive = transitive_data_asset_depsets)
    native_assets_list = transitive_native_assets.to_list()

    target_arch = host_target_arch(ctx, flutter_sdk_info)
    native_assets_manifest_file = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
    write_native_assets_manifest(
        ctx = ctx,
        output_file = native_assets_manifest_file,
        native_assets = native_assets_list,
        target_os = target_platform,
        target_arch = target_arch,
    )

    bundled_code_assets = collect_bundled_code_asset_files(
        native_assets_list,
        target_platform,
    )

    # Step 1: Kernel compilation (mode-aware: debug uses debug dill, no AOT).
    compilation = flutter_compile_kernel(
        ctx,
        flutter_sdk_info,
        target_platform = target_platform,
        native_assets_manifest = native_assets_manifest_file,
    )
    kernel_dill = compilation.kernel_dill
    package_config = compilation.package_config

    aot_output = None
    debug_info_output = None
    if not is_debug:
        # Collect gen_snapshot extra flags from user attrs.
        extra_flags = list(ctx.attr.extra_gen_snapshot_options)
        extra_outputs = []
        if is_profile:
            extra_flags.append("--no-causal-async-stacks")
        if ctx.attr.obfuscate:
            extra_flags.append("--obfuscate")
        if ctx.attr.split_debug_info:
            debug_info_output = ctx.actions.declare_file(ctx.label.name + ".symbols")
            extra_flags.extend(["--dwarf-stack-traces", "--resolve-dwarf-paths", "--save-debugging-info=" + debug_info_output.path])
            extra_outputs.append(debug_info_output)

        # Step 2: AOT compile — choose format based on target platform.
        if is_ios or is_macos:
            aot_output = ctx.actions.declare_file(ctx.label.name + ".dylib")
            flutter_aot_macho_action(
                ctx = ctx,
                gen_snapshot = flutter_sdk_info.gen_snapshot,
                flutter_sdk_files = flutter_sdk_info.tool_files,
                kernel_dill = kernel_dill,
                output = aot_output,
                strip = strip,
                extra_flags = extra_flags,
                extra_outputs = extra_outputs,
                min_os_version = ctx.attr.min_os_version if ctx.attr.min_os_version else None,
            )
        else:
            aot_output = ctx.actions.declare_file(ctx.label.name + ".so")
            flutter_aot_elf_action(
                ctx = ctx,
                gen_snapshot = flutter_sdk_info.gen_snapshot,
                flutter_sdk_files = flutter_sdk_info.tool_files,
                kernel_dill = kernel_dill,
                output = aot_output,
                strip = strip,
                extra_flags = extra_flags,
                extra_outputs = extra_outputs,
            )

    # Collect native shared libraries from native_deps + transitive plugin deps.
    native_libs = collect_native_libs(ctx.attr.native_deps)
    transitive_native_depsets = [
        dep[FlutterInfo].transitive_native_libs
        for dep in ctx.attr.deps
        if FlutterInfo in dep
    ]
    if transitive_native_depsets:
        native_libs.extend(depset(transitive = transitive_native_depsets).to_list())

    # Step 3: Shader compilation + asset bundle. Pass data assets so the
    # bundler places them under flutter_assets/data/<pkg>/<name>.
    compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, target_platform)
    flutter_assets = flutter_build_assets(
        ctx,
        flutter_sdk_info,
        compiled_shaders,
        kernel_dill = kernel_dill,
        is_debug = is_debug,
        data_assets = transitive_data_assets,
    )

    # Collect plugins from deps for FlutterInfo propagation.
    all_dep_plugins = []
    apple_plugin_lib_depsets = []
    linux_plugin_lib_depsets = []
    windows_plugin_lib_depsets = []
    android_plugin_lib_depsets = []
    apple_privacy_manifest_depsets = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
            apple_plugin_lib_depsets.append(dep[FlutterInfo].apple_plugin_libraries)
            linux_plugin_lib_depsets.append(dep[FlutterInfo].linux_plugin_libraries)
            windows_plugin_lib_depsets.append(dep[FlutterInfo].windows_plugin_libraries)
            android_plugin_lib_depsets.append(dep[FlutterInfo].android_plugin_libraries)
            if hasattr(dep[FlutterInfo], "apple_privacy_manifests") and dep[FlutterInfo].apple_privacy_manifests != None:
                apple_privacy_manifest_depsets.append(dep[FlutterInfo].apple_privacy_manifests)
    all_plugins = dedup_plugins(all_dep_plugins)
    apple_plugin_libraries = depset(transitive = apple_plugin_lib_depsets)
    linux_plugin_libraries = depset(transitive = linux_plugin_lib_depsets)
    windows_plugin_libraries = depset(transitive = windows_plugin_lib_depsets)
    android_plugin_libraries = depset(transitive = android_plugin_lib_depsets)
    apple_privacy_manifests = depset(transitive = apple_privacy_manifest_depsets)

    default_files = [flutter_assets, package_config, native_assets_manifest_file] + native_libs
    if aot_output:
        default_files.append(aot_output)
    if is_debug:
        default_files.append(kernel_dill)

    # Hot-reload dev config (debug only), mirroring flutter_web_application's
    # `_dev_config.json`. Tells the dev tool the authoritative entrypoint URI
    # and — for a source-assembled (codegen) app — the multi-root layout +
    # generated source paths/URIs, so it never infers any of this from
    # package_config rootUri shapes. The dev tool discovers this by building the
    # flutter_application target directly (its DefaultInfo). When
    # `generatedSourceUris` is non-empty the dev tool rebuilds this same app
    # target on change to regenerate codegen outputs (a narrow codegen-only
    # rebuild would prune the flutter SDK from the execroot symlink forest and
    # break the next full compile).
    if is_debug and compilation.dev_package_config != None:
        dev_config_file = ctx.actions.declare_file(ctx.label.name + "_dev_config.json")
        ctx.actions.write(
            output = dev_config_file,
            content = json.encode({
                "engineRevision": flutter_sdk_info.engine_revision,
                "flutterVersion": flutter_sdk_info.version,
                "dartSdkRoot": flutter_sdk_info.dartaotruntime.path.rsplit("/bin/", 1)[0],
                "dartaotruntime": flutter_sdk_info.dartaotruntime.path,
                "frontendServer": flutter_sdk_info.frontend_server.path,
                "patchedSdkRoot": flutter_sdk_info.platform_kernel_dill.path.rsplit("/", 1)[0],
                "appEntrypoint": compilation.app_entrypoint_uri,
                # Merged user defines (attr + extra_dart_defines flag). The
                # dev tool replays these as -D on its resident frontend_server
                # so hot reload/restart recompiles keep the same environment.
                "dartDefines": compilation.dart_defines,
                "devPackageConfig": compilation.dev_package_config.path,
                "filesystemRoots": compilation.dev_filesystem_roots,
                "filesystemScheme": compilation.dev_filesystem_scheme,
                "generatedSourcePaths": compilation.dev_generated_source_paths,
                "generatedSourceUris": compilation.dev_generated_source_uris,
                # First-party source packages (app + local deps) the dev tool
                # maps live edits back to via its PackageUriResolver. libRoot is
                # workspace-relative.
                "sourcePackages": [
                    {"name": sp[0], "libRoot": sp[1]}
                    for sp in compilation.dev_source_packages
                ],
            }),
        )
        default_files.append(dev_config_file)
        default_files.append(compilation.dev_package_config)

    output_groups = {
        "native_assets_manifest": depset([native_assets_manifest_file]),
        "bundled_code_assets": bundled_code_assets,
    }
    if debug_info_output:
        output_groups["debug_info"] = depset([debug_info_output])

    providers = [
        DefaultInfo(files = depset(default_files)),
        FlutterApplicationInfo(
            aot_output = aot_output,
            kernel_dill = kernel_dill if is_debug else None,
            flutter_assets = flutter_assets,
            icu_data = flutter_sdk_info.icu_data,
            native_libs = native_libs,
            is_debug = is_debug,
            package_config = package_config,
            native_assets_manifest = native_assets_manifest_file,
            bundled_code_assets = bundled_code_assets,
            bundled_data_assets = transitive_data_assets,
            apple_privacy_manifests = apple_privacy_manifests,
        ),
        FlutterInfo(
            plugins = all_plugins,
            asset_dirs = depset(),
            shader_srcs = depset(),
            transitive_native_libs = depset(),
            apple_plugin_libraries = apple_plugin_libraries,
            linux_plugin_libraries = linux_plugin_libraries,
            windows_plugin_libraries = windows_plugin_libraries,
            android_plugin_libraries = android_plugin_libraries,
            apple_privacy_manifests = apple_privacy_manifests,
            native_assets = transitive_native_assets,
            data_assets = transitive_data_assets,
            pub_fonts = depset(),
            pub_assets = depset(),
            pub_shaders = depset(),
        ),
    ]
    providers.append(OutputGroupInfo(**output_groups))
    return providers

flutter_application = rule(
    implementation = _flutter_application_impl,
    attrs = dict(FLUTTER_APPLICATION_ATTRS, **PLATFORM_CONSTRAINT_ATTRS),
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles a Flutter application to AOT native code + asset bundle (release) or kernel .dill + assets (debug).",
)
