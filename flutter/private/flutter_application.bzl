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
load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartPackageMetadataInfo")
load("@rules_dart//dart:utils.bzl", "PROGRAM_ASSETS_TOOLCHAINS", "program_assets_action_args", "program_assets_attrs")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterApplicationInputsInfo", "FlutterInfo")
load("//flutter/private:code_asset_libraries.bzl", "code_asset_libraries", "code_asset_libraries_aspect", "describe_code_asset_libraries")
load("//flutter/private:common.bzl", "FLUTTER_APPLICATION_ATTRS", "PLATFORM_CONSTRAINT_ATTRS", "PROGRAM_PACKAGE_DOC", "asset_roots", "check_unreplaced_hooks", "collect_binding_contracts", "collect_native_libs", "declare_flutter_assets_dir", "detect_target_platform", "flutter_build_assets", "flutter_build_mode", "flutter_compile_kernel", "flutter_compile_shaders", "flutter_deps_attr", "flutter_program_inputs", "host_target_arch", "launch_build_args", "shader_sources", "shakes_icons")
load("//flutter/private:dev_config.bzl", "dev_config_file", "dev_search_roots", "dev_source_dir", "write_dev_config")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_elf_action", "flutter_aot_macho_action", "gen_snapshot_options")
load("//flutter/private:flutter_native_assets.bzl", "CODE_ASSETS_DOC", "CODE_ASSETS_TOOL_ATTRS", "candidate_code_asset_libraries", "check_bundled_library_names", "native_assets_target_string", "run_code_assets_tool")
load("//flutter/private:link_hooks.bzl", "link_hooks_plan", "native_code_config", "program_assets")
load("//flutter/private:native_sources.bzl", "collect_native_source_pairs")
load("//flutter/private:plugin_resolution.bzl", "application_plugins", "chosen_native_code")
load("//flutter/private:program_analysis.bzl", "program_analyzable_info")

_FLUTTER_TOOLCHAIN_TYPE = "@rules_flutter//flutter:toolchain_type"

# What an application rule declares so it can be built for a web platform,
# where it needs no Flutter toolchain of the target's (no toolchain targets
# one: a web app compiles with its own host tools) and builds nothing.
WEB_PLATFORM_CONSTRAINT_ATTRS = {
    "_js_constraint": attr.label(default = "@rules_dart//dart/constraints:js"),
    "_wasm_constraint": attr.label(default = "@rules_dart//dart/constraints:wasm"),
}

# The toolchains of an application rule. The Flutter one is optional for the
# web platforms alone: `flutter_application_build` fails where it is missing
# for any other.
APPLICATION_TOOLCHAINS = [
    config_common.toolchain_type(_FLUTTER_TOOLCHAIN_TYPE, mandatory = False),
] + PROGRAM_ASSETS_TOOLCHAINS

def is_web_platform(ctx):
    """Whether `ctx`, carrying `WEB_PLATFORM_CONSTRAINT_ATTRS`, is built for a web platform.

    Args:
        ctx: Rule context.

    Returns:
        True for a platform with the `js` or `wasm` web compiler constraint.
    """
    return ctx.target_platform_has_constraint(ctx.attr._js_constraint[platform_common.ConstraintValueInfo]) or \
           ctx.target_platform_has_constraint(ctx.attr._wasm_constraint[platform_common.ConstraintValueInfo])

def flutter_application_build(ctx, inputs):
    """Builds the program `inputs` describes as the application `ctx` declares.

    The whole of `flutter_application`'s analysis, over a program passed in
    rather than read off `ctx`'s attributes, so a rule that is the same
    application with another `main` (`flutter_application_variant`) runs the
    same pipeline over its own program. `ctx` supplies what is not the
    program: the label that names the outputs, the toolchains and the tool
    attributes, and the platform.

    Args:
        ctx: Rule context carrying `FLUTTER_APPLICATION_ATTRS`, the platform
            constraint attributes and `program_assets_attrs()`.
        inputs: The program, from `flutter_program_inputs`.

    Returns:
        The providers `flutter_application` returns, `FlutterApplicationInputsInfo`
        included.
    """

    # Built for a web platform, under a web app's split, the application is
    # its program and nothing else: the web app compiles that with its own
    # compilers (see `flutter_web_bundle`). Nothing native is built there, as
    # `flutter build web` builds none of a shared app's native code.
    if is_web_platform(ctx):
        return [FlutterApplicationInputsInfo(inputs = inputs), DefaultInfo(files = depset())]

    flutter_toolchain = ctx.toolchains[_FLUTTER_TOOLCHAIN_TYPE]
    if flutter_toolchain == None:
        fail("%s: no Flutter toolchain targets the platform this is built for. Rerun with `--toolchain_resolution_debug='@@rules_flutter+//flutter:toolchain_type'` to see why each registered one was rejected." % ctx.label)
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    mode = flutter_build_mode(ctx)
    is_debug = mode == "debug"

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
    hook_err = check_unreplaced_hooks(ctx.label, inputs.deps)
    if hook_err != None:
        fail(hook_err)

    # Link hooks run over the uses the AOT compile records, so only a
    # release or profile build has any: a JIT compile tree-shakes nothing and
    # records nothing, and a debug build runs no hook. As in `flutter build`,
    # every package with a link hook has it run then, whether or not it emits
    # anything: the hook decides which of its package's declared data assets
    # ship.
    link_hooks = link_hooks_plan(inputs, inputs.deps, links = not is_debug)

    # The AOT compile records the uses when something reads them: the link
    # hooks, or icon tree shaking, which reads the `IconData` uses.
    records_uses = link_hooks.runs or shakes_icons(inputs, portable_tools(ctx), is_debug)
    recorded_uses = ctx.actions.declare_file(ctx.label.name + ".recorded_uses.json") if records_uses else None

    # What the application ships: its data assets, bundled under
    # `flutter_assets/packages/<pkg>/<name>`, and its code assets, the Dart
    # package graph's (a package that owns a native library contributes it
    # just by being depended on) and those this target names in
    # `code_assets`, which replace whatever arrives under their ids. See
    # `resolve_native_assets`.
    target_arch = host_target_arch(ctx, flutter_sdk_info)
    shipped = program_assets(
        ctx,
        inputs,
        inputs.deps,
        link_hooks,
        recorded_uses,
        name = ctx.label.name + "_program_assets",
        code_config = native_code_config(
            target_platform,
            target_arch,
            is_simulator = is_ios and apple_support.target_environment_from_rule_ctx(ctx) == "simulator",
            minimum_os_version = inputs.minimum_os_version,
        ) if link_hooks.runs else None,
        code_assets = [target[DartCodeAssetInfo] for target in inputs.code_assets],
    )
    link_hook_validation = shipped.validation_outputs

    # The app's native-assets manifest, which it ships as
    # `flutter_assets/NativeAssetsManifest.json`, as upstream's
    # `InstallCodeAssets` ships it after the link hooks: the engine reads it at
    # startup and resolves every `@Native(assetId:)` binding through it, a
    # hot restart's included. Which code assets ship is known only when the
    # hooks have run, so an action reading the program's code assets by name
    # writes it, naming each where its platform's bundle places it.
    native_assets_manifest_file = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
    dart_target = native_assets_target_string(target_platform, target_arch)
    if shipped.code_assets and not dart_target:
        fail((
            "%s: %d code asset(s) can reach this application on %r, but the " +
            "target architecture could not be determined (got %r), so its " +
            "native-assets manifest could name none of them. This is a " +
            "rules_flutter bug in host_target_arch's cpu detection: please " +
            "report the bazel-out cpu segment of this build."
        ) % (ctx.label, len(shipped.code_assets), target_platform, target_arch))
    manifest_code_assets = program_assets_action_args(ctx.actions, shipped.info, data = False, code = "names")
    manifest_args = ctx.actions.args()
    manifest_args.add("--os", target_platform)
    manifest_args.add("--target", dart_target)
    manifest_args.add("--output", native_assets_manifest_file)
    run_code_assets_tool(
        ctx,
        "manifest",
        [manifest_args, manifest_code_assets.args],
        manifest_code_assets.inputs,
        [native_assets_manifest_file],
        mnemonic = "FlutterNativeAssetsManifest",
        progress_message = "Writing the native-assets manifest of %{label}",
    )

    # Declared before the kernel compile that will later feed it, because a
    # debug app carries this path inside itself: `flutter_compile_kernel`
    # bakes it into `rules_flutter.build_info.assetsDir`, and the dev tool
    # matches the running app's reported value against the tree it watches
    # and rebuilds. Declaring an output is independent of registering the
    # action that fills it, so the ordering costs nothing.
    flutter_assets = declare_flutter_assets_dir(ctx)

    # Step 1: Kernel compilation (mode-aware: debug uses debug dill, no AOT).
    compilation = flutter_compile_kernel(
        ctx,
        portable_tools(ctx),
        target_platform = target_platform,
        track_widget_creation = inputs.track_widget_creation and mode != "release",
        assets_dir = flutter_assets,
        recorded_uses = recorded_uses,
        inputs = inputs,
        platform_build_args = launch_build_args(
            target_platform,
            is_simulator = is_ios and apple_support.target_environment_from_rule_ctx(ctx) == "simulator",
            is_arm64 = ctx.target_platform_has_constraint(
                ctx.attr._arm64_constraint[platform_common.ConstraintValueInfo],
            ),
            is_x86_64 = ctx.target_platform_has_constraint(
                ctx.attr._x86_64_constraint[platform_common.ConstraintValueInfo],
            ),
            is_armv7 = ctx.target_platform_has_constraint(
                ctx.attr._armv7_constraint[platform_common.ConstraintValueInfo],
            ),
        ),
    )
    kernel_dill = compilation.kernel_dill

    aot_output = None
    aot_object = None
    strip_aot = True
    debug_info_output = None
    gen_snapshot_files = []
    if not is_debug:
        options = gen_snapshot_options(ctx, inputs)
        strip_aot = options.strip
        debug_info_output = options.debug_info
        gen_snapshot_files = options.files

        # Step 2: AOT compile — choose format based on target platform.
        if is_ios or is_macos:
            aot_output = ctx.actions.declare_file(ctx.label.name + ".dylib")
            aot_object = ctx.actions.declare_file(ctx.label.name + ".o")
            flutter_aot_macho_action(
                ctx = ctx,
                gen_snapshot = flutter_sdk_info.gen_snapshot,
                kernel_dill = kernel_dill,
                output = aot_output,
                extra_flags = options.flags,
                file_flags = options.file_flags,
                debug_info = debug_info_output,
                object = aot_object,
                minimum_os_version = inputs.minimum_os_version if inputs.minimum_os_version else None,
            )
        else:
            aot_output = ctx.actions.declare_file(ctx.label.name + ".so")
            flutter_aot_elf_action(
                ctx = ctx,
                gen_snapshot = flutter_sdk_info.gen_snapshot,
                kernel_dill = kernel_dill,
                output = aot_output,
                # Every AOT build strips unless `--no-strip` asks otherwise,
                # as `flutter build` does whatever the `-c`: release and profile
                # alike, since the profiler names Dart code from the snapshot.
                # Apple strips after making a dSYM instead (`apple_xcode.bzl`).
                strip = options.strip,
                extra_flags = options.flags,
                file_flags = options.file_flags,
                debug_info = debug_info_output,
                target_arch = flutter_sdk_info.target_arch,
            )

    # Collect native shared libraries from native_deps + transitive plugin deps.
    native_libs = collect_native_libs(inputs.native_deps)
    transitive_native_depsets = [
        dep[FlutterInfo].transitive_native_libs
        for dep in inputs.deps
        if FlutterInfo in dep
    ]
    if transitive_native_depsets:
        native_libs.extend(depset(transitive = transitive_native_depsets).to_list())

    # Step 3: Shader compilation + asset bundle. Pass the program's assets so
    # the bundler places its data assets under flutter_assets/packages/<pkg>/<name>.
    compiled_shaders = flutter_compile_shaders(ctx, portable_tools(ctx), target_platform, inputs.deps, inputs)
    flutter_build_assets(
        ctx,
        portable_tools(ctx),
        flutter_assets,
        inputs.deps,
        target_platform,
        compiled_shaders,
        recorded_uses = [recorded_uses] if recorded_uses else [],
        is_debug = is_debug,
        program_assets = shipped.info,
        native_assets_manifest = native_assets_manifest_file,
        inputs = inputs,
    )

    # Aggregate the plugin channels from deps. These are what the platform
    # registrant generators and desktop runners read back off this target —
    # via FlutterApplicationInfo, since an application is the end of the
    # library graph and does not contribute to another one.
    apple_plugin_lib_depsets = []
    linux_plugin_lib_depsets = []
    windows_plugin_lib_depsets = []
    apple_privacy_manifest_depsets = []
    android_lib_depsets = []
    for dep in inputs.deps:
        if FlutterInfo in dep:
            apple_plugin_lib_depsets.append(dep[FlutterInfo].apple_plugin_libraries)
            linux_plugin_lib_depsets.append(dep[FlutterInfo].linux_plugin_libraries)
            windows_plugin_lib_depsets.append(dep[FlutterInfo].windows_plugin_libraries)
            apple_privacy_manifest_depsets.append(dep[FlutterInfo].apple_privacy_manifests)
            android_lib_depsets.append(dep[FlutterInfo].android_libs)

    # One implementation of each federated plugin per platform, which every
    # native registrant registers, and whose native code alone the app links.
    resolution = application_plugins(ctx.label, inputs.deps)
    all_plugins = resolution.native
    native_code = chosen_native_code(
        resolution,
        android_libs = depset(transitive = android_lib_depsets),
        apple_plugin_libraries = depset(transitive = apple_plugin_lib_depsets),
        apple_privacy_manifests = depset(transitive = apple_privacy_manifest_depsets),
        linux_plugin_libraries = depset(transitive = linux_plugin_lib_depsets),
        windows_plugin_libraries = depset(transitive = windows_plugin_lib_depsets),
    )
    apple_plugin_libraries = native_code.apple_plugin_libraries
    linux_plugin_libraries = native_code.linux_plugin_libraries
    windows_plugin_libraries = native_code.windows_plugin_libraries
    apple_privacy_manifests = native_code.apple_privacy_manifests
    android_libs = native_code.android_libs

    # Every loose native library this app can carry, by both routes in: the
    # `native_deps` set above, and every code-asset candidate. No two may
    # land on one path, whichever a link hook keeps. Deduplicated by path
    # because nothing stops one library arriving twice. A debug build, the
    # one the dev tool reads these of, runs no link hook and ships them all.
    candidate_libraries = candidate_code_asset_libraries(shipped.info)
    check_bundled_library_names(ctx.label, native_libs + candidate_libraries, target_platform)
    bundled_native_libs = {}
    for lib in native_libs + candidate_libraries:
        bundled_native_libs[lib.path] = lib

    # What each of those libraries' bindings were generated from, when its build
    # said so — see `flutter_native_library`. Keyed by the same paths, so a
    # library with no contract is an empty list rather than a missing key: the dev
    # tool has to tell "nothing describes this one" from "this one is not
    # bundled", and they mean opposite things for a reload.
    binding_contracts = {path: [] for path in bundled_native_libs}
    for pair in collect_binding_contracts(inputs.native_deps) + [
        p
        for dep in inputs.deps
        if FlutterInfo in dep
        for p in dep[FlutterInfo].binding_contracts.to_list()
    ]:
        if pair.library.path in binding_contracts:
            binding_contracts[pair.library.path] = list(pair.contract)

    # And what each is built from, on the same keys, so a reload can tell that a
    # library went stale in an app that runs no build of its own.
    native_lib_sources = {path: [] for path in bundled_native_libs}
    for pair in collect_native_source_pairs(inputs.native_deps) + [
        p
        for dep in inputs.deps
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
        shipped.code_assets,
        code_asset_libraries(
            inputs.deps + ([inputs.package_target] if inputs.package_target != None else []),
            inputs.code_assets,
            {asset.asset_id: asset.file for asset in shipped.code_assets},
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
                # Merged user defines (attr + extra_dart_defines flag), the
                # flavor's `FLUTTER_APP_FLAVOR`, and the app's version and the
                # SDK's (`FLUTTER_BUILD_NAME`, `FLUTTER_VERSION`, ...). The dev
                # tool replays these as
                # -D on its resident frontend_server so hot reload/restart
                # recompiles keep the same environment.
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
                "shaders": shader_sources(ctx, inputs.deps, target_platform, inputs),
                # Where each package's first-party assets are in the workspace,
                # by bundle path prefix: an asset is bundled under its path in
                # its package, not in the workspace.
                "assetRoots": asset_roots(ctx, inputs.deps, inputs),
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
                # maps live edits back to via its SourceUriResolver. packageRoot is
                # workspace-relative.
                "sourcePackages": [
                    {"name": sp[0], "packageRoot": sp[1]}
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
    }
    if debug_info_output:
        output_groups["debug_info"] = depset([debug_info_output])
    if gen_snapshot_files:
        output_groups["gen_snapshot_files"] = depset(gen_snapshot_files)

    # Every hook runs whenever the app builds, even one that emits no asset,
    # so its verdict on the program is never skipped.
    output_groups.update(compilation.import_checks)
    output_groups["_validation"] = depset(link_hook_validation, transitive = [compilation.import_checks["_validation"]])

    providers = [
        FlutterApplicationInputsInfo(inputs = inputs),
        DefaultInfo(files = depset(default_files)),
        FlutterApplicationInfo(
            aot_output = aot_output,
            aot_object = aot_object,
            strip_aot = strip_aot,
            kernel_dill = kernel_dill if is_debug else None,
            flutter_assets = flutter_assets,
            icu_data = flutter_sdk_info.icu_data,
            native_libs = native_libs,
            is_debug = is_debug,
            native_assets_manifest = native_assets_manifest_file,
            program_assets = shipped.info,
            apple_privacy_manifests = apple_privacy_manifests,
            plugins = all_plugins,
            apple_plugin_libraries = apple_plugin_libraries,
            linux_plugin_libraries = linux_plugin_libraries,
            windows_plugin_libraries = windows_plugin_libraries,
            android_libs = android_libs,
        ),
        # What `bazel coverage` of a test compiled in this application
        # reports of it: its sources and the libraries it reaches. A
        # variant's `main` is what replaces the application's, an entry point
        # of its own (an integration test's), so only its `srcs` are.
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"] if hasattr(ctx.attr, "application") else ["srcs", "main"],
            dependency_attributes = ["deps", "application"],
            extensions = ["dart"],
        ),
        # What lets rules_dart's analysis check the program's own files: its
        # `main`, which may be outside any `lib/`, its sources, and the sources
        # of what it compiles staged copies of. Deliberately not a `DartInfo`:
        # `deps` requires one, and an application is not a dependency.
        program_analyzable_info(
            ctx,
            inputs.package,
            inputs.package_root,
            inputs.deps,
            [inputs.main] + inputs.srcs + inputs.staged_sources,
        ),
    ]
    providers.append(OutputGroupInfo(**output_groups))
    return providers

def _flutter_application_impl(ctx):
    return flutter_application_build(ctx, flutter_program_inputs(ctx))

flutter_application = rule(
    implementation = _flutter_application_impl,
    attrs = dicts.add(
        FLUTTER_APPLICATION_ATTRS,
        # The application is where a debug build's dev config is written, so
        # it is the one rule that needs to know, per code asset, what the
        # asset's own build declared about it.
        {
            "deps": flutter_deps_attr(aspects = [code_asset_libraries_aspect]),
            # Redeclared to reach the code assets the package itself declares,
            # which no library in `deps` carries when none names it.
            "package": attr.label(
                providers = [DartPackageMetadataInfo],
                mandatory = True,
                doc = PROGRAM_PACKAGE_DOC,
                aspects = [code_asset_libraries_aspect],
            ),
            "code_assets": attr.label_list(
                doc = CODE_ASSETS_DOC,
                providers = [DartCodeAssetInfo],
                aspects = [code_asset_libraries_aspect],
            ),
        },
        PLATFORM_CONSTRAINT_ATTRS,
        WEB_PLATFORM_CONSTRAINT_ATTRS,
        CODE_ASSETS_TOOL_ATTRS,
        program_assets_attrs(),
        # Simulator-vs-device is an Apple *environment* constraint, not an OS
        # one, so it needs apple_support's own attrs on top of the OS set.
        # `launch_build_args` turns it into `--ios_multi_cpus=sim_arm64` or
        # `=arm64`, which is the difference between a dev-loop rebuild landing
        # in the app's output tree and landing in one it never reads.
        apple_support.platform_constraint_attrs(),
    ),
    # The target's toolchain is for its AOT compile and engine files; every
    # compile whose output does not depend on the target is `portable`.
    toolchains = APPLICATION_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = ["cpp"],
    doc = "Compiles a Flutter application to AOT native code + asset bundle (release) or kernel .dill + assets (debug). A web app (`flutter_web_app`) builds it for its compilers' web platforms, where it compiles nothing and gives the web app its program (`FlutterApplicationInputsInfo`).",
)
