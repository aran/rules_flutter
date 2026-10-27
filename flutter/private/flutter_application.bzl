"""Common Flutter application compilation pipeline.

Chains: sources → kernel .dill → AOT native code → asset bundle.

In debug mode (-c dbg): produces kernel .dill + assets (JIT, no gen_snapshot).
In fastbuild/opt mode: produces AOT native code + assets (release).
With -c opt and `--@rules_flutter//flutter:profile`: AOT for profile mode,
compiled by the profile gen_snapshot the toolchain selects.

This rule produces outputs that platform-specific wrappers consume:
1. AOT compiled native code (.so/.dylib) or kernel .dill (debug)
2. flutter_assets/ tree artifact
3. ICU data file (icudtl.dat)
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo")
load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "dart_link_hook_actions", "link_hook_runner_attr")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterInfo")
load("//flutter/private:code_asset_libraries.bzl", "code_asset_libraries", "code_asset_libraries_aspect", "describe_code_asset_libraries")
load("//flutter/private:common.bzl", "FLUTTER_APPLICATION_ATTRS", "PLATFORM_CONSTRAINT_ATTRS", "check_unreplaced_hooks", "collect_binding_contracts", "collect_native_libs", "declare_flutter_assets_dir", "detect_target_platform", "flutter_build_assets", "flutter_build_mode", "flutter_compile_kernel", "flutter_compile_shaders", "flutter_deps_attr", "host_target_arch", "launch_build_args", "shader_sources")
load("//flutter/private:dev_config.bzl", "dev_config_file", "dev_search_roots", "dev_source_dir", "write_dev_config")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_elf_action", "flutter_aot_macho_action")
load("//flutter/private:flutter_info.bzl", "dedup_plugins")
load("//flutter/private:flutter_native_assets.bzl", "CODE_ASSETS_DOC", "collect_bundled_code_asset_files", "resolve_native_assets", "write_native_assets_manifest")
load("//flutter/private:native_sources.bzl", "collect_native_source_pairs")

def _flutter_application_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    mode = flutter_build_mode(ctx)
    is_debug = mode == "debug"

    # Profile strips like release, as `flutter build --profile` does: the
    # profiler names Dart code from the snapshot, not from native symbols.
    strip = ctx.var["COMPILATION_MODE"] == "opt"

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

    # A pub package that builds its native code with `hook/build.dart` has no
    # library to contribute unless something stands in for the hook. The
    # application is where that is knowable and where it matters: the whole
    # package closure is visible, and it is this target whose manifest would
    # otherwise be quietly short an entry and die at runtime on an unresolved
    # `@Native` symbol. Checked before any compilation so the build fails on
    # the cause rather than minutes later on a symptom.
    hook_err = check_unreplaced_hooks(ctx.label, ctx.attr.deps)
    if hook_err != None:
        fail(hook_err)

    # Aggregate transitive Native Assets so the manifest exists before
    # kernel compile (the frontend_server reads it via --native-assets).
    transitive_native_asset_depsets = []
    transitive_data_asset_depsets = []
    for dep in ctx.attr.deps:
        if FlutterInfo not in dep:
            continue
        info = dep[FlutterInfo]
        transitive_native_asset_depsets.append(info.native_assets)
        transitive_data_asset_depsets.append(info.data_assets)
    transitive_native_assets = depset(transitive = transitive_native_asset_depsets)
    transitive_data_assets = depset(transitive = transitive_data_asset_depsets)

    # Plus any code assets rules_dart propagated through the Dart package
    # graph — a pub package that owns a native library contributes it just by
    # being depended on — and those this target names in `code_assets`, which
    # replace whatever arrives under their ids. See `resolve_native_assets`.
    resolved_assets = resolve_native_assets(
        ctx,
        declared = transitive_native_assets.to_list(),
        deps = ctx.attr.deps,
        code_assets = [target[DartCodeAssetInfo] for target in ctx.attr.code_assets],
    )
    native_assets_list = resolved_assets.assets
    lifted_code_assets = resolved_assets.lifted

    target_arch = host_target_arch(ctx, flutter_sdk_info)
    native_assets_manifest_file = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
    write_native_assets_manifest(
        ctx = ctx,
        output_file = native_assets_manifest_file,
        native_assets = native_assets_list,
        target_os = target_platform,
        target_arch = target_arch,
    )

    bundled_code_assets = collect_bundled_code_asset_files(native_assets_list)

    # Declared before the kernel compile that will later feed it, because a
    # debug app carries this path inside itself: `flutter_compile_kernel`
    # bakes it into `rules_flutter.build_info.assetsDir`, and the dev tool
    # matches the running app's reported value against the tree it watches
    # and rebuilds. Declaring an output is independent of registering the
    # action that fills it, so the ordering costs nothing.
    flutter_assets = declare_flutter_assets_dir(ctx)

    # Link hooks run over the uses the AOT compile records, so only a
    # release or profile build has any: a JIT compile tree-shakes nothing and
    # records nothing, and a debug build runs no hook and bundles no asset.
    run_link_hooks = bool(ctx.attr.link_hook_assets) and not is_debug
    recorded_uses = ctx.actions.declare_file(ctx.label.name + ".recorded_uses.json") if run_link_hooks else None

    # Step 1: Kernel compilation (mode-aware: debug uses debug dill, no AOT).
    compilation = flutter_compile_kernel(
        ctx,
        portable_tools(ctx),
        target_platform = target_platform,
        native_assets_manifest = native_assets_manifest_file,
        track_widget_creation = ctx.attr.track_widget_creation,
        assets_dir = flutter_assets,
        recorded_uses = recorded_uses,
        platform_build_args = launch_build_args(
            target_platform,
            is_simulator = is_ios and apple_support.target_environment_from_rule_ctx(ctx) == "simulator",
            is_arm64 = ctx.target_platform_has_constraint(
                ctx.attr._arm64_constraint[platform_common.ConstraintValueInfo],
            ),
            is_x86_64 = ctx.target_platform_has_constraint(
                ctx.attr._x86_64_constraint[platform_common.ConstraintValueInfo],
            ),
        ),
    )
    kernel_dill = compilation.kernel_dill
    package_config = compilation.package_config

    aot_output = None
    debug_info_output = None
    if not is_debug:
        # Collect gen_snapshot extra flags from user attrs.
        extra_flags = list(ctx.attr.extra_gen_snapshot_options)
        if ctx.attr.obfuscate:
            extra_flags.append("--obfuscate")
        if ctx.attr.split_debug_info:
            debug_info_output = ctx.actions.declare_file(ctx.label.name + ".symbols")

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
                debug_info = debug_info_output,
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
                debug_info = debug_info_output,
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

    # Step 2b: package link hooks over the recorded uses. Each emits the data
    # assets declared in `link_hook_assets`, bundled below beside the native
    # assets' data assets.
    link_hook_validation = []
    if run_link_hooks:
        link = dart_link_hook_actions(
            ctx,
            runner = ctx.executable._link_hook_runner,
            recorded_uses = recorded_uses,
            deps = ctx.attr.deps,
            data_asset_ids = ctx.attr.link_hook_assets,
            name = ctx.label.name + "_link_hooks",
        )
        transitive_data_assets = depset(link.assets, transitive = [transitive_data_assets])
        link_hook_validation = link.validation_outputs

    # Step 3: Shader compilation + asset bundle. Pass data assets so the
    # bundler places them under flutter_assets/packages/<pkg>/<name>.
    compiled_shaders = flutter_compile_shaders(ctx, portable_tools(ctx), target_platform)
    flutter_build_assets(
        ctx,
        portable_tools(ctx),
        flutter_assets,
        compiled_shaders,
        kernel_dill = kernel_dill,
        is_debug = is_debug,
        data_assets = transitive_data_assets,
    )

    # Aggregate the plugin channels from deps. These are what the platform
    # registrant generators and desktop runners read back off this target —
    # via FlutterApplicationInfo, since an application is the end of the
    # library graph and does not contribute to another one.
    all_dep_plugins = []
    apple_plugin_lib_depsets = []
    linux_plugin_lib_depsets = []
    windows_plugin_lib_depsets = []
    apple_privacy_manifest_depsets = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
            apple_plugin_lib_depsets.append(dep[FlutterInfo].apple_plugin_libraries)
            linux_plugin_lib_depsets.append(dep[FlutterInfo].linux_plugin_libraries)
            windows_plugin_lib_depsets.append(dep[FlutterInfo].windows_plugin_libraries)
            apple_privacy_manifest_depsets.append(dep[FlutterInfo].apple_privacy_manifests)
    all_plugins = dedup_plugins(all_dep_plugins)
    apple_plugin_libraries = depset(transitive = apple_plugin_lib_depsets)
    linux_plugin_libraries = depset(transitive = linux_plugin_lib_depsets)
    windows_plugin_libraries = depset(transitive = windows_plugin_lib_depsets)
    apple_privacy_manifests = depset(transitive = apple_privacy_manifest_depsets)

    # Every loose native library this app carries, by both routes in: the
    # `native_deps` set above, and the Native Assets `CodeAsset` libraries
    # `native_assets.json` already points at. Deduplicated by path because
    # nothing stops one library arriving twice.
    bundled_native_libs = {}
    for lib in native_libs + bundled_code_assets.to_list():
        bundled_native_libs[lib.path] = lib

    # What each of those libraries' bindings were generated from, when its build
    # said so — see `flutter_native_library`. Keyed by the same paths, so a
    # library with no contract is an empty list rather than a missing key: the dev
    # tool has to tell "nothing describes this one" from "this one is not
    # bundled", and they mean opposite things for a reload.
    binding_contracts = {path: [] for path in bundled_native_libs}
    for pair in collect_binding_contracts(ctx.attr.native_deps) + [
        p
        for dep in ctx.attr.deps
        if FlutterInfo in dep
        for p in dep[FlutterInfo].binding_contracts.to_list()
    ]:
        if pair.library.path in binding_contracts:
            binding_contracts[pair.library.path] = list(pair.contract)

    # And what each is built from, on the same keys, so a reload can tell that a
    # library went stale in an app that runs no build of its own.
    native_lib_sources = {path: [] for path in bundled_native_libs}
    for pair in collect_native_source_pairs(ctx.attr.native_deps) + [
        p
        for dep in ctx.attr.deps
        if FlutterInfo in dep
        for p in dep[FlutterInfo].native_lib_sources.to_list()
    ]:
        if pair.library.path in native_lib_sources:
            native_lib_sources[pair.library.path] = list(pair.sources)

    # A code asset off the Dart package graph, or named in `code_assets`, is
    # bundled under this target's own name for it, so what its build declares
    # — a `flutter_native_library` wrapper's contract, and its sources either
    # way — is looked up by asset id and put on that name. See
    # `code_asset_libraries.bzl`.
    describe_code_asset_libraries(
        ctx.label,
        lifted_code_assets,
        code_asset_libraries(
            ctx.attr.deps,
            ctx.attr.code_assets,
            resolved_assets.libraries,
        ),
        binding_contracts,
        native_lib_sources,
        is_debug,
    )

    # The code-asset libraries join `default_files` with the manifest that names
    # them. Declaring an output is what makes its path true: the manifest is
    # built here and the dev tool reads these files back off this target, and a
    # path named by a build that did not write it fails far from its cause.
    default_files = [
        flutter_assets,
        package_config,
        native_assets_manifest_file,
    ] + bundled_native_libs.values()
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
        dartaotruntime = flutter_sdk_info.dartaotruntime
        platform_dill = flutter_sdk_info.platform_kernel_dill

        # Declares every build output the config names; see `dev_config.bzl`.
        default_files.extend(write_dev_config(
            ctx,
            ctx.actions.declare_file(ctx.label.name + "_dev_config.json"),
            {
                "engineRevision": flutter_sdk_info.engine_revision,
                "flutterVersion": flutter_sdk_info.version,
                "dartSdkRoot": dev_source_dir(dartaotruntime, dartaotruntime.path.rsplit("/bin/", 1)[0]),
                "dartaotruntime": dartaotruntime,
                "frontendServer": flutter_sdk_info.frontend_server,
                "patchedSdkRoot": dev_source_dir(platform_dill, platform_dill.dirname),
                "appEntrypoint": compilation.app_entrypoint_uri,
                # Merged user defines (attr + extra_dart_defines flag). The
                # dev tool replays these as -D on its resident frontend_server
                # so hot reload/restart recompiles keep the same environment.
                "dartDefines": compilation.dart_defines,
                # Generated plugin registrants, keyed by platform ("" when
                # that platform has no Dart plugins and no agent). One per
                # platform because this dev build runs in the host
                # configuration while the app can be running elsewhere; the dev tool selects by the platform the
                # app reports (build_info.targetPlatform), compiles that file
                # into its dills via --source, and advertises it with
                # -Dflutter.dart_plugin_registrant so the engine's pre-main
                # hook keeps firing — with the right plugin set — after hot
                # restart.
                "dartPluginRegistrants": {
                    platform: registrant or ""
                    for platform, registrant in compilation.dev_plugin_registrants.items()
                },
                "devPackageConfig": dev_config_file(
                    compilation.dev_package_config,
                    compilation.dev_package_config_names,
                ),
                "filesystemRoots": dev_search_roots(compilation.dev_filesystem_roots),
                "filesystemScheme": compilation.dev_filesystem_scheme,
                "generatedSourcePaths": compilation.dev_generated_sources,
                "generatedSourceUris": compilation.dev_generated_source_uris,
                # Every bundled shader, by bundle path, with the workspace
                # files it is compiled from. The dev tool watches those and
                # has the app reload a shader whose compiled bytes changed.
                "shaders": shader_sources(ctx),
                # The loose native libraries this build writes, from the
                # same list `default_files` carries so the two cannot drift —
                # `native_deps` and Native Assets code assets alike, because a
                # process maps both and can replace neither. A `dlopen`ing app has these mapped for the life
                # of its process, and a hot reload that rebuilds this target to
                # regenerate codegen sources rebuilds them too — so comparing
                # them across those rebuilds is how the dev tool learns that an
                # increment would be injected over stale machine code, without
                # paying a second build in the app's launch configuration.
                # Empty unless the app bundles `native_deps`.
                "nativeLibs": bundled_native_libs.values(),
                # Per library, the files its bindings were generated from. A
                # reload compares these bytes to decide whether an increment is
                # one the library the running process already has can serve —
                # see `NativeLibsWatch` in the dev tool. Empty list: nothing
                # declared, so the reload cannot know and will not guess.
                "nativeLibContracts": binding_contracts,
                # Per library, the first-party sources it is built from, so a
                # reload can see a native edit in an app that runs no build of
                # its own — every app without generated sources. Stat-ed on each
                # reload; see `native_sources.bzl`.
                "nativeLibSources": native_lib_sources,
                # First-party source packages (app + local deps) the dev tool
                # maps live edits back to via its SourceUriResolver. libRoot is
                # workspace-relative.
                "sourcePackages": [
                    {"name": sp[0], "libRoot": sp[1]}
                    for sp in compilation.dev_source_packages
                ],
                # The sources outside every package the app compiles under the
                # app scheme — a `main` outside its package's `lib/` and the
                # `srcs` beside it — with the URI the compiler keys each by.
                # Empty for a `main` with a `package:` URI.
                "appSources": compilation.dev_app_sources,
            },
        ))

    output_groups = {
        "native_assets_manifest": depset([native_assets_manifest_file]),
        "bundled_code_assets": bundled_code_assets,
    }
    if debug_info_output:
        output_groups["debug_info"] = depset([debug_info_output])

    # Every hook runs whenever the app builds, even one that emits no asset,
    # so its verdict on the program is never skipped.
    output_groups["_validation"] = depset(link_hook_validation, transitive = [compilation.import_checks])

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
            plugins = all_plugins,
            apple_plugin_libraries = apple_plugin_libraries,
            linux_plugin_libraries = linux_plugin_libraries,
            windows_plugin_libraries = windows_plugin_libraries,
        ),
    ]
    providers.append(OutputGroupInfo(**output_groups))
    return providers

flutter_application = rule(
    implementation = _flutter_application_impl,
    attrs = dicts.add(
        FLUTTER_APPLICATION_ATTRS,
        # The application is where a debug build's dev config is written, so
        # it is the one rule that needs to know, per code asset, what the
        # asset's own build declared about it.
        {
            "deps": flutter_deps_attr(aspects = [code_asset_libraries_aspect]),
            "code_assets": attr.label_list(
                doc = CODE_ASSETS_DOC,
                providers = [DartCodeAssetInfo],
                aspects = [code_asset_libraries_aspect],
            ),
        },
        PLATFORM_CONSTRAINT_ATTRS,
        link_hook_runner_attr(),
        # Simulator-vs-device is an Apple *environment* constraint, not an OS
        # one, so it needs apple_support's own attrs on top of the OS set.
        # `launch_build_args` turns it into `--ios_multi_cpus=sim_arm64` or
        # `=arm64`, which is the difference between a dev-loop rebuild landing
        # in the app's output tree and landing in one it never reads.
        apple_support.platform_constraint_attrs(),
    ),
    # The target's toolchain is for its AOT compile and engine files; every
    # compile whose output does not depend on the target is `portable`.
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Compiles a Flutter application to AOT native code + asset bundle (release) or kernel .dill + assets (debug).",
)
