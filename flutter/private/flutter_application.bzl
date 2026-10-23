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
load("@rules_dart//dart:utils.bzl", "dart_link_hook_actions", "link_hook_runner_attr")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterInfo")
load("//flutter/private:common.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "FLUTTER_APPLICATION_ATTRS", "PLATFORM_CONSTRAINT_ATTRS", "check_unreplaced_hooks", "collect_binding_contracts", "collect_native_libs", "declare_flutter_assets_dir", "detect_target_platform", "flutter_build_assets", "flutter_build_mode", "flutter_compile_kernel", "flutter_compile_shaders", "host_target_arch", "launch_build_args", "resolve_flutter_sdk_info", "shader_sources")
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_elf_action", "flutter_aot_gen_snapshot_flags", "flutter_aot_macho_action")
load("//flutter/private:flutter_info.bzl", "dedup_plugins")
load("//flutter/private:flutter_native_assets.bzl", "bridge_dart_code_assets", "collect_bundled_code_asset_files", "write_native_assets_manifest")
load("//flutter/private:native_sources.bzl", "collect_native_source_pairs")

def _check_aot_supported(flutter_sdk_info, is_debug):
    """Guards: AOT cross-compilation between desktop OSes is not supported.

    target_os is non-empty only for cross-compilation toolchains.
    """
    if not is_debug and flutter_sdk_info.target_os in ("linux", "macos", "windows"):
        fail(
            "AOT cross-compilation between desktop platforms is not supported. " +
            "Flutter's gen_snapshot can only produce native code for the host OS. " +
            "Build on the target platform, or use debug mode (-c dbg).",
        )
    if not is_debug and not flutter_sdk_info.gen_snapshot:
        fail(
            (
                "No target-compatible AOT gen_snapshot toolchain is registered for this " +
                "host and target platform (target_os=%s). Apple AOT snapshots require a " +
                "Darwin-target gen_snapshot on a macOS host; build on macOS or use debug mode (-c dbg)."
            ) % (
                flutter_sdk_info.target_os or "native",
            ),
        )

def _detect_application_platform(ctx):
    """Reads the platform constraints into flags plus a target-platform string."""
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
    return struct(
        target_platform = detect_target_platform(is_ios, is_macos, is_linux, is_windows, is_android),
        is_ios = is_ios,
        is_macos = is_macos,
    )

def _fail_on_unreplaced_hooks(ctx):
    """Fails naming the unreplaced `hook/build.dart` packages, if any.

    A pub package that builds its native code with `hook/build.dart` has no
    library to contribute unless something stands in for the hook. The
    application is where that is knowable and where it matters: the whole
    package closure is visible, and it is this target whose manifest would
    otherwise be quietly short an entry and die at runtime on an unresolved
    `@Native` symbol. Checked before any compilation so the build fails on
    the cause rather than minutes later on a symptom.
    """
    hook_err = check_unreplaced_hooks(ctx.label, ctx.attr.deps)
    if hook_err != None:
        fail(hook_err)

def _collect_transitive_assets(ctx):
    """Aggregates transitive Native Assets so the manifest exists before kernel compile.

    Plus any code assets rules_dart propagated through the Dart package
    graph — a pub package that owns a native library contributes it just by
    being depended on. Declarations made here with `flutter_native_asset`
    win, since they are the deliberate ones.

    Returns:
      A `(native_assets_list, transitive_data_assets)` tuple.
    """
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
    native_assets_list = transitive_native_assets.to_list()
    declared_ids = {asset.asset_id: True for asset in native_assets_list}
    native_assets_list = native_assets_list + [
        asset
        for asset in bridge_dart_code_assets(ctx, ctx.attr.deps)
        if asset.asset_id not in declared_ids
    ]
    return native_assets_list, transitive_data_assets

def _write_application_manifest(ctx, native_assets_list, target_platform, target_arch):
    """Declares and writes the `native_assets.json` manifest."""
    native_assets_manifest_file = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
    write_native_assets_manifest(
        ctx = ctx,
        output_file = native_assets_manifest_file,
        native_assets = native_assets_list,
        target_os = target_platform,
        target_arch = target_arch,
    )
    return native_assets_manifest_file

def _compile_application_kernel(ctx, flutter_sdk_info, target_platform, is_ios, native_assets_manifest_file, flutter_assets, recorded_uses):
    """Runs Step 1: mode-aware kernel compilation."""
    return flutter_compile_kernel(
        ctx,
        flutter_sdk_info,
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

def _compile_application_aot(ctx, flutter_sdk_info, is_debug, is_ios, is_macos, kernel_dill, strip):
    """Runs Step 2: AOT compile in the platform's format (release only).

    Collects gen_snapshot extra flags from user attrs (shared with
    flutter_aot_target so the two stay in step). Obfuscation forces
    `--strip`: unstripped DWARF would leak the original names.
    """
    if is_debug:
        return None, None, strip
    extra_flags, extra_outputs, debug_info_output, strip = flutter_aot_gen_snapshot_flags(ctx, strip)
    if is_ios or is_macos:
        aot_output = ctx.actions.declare_file(ctx.label.name + ".dylib")
        flutter_aot_macho_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
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
            kernel_dill = kernel_dill,
            output = aot_output,
            strip = strip,
            extra_flags = extra_flags,
            extra_outputs = extra_outputs,
        )
    return aot_output, debug_info_output, strip

def _collect_application_native_libs(ctx):
    """Collects native shared libraries from native_deps + transitive plugin deps."""
    native_libs = collect_native_libs(ctx.attr.native_deps)
    transitive_native_depsets = [
        dep[FlutterInfo].transitive_native_libs
        for dep in ctx.attr.deps
        if FlutterInfo in dep
    ]
    if transitive_native_depsets:
        native_libs.extend(depset(transitive = transitive_native_depsets).to_list())
    return native_libs

def _run_application_link_hooks(ctx, run_link_hooks, recorded_uses, transitive_data_assets):
    """Runs Step 2b: package link hooks over the recorded uses.

    Each emits the data assets declared in `link_hook_assets`, bundled below
    beside the native assets' data assets.
    """
    if not run_link_hooks:
        return transitive_data_assets, []
    link = dart_link_hook_actions(
        ctx,
        runner = ctx.executable._link_hook_runner,
        sdk = ctx.toolchains["@rules_dart//dart:exec_tools_toolchain_type"].dart_sdk_info,
        recorded_uses = recorded_uses,
        deps = ctx.attr.deps,
        data_asset_ids = ctx.attr.link_hook_assets,
        name = ctx.label.name + "_link_hooks",
    )
    return depset(link.assets, transitive = [transitive_data_assets]), link.validation_outputs

def _aggregate_application_plugins(ctx):
    """Aggregates the plugin channels from deps for the registrant generators.

    These are what the platform registrant generators and desktop runners
    read back off this target — via FlutterApplicationInfo, since an
    application is the end of the library graph and does not contribute to
    another one.
    """
    all_dep_plugins = []
    apple_plugin_lib_depsets = []
    android_plugin_lib_depsets = []
    linux_plugin_lib_depsets = []
    windows_plugin_lib_depsets = []
    apple_privacy_manifest_depsets = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
            apple_plugin_lib_depsets.append(dep[FlutterInfo].apple_plugin_libraries)
            android_plugin_lib_depsets.append(dep[FlutterInfo].android_plugin_libraries)
            linux_plugin_lib_depsets.append(dep[FlutterInfo].linux_plugin_libraries)
            windows_plugin_lib_depsets.append(dep[FlutterInfo].windows_plugin_libraries)
            apple_privacy_manifest_depsets.append(dep[FlutterInfo].apple_privacy_manifests)
    return struct(
        all_plugins = dedup_plugins(all_dep_plugins),
        apple_plugin_libraries = depset(transitive = apple_plugin_lib_depsets),
        android_plugin_libraries = depset(transitive = android_plugin_lib_depsets),
        linux_plugin_libraries = depset(transitive = linux_plugin_lib_depsets),
        windows_plugin_libraries = depset(transitive = windows_plugin_lib_depsets),
        apple_privacy_manifests = depset(transitive = apple_privacy_manifest_depsets),
    )

def _index_bundled_libraries(native_libs, bundled_code_assets):
    """Indexes every loose native library this app carries by path.

    Both routes in: the `native_deps` set, and the Native Assets `CodeAsset`
    libraries `native_assets.json` already points at. Deduplicated by path
    because nothing stops one library arriving twice.
    """
    bundled_native_libs = {}
    for lib in native_libs + bundled_code_assets.to_list():
        bundled_native_libs[lib.path] = lib
    return bundled_native_libs

def _index_library_pairs(bundled_native_libs, pairs, files_field):
    """Indexes per-library file lists on the bundled paths.

    A library with no entry is an empty list rather than a missing key: the
    dev tool has to tell "nothing describes this one" from "this one is not
    bundled", and they mean opposite things for a reload.

    Returns:
      An `(index, files)` tuple; `files` holds every listed File for
      declaration as an output.
    """
    index = {path: [] for path in bundled_native_libs}
    files = []
    for pair in pairs:
        if pair.library.path in index:
            listed = getattr(pair, files_field)
            index[pair.library.path] = [f.path for f in listed]
            files.extend(listed)
    return index, files

def _application_dep_pairs(ctx, collect_native, field):
    """Collects per-library pairs from native_deps plus deps' `FlutterInfo`."""
    return collect_native(ctx.attr.native_deps) + [
        p
        for dep in ctx.attr.deps
        if FlutterInfo in dep
        for p in getattr(dep[FlutterInfo], field).to_list()
    ]

def _write_dev_config(ctx, flutter_sdk_info, compilation, bundled_native_libs, binding_contracts, native_lib_sources, contract_files):
    """Writes the hot-reload dev config (debug only) and returns extra default files.

    Mirrors flutter_web_application's `_dev_config.json`. Tells the dev tool
    the authoritative entrypoint URI and — for a source-assembled (codegen)
    app — the multi-root layout + generated source paths/URIs, so it never
    infers any of this from package_config rootUri shapes. The dev tool
    discovers this by building the flutter_application target directly (its
    DefaultInfo). When `generatedSourceUris` is non-empty the dev tool
    rebuilds this same app target on change to regenerate codegen outputs (a
    narrow codegen-only rebuild would prune the flutter SDK from the execroot
    symlink forest and break the next full compile).
    """
    extra_files = []
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
            # Generated plugin registrants, keyed by platform
            # (exec-relative paths, "" when that platform has no Dart
            # plugins and no agent). One per platform because this dev
            # build runs in the host configuration while the app can be
            # running elsewhere; the dev tool selects by the platform the
            # app reports (build_info.targetPlatform), compiles that file
            # into its dills via --source, and advertises it with
            # -Dflutter.dart_plugin_registrant so the engine's pre-main
            # hook keeps firing — with the right plugin set — after hot
            # restart.
            "dartPluginRegistrants": {
                platform: registrant.path if registrant else ""
                for platform, registrant in compilation.dev_plugin_registrants.items()
            },
            "devPackageConfig": compilation.dev_package_config.path,
            "filesystemRoots": compilation.dev_filesystem_roots,
            "filesystemScheme": compilation.dev_filesystem_scheme,
            "generatedSourcePaths": compilation.dev_generated_source_paths,
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
            "nativeLibs": bundled_native_libs.keys(),
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
        }),
    )
    extra_files.append(dev_config_file)
    extra_files.append(compilation.dev_package_config)

    # The dev registrants are inputs to no action — without this they are
    # declared but never materialized by the bare build, and the dev tool
    # would absolutize a dangling path.
    for registrant in compilation.dev_plugin_registrants.values():
        if registrant:
            extra_files.append(registrant)

    # The generated sources `_dev_config.json` points the frontend_server
    # at. These *are* inputs to the kernel compile, which is why they
    # looked safe — but an input is materialized on the machine that ran
    # the action, and a cache hit runs none. Declaring them is what makes
    # the paths in the config true.
    extra_files.extend(compilation.dev_generated_source_files)

    # And the binding contracts, which have it worse than the generated
    # sources: a contract is an input to no action of this target at all.
    # Nothing but the dev tool ever reads its bytes, so a *generated*
    # contract is written only if some other action happens to produce it —
    # a bridge generator that emits its interface description beside the
    # Dart it also emits does, and a rule that emits the description alone
    # does not. The first case works by luck and the second one names a
    # path in the config that this build never writes, which the dev tool
    # reports at launch as a build that declared a file it did not write.
    # Declaring them is what makes the paths true, and what makes the
    # reload's own rebuild refresh them.
    extra_files.extend(contract_files)
    return extra_files

def _application_default_files(flutter_assets, package_config, native_assets_manifest_file, bundled_native_libs, aot_output, is_debug, kernel_dill):
    """Assembles the DefaultInfo file list, including the manifest-named code assets.

    The code-asset libraries join `default_files` with the manifest that names
    them. Declaring an output is what makes its path true: the manifest is
    built here and the dev tool reads these files back off this target, and a
    path named by a build that did not write it fails far from its cause.
    """
    default_files = [
        flutter_assets,
        package_config,
        native_assets_manifest_file,
    ] + bundled_native_libs.values()
    if aot_output:
        default_files.append(aot_output)
    if is_debug:
        default_files.append(kernel_dill)
    return default_files

def _application_providers(flutter_sdk_info, is_debug, kernel_dill, package_config, native_assets_manifest_file, bundled_code_assets, transitive_data_assets, aot_output, debug_info_output, link_hook_validation, flutter_assets, native_libs, plugins, default_files):
    """Assembles the result providers for the compiled application."""
    output_groups = {
        "native_assets_manifest": depset([native_assets_manifest_file]),
        "bundled_code_assets": bundled_code_assets,
    }
    if debug_info_output:
        output_groups["debug_info"] = depset([debug_info_output])
    if link_hook_validation:
        # Every hook runs whenever the app builds, even one that emits no
        # asset, so its verdict on the program is never skipped.
        output_groups["_validation"] = depset(link_hook_validation)

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
            apple_privacy_manifests = plugins.apple_privacy_manifests,
            plugins = plugins.all_plugins,
            apple_plugin_libraries = plugins.apple_plugin_libraries,
            android_plugin_libraries = plugins.android_plugin_libraries,
            linux_plugin_libraries = plugins.linux_plugin_libraries,
            windows_plugin_libraries = plugins.windows_plugin_libraries,
        ),
    ]
    providers.append(OutputGroupInfo(**output_groups))
    return providers

def _flutter_application_impl(ctx):
    flutter_sdk_info = resolve_flutter_sdk_info(ctx)

    mode = flutter_build_mode(ctx)
    is_debug = mode == "debug"

    # Profile strips like release, as `flutter build --profile` does: the
    # profiler names Dart code from the snapshot, not from native symbols.
    strip = ctx.var["COMPILATION_MODE"] == "opt"

    _check_aot_supported(flutter_sdk_info, is_debug)

    platform = _detect_application_platform(ctx)
    target_platform = platform.target_platform

    _fail_on_unreplaced_hooks(ctx)

    # Aggregate transitive Native Assets so the manifest exists before
    # kernel compile (the frontend_server reads it via --native-assets).
    native_assets_list, transitive_data_assets = _collect_transitive_assets(ctx)

    target_arch = host_target_arch(ctx, flutter_sdk_info)
    native_assets_manifest_file = _write_application_manifest(ctx, native_assets_list, target_platform, target_arch)

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
    compilation = _compile_application_kernel(ctx, flutter_sdk_info, target_platform, platform.is_ios, native_assets_manifest_file, flutter_assets, recorded_uses)
    kernel_dill = compilation.kernel_dill
    package_config = compilation.package_config

    # Step 2: AOT compile — choose format based on target platform.
    aot_output, debug_info_output, strip = _compile_application_aot(ctx, flutter_sdk_info, is_debug, platform.is_ios, platform.is_macos, kernel_dill, strip)

    native_libs = _collect_application_native_libs(ctx)

    # Step 2b: package link hooks over the recorded uses. Each emits the data
    # assets declared in `link_hook_assets`, bundled below beside the native
    # assets' data assets.
    transitive_data_assets, link_hook_validation = _run_application_link_hooks(ctx, run_link_hooks, recorded_uses, transitive_data_assets)

    # Step 3: Shader compilation + asset bundle. Pass data assets so the
    # bundler places them under flutter_assets/packages/<pkg>/<name>.
    compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, target_platform)
    flutter_build_assets(
        ctx,
        flutter_sdk_info,
        flutter_assets,
        compiled_shaders,
        target_platform = target_platform,
        kernel_dill = kernel_dill,
        is_debug = is_debug,
        data_assets = transitive_data_assets,
    )

    # Aggregate the plugin channels from deps. These are what the platform
    # registrant generators and desktop runners read back off this target —
    # via FlutterApplicationInfo, since an application is the end of the
    # library graph and does not contribute to another one.
    plugins = _aggregate_application_plugins(ctx)

    bundled_native_libs = _index_bundled_libraries(native_libs, bundled_code_assets)

    # What each of those libraries' bindings were generated from, when its build
    # said so — see `flutter_native_library`. Keyed by the same paths, so a
    # library with no contract is an empty list rather than a missing key: the dev
    # tool has to tell "nothing describes this one" from "this one is not
    # bundled", and they mean opposite things for a reload.
    binding_contracts, contract_files = _index_library_pairs(
        bundled_native_libs,
        _application_dep_pairs(ctx, collect_binding_contracts, "binding_contracts"),
        "contract",
    )

    # And what each is built from, on the same keys, so a reload can tell that a
    # library went stale in an app that runs no build of its own.
    native_lib_sources, _ = _index_library_pairs(
        bundled_native_libs,
        _application_dep_pairs(ctx, collect_native_source_pairs, "native_lib_sources"),
        "sources",
    )

    default_files = _application_default_files(flutter_assets, package_config, native_assets_manifest_file, bundled_native_libs, aot_output, is_debug, kernel_dill)

    # Hot-reload dev config (debug only), mirroring flutter_web_application's
    # `_dev_config.json`.
    if is_debug and compilation.dev_package_config != None:
        default_files.extend(_write_dev_config(ctx, flutter_sdk_info, compilation, bundled_native_libs, binding_contracts, native_lib_sources, contract_files))

    return _application_providers(flutter_sdk_info, is_debug, kernel_dill, package_config, native_assets_manifest_file, bundled_code_assets, transitive_data_assets, aot_output, debug_info_output, link_hook_validation, flutter_assets, native_libs, plugins, default_files)

flutter_application = rule(
    implementation = _flutter_application_impl,
    attrs = dicts.add(
        FLUTTER_APPLICATION_ATTRS,
        PLATFORM_CONSTRAINT_ATTRS,
        link_hook_runner_attr(),
        # Simulator-vs-device is an Apple *environment* constraint, not an OS
        # one, so it needs apple_support's own attrs on top of the OS set.
        # `launch_build_args` turns it into `--ios_multi_cpus=sim_arm64` or
        # `=arm64`, which is the difference between a dev-loop rebuild landing
        # in the app's output tree and landing in one it never reads.
        apple_support.platform_constraint_attrs(),
    ),
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_flutter//flutter/private:product_tools_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_flutter//flutter/private:aot_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_flutter//flutter/private:font_subset_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles a Flutter application to AOT native code + asset bundle (release) or kernel .dill + assets (debug).",
)
