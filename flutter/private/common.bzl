"""Shared utilities for Flutter rules.

Package config generation, transitive source collection, and the shared
compilation pipeline (kernel → AOT → assets → FFI collection) used by
flutter_application, flutter_android_bundle, and flutter_ios_application.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "KERNEL_TOOL_ATTR", "collect_packages", "collect_transitive_srcs", "dart_import_check_aspect", "generate_dev_package_config", "import_check_output_groups", "package_identity_attrs", "package_info_from_metadata", "package_lib_prefix", "resolve_package_identity", "runtime_reset")
load("//flutter:providers.bzl", "FlutterInfo", "FlutterNativeLibraryInfo")
load("//flutter/private:app_entrypoint.bzl", "APP_SCHEME", "app_main_location", "app_scheme_files", "app_scheme_location", "app_scheme_sources", "synthesize_app_package", "with_root")
load("//flutter/private:application_version.bzl", "VERSION_SETTING_ATTRS", "program_version")
load("//flutter/private:constants.bzl", "SHARED_LIBRARY_EXTENSIONS")
load("//flutter/private:flutter_aot_compile.bzl", "GEN_SNAPSHOT_SETTINGS_ATTRS")
load("//flutter/private:flutter_asset_bundle.bzl", "flutter_asset_bundle_action")
load("//flutter/private:flutter_compile.bzl", "flutter_kernel_compile")
load("//flutter/private:flutter_info_forwarding.bzl", "flutter_info_forwarding_aspect")
load("//flutter/private:flutter_library.bzl", "aggregate_pub_contributions", "bundle_key", "package_root_of", "path_in_package", "ships_in")
load("//flutter/private:flutter_shader_compile.bzl", "flutter_shader_compile_action")
load("//flutter/private:native_sources.bzl", "native_sources_aspect")
load("//flutter/private:notices.bzl", "NOTICES_ATTRS", "additional_licenses_of", "flutter_notices_action", "notices_asset_key", "package_licenses_of")
load("//flutter/private:plugin_registrant.bzl", "generate_dart_plugin_registrant", "generate_dev_plugin_registrants")
load("//flutter/private:plugin_resolution.bzl", "PLUGIN_WARNINGS_TOOL_ATTR", "application_plugins", "plugin_warnings_validation")
load("//flutter/private:program_analysis.bzl", "program_sky_engine_attr")
load("//flutter/private:sdk_defines.bzl", "program_version_dart_defines")
load("//flutter/private:validation.bzl", "validate_dart_defines")

visibility("//flutter/...")

def make_web_wrapper_main_content(original_import, registrant_import = None, agent_imports = None):
    """Generate a web wrapper main.dart that uses ui_web.bootstrapEngine().

    Flutter web requires ui_web.bootstrapEngine() to properly initialize the
    engine (create the implicit view, set up the platform dispatcher, etc.)
    before calling the user's main(). Without this, runApp() fails with
    "The app requested a view, but the platform did not provide one."

    This matches the wrapper that `flutter build web` generates.

    Args:
        original_import: Import URI for the original main.
        registrant_import: Optional relative import path for the generated
            registrant file. If None, plugin registration is a no-op.
        agent_imports: Optional pair of relative import paths, the agent
            extensions and their web bridge, for a debug build. The wrapper
            registers the extensions and installs the bridge before anything
            else runs, so they cover the app's whole start.

    Returns:
        String of Dart source code.
    """
    lines = [
        "// GENERATED — do not edit.",
        "// Flutter web bootstrap script.",
        "// ignore_for_file: type=lint",
        "",
        "import 'dart:ui_web' as ui_web;",
        "import 'dart:async';",
        "",
        "import '%s' as entrypoint;" % original_import,
    ]
    if registrant_import:
        lines.append("import '%s' as pluginRegistrant;" % registrant_import)
    if agent_imports:
        lines.append("import '%s' as agentExtensions;" % agent_imports[0])
        lines.append("import '%s' as agentBridge;" % agent_imports[1])
    lines.extend([
        "",
        "typedef _UnaryFunction = dynamic Function(List<String> args);",
        "typedef _NullaryFunction = dynamic Function();",
        "",
        "Future<void> main() async {",
    ])
    if agent_imports:
        lines.append("  agentBridge.installRulesFlutterAgentBridge(")
        lines.append("    agentExtensions.registerRulesFlutterAgentExtensions(),")
        lines.append("  );")
    lines.extend([
        "  await ui_web.bootstrapEngine(",
        "    runApp: () {",
        "      if (entrypoint.main is _UnaryFunction) {",
        "        return (entrypoint.main as _UnaryFunction)(<String>[]);",
        "      }",
        "      return (entrypoint.main as _NullaryFunction)();",
        "    },",
    ])
    if registrant_import:
        lines.append("    registerPlugins: () {")
        lines.append("      pluginRegistrant.registerPlugins();")
        lines.append("    },")
    lines.extend([
        "  );",
        "}",
        "",
    ])
    return "\n".join(lines)

def check_unreplaced_hooks(label, deps):
    """Returns an error naming pub packages whose build hook nothing replaces.

    A pub package shipping `hook/build.dart` builds its native library at
    `pub get` time. Bazel cannot run that hook, so without a replacement the
    package's `@Native` bindings resolve to nothing: the manifest is simply
    missing an entry, and the failure surfaces at runtime as "couldn't resolve
    native function" with nothing pointing at the cause.

    Checked at the application rather than when the spoke repo is generated.
    `flutter_pub.from_lock()` materialises the whole lock file, so failing at
    generation would fail over packages nothing depends on, and on platforms
    where the hook is irrelevant. Only a package an application actually reaches
    is a problem, and only here is the depending target known.

    rules_dart applies the same rule at `dart_binary`. The two differ in the
    remediation they suggest: a Flutter user fixes this through
    `flutter_pub.from_lock()`, not `pub.from_lock()`.

    Args:
      label: The consuming target's label, for the message.
      deps: The application's `deps`, each providing `DartInfo`.

    Returns:
      An error message string, or `None`.
    """
    packages = depset(
        transitive = [dep[DartInfo].transitive_packages for dep in deps],
    ).to_list()

    offenders = [
        pkg
        for pkg in packages
        if pkg.unreplaced_hook
    ]
    if not offenders:
        return None
    return (
        "%s depends on pub package(s) that build native code with a hook " +
        "Bazel cannot run:\n%s\n\n" +
        "Their `@Native` bindings will not resolve at runtime. Either:\n" +
        "  - add a `dart_code_asset` to the owning package's `code_assets` " +
        "(for a pub package, that means a `flutter_pub.plugin_overlays` entry, " +
        "or a curated entry upstream in rules_dart), or\n" +
        "  - list the package in `flutter_pub.from_lock(ignore_hooks = [...])` if its " +
        "native code is genuinely unused here."
    ) % (
        label,
        "\n".join([
            "  - %s (%s)" % (pkg.package_name, pkg.unreplaced_hook)
            for pkg in offenders
        ]),
    )

def collect_native_libs(native_deps):
    """Collect shared libraries from native_deps for dart:ffi.

    Filters DefaultInfo files by extension (.so, .dylib, .dll).

    Args:
        native_deps: List of targets providing DefaultInfo with shared libs.

    Returns:
        List of shared library Files.
    """
    libs = []
    for dep in native_deps:
        for f in dep[DefaultInfo].files.to_list():
            if f.extension in SHARED_LIBRARY_EXTENSIONS:
                libs.append(f)
    return libs

def resolve_dev_generated_sources(paths, candidates):
    """The Files behind `_dev_config.json`'s `generatedSourcePaths`.

    rules_dart reports the generated sources as paths; the dev config takes
    Files (see `dev_config.bzl`), and these are those Files.

    Args:
        paths: The `generatedSourcePaths` going into the dev config.
        candidates: The Files the paths were derived from.

    Returns:
        The Files, in the order [paths] names them.
    """
    by_path = {f.path: f for f in candidates}
    missing = [p for p in paths if p not in by_path]
    if missing:
        fail(
            "dev config names generated sources with no File to declare: " +
            ", ".join(missing) +
            "\nThey would be written into _dev_config.json for the " +
            "frontend_server to read and never materialized by the build.",
        )
    return [by_path[p] for p in paths]

def collect_binding_contracts(native_deps):
    """Pair each `native_deps` entry's libraries with its declared binding contract.

    Only a `flutter_native_library` wrapper declares one. A bare shared library
    contributes a pair with an empty contract rather than being left out: "this
    library has nothing describing its bindings" is the state the dev tool has to
    be able to name, and a library missing from the map would read as a library
    that is not bundled.

    Args:
        native_deps: The `native_deps` targets, wrapped or bare.

    Returns:
        List of `struct(library = File, contract = tuple[File])`, one per shared
        library.
    """
    pairs = []
    for dep in native_deps:
        if FlutterNativeLibraryInfo in dep:
            info = dep[FlutterNativeLibraryInfo]
            contract = tuple(info.binding_contract.to_list())
            for lib in info.libraries.to_list():
                pairs.append(struct(library = lib, contract = contract))
        else:
            for f in dep[DefaultInfo].files.to_list():
                if f.extension in SHARED_LIBRARY_EXTENSIONS:
                    pairs.append(struct(library = f, contract = ()))
    return pairs

def flutter_compile_kernel(ctx, tools, aot = None, target_platform = None, track_widget_creation = False, assets_dir = None, platform_build_args = [], recorded_uses = None, inputs = None):
    """Run the shared kernel compilation step.

    Collects sources and packages and compiles them (`flutter_kernel_compile`).
    If deps contain plugins with dartPluginClass (or the debug agent is
    injected), generates a registrant library the engine invokes before main()
    on every root-isolate launch — including hot restart.

    The kernel is for the build mode's runtime (`flutter_build_mode`): debug
    is JIT against the non-product platform, profile AOT against it, and
    release AOT against the product platform.

    Args:
        ctx: Rule context (must have main, srcs, deps, defines attrs).
        tools: `FlutterExecToolsInfo` of the `PORTABLE` group (`portable_tools`).
        aot: If set, override AOT mode. Otherwise determined by the build mode.
        target_platform: Optional platform string (e.g. "web", "linux", "android").
            When set, only plugins with dartPluginClass on that platform are registered.
        track_widget_creation: Whether to pass `--track-widget-creation` to
            the frontend server, and to tell the dev tool the kernel has it
            (the `trackWidgetCreation` of the debug `rules_flutter.build_info`
            record). Passed rather than read off `ctx.attr`,
            because the rules calling this do not share one attribute set —
            `flutter_kernel` has no such attr — and a rule that has no
            opinion should say `False` rather than be probed for one.
        assets_dir: The declared `flutter_assets/` tree artifact, from
            `declare_flutter_assets_dir`. Supplying it is what makes a debug
            build carry `rules_flutter.build_info`; the rules with no asset
            bundle of their own (`flutter_kernel`,
            `flutter_aot_snapshot`) leave it None and emit no define, because
            an app with no assets tree has nothing for the dev tool to watch.
        platform_build_args: Flags from `launch_build_args`, recorded in
            `build_info` so an attaching dev tool can reproduce this
            configuration. Only meaningful alongside `assets_dir`.
        recorded_uses: Optional declared File for the compiler's recorded
            `@RecordUse` uses, the input of package link hooks. Pass it for
            AOT compiles only.
        inputs: The program to compile, from `flutter_program_inputs`; `ctx`'s
            own when None. A program rebuilt under another target
            (`flutter_application_variant`) is the application's, changed, and
            keeps the application's package: its package root, and so what
            `package:<name>/…` resolves to.

    Returns:
        struct with kernel_dill (File) and
        import_checks (the import checks' output groups, a dict for
        `OutputGroupInfo`: `_validation`, the app's and its libraries'
        checks and the action that prints the plugin choice's warnings, and rules_dart's unused-dependency group its fixer reads).
    """
    if inputs == None:
        inputs = flutter_program_inputs(ctx)
    all_srcs = list(inputs.srcs) + collect_transitive_srcs(inputs.deps).to_list()
    packages = collect_packages(inputs.deps)

    # Register the app itself as a package so the frontend_server keys the
    # entrypoint as `package:<name>/main.dart` — the URI the dev tool's
    # incremental compiler uses (without this, hot-reload deltas keyed via
    # sandbox `file://` URIs can't be matched against the kernel's libraries).
    app_pkg_name = inputs.package_name

    # The app's own package root, which is what `package:<name>/…` resolves
    # against: its declaration's directory, so an app in a nested Bazel
    # package registers a `rootUri` pointing at its own directory, not at
    # whatever sits in the *workspace's* `lib/`.
    app_package_root = inputs.package_root
    packages = synthesize_app_package(
        ctx.label,
        packages,
        app_pkg_name,
        app_package_root,
        inputs.package,
    )

    # Every file of the program, the app's own `main` included.
    program_files = all_srcs + ([inputs.main] if inputs.main else [])

    # Dev hot-reload metadata (debug only): a package_config for the dev tool's
    # compiler, outside the sandbox. A package whose sources straddle the
    # source tree and bazel-out (codegen) gets a `rootUri` under `APP_SCHEME`,
    # the scheme the build's compile reads every source through, resolved
    # across the live source tree and the generated roots; the rest point at
    # their directories. This is what lets the dev tool's frontend_server pick
    # up live edits AND find generated parts. See rules_dart
    # `generate_dev_package_config`.
    mode = flutter_build_mode(ctx)
    emit_dev_config = mode == "debug"
    dev_package_config = None
    dev_filesystem_roots = []
    dev_filesystem_scheme = ""
    dev_package_config_names = []
    dev_generated_sources = []
    dev_generated_source_uris = []
    dev_source_packages = []
    dev_app_sources = []
    main_location = app_main_location(app_pkg_name, app_package_root, inputs.main) if inputs.main else None
    app_entrypoint_uri = main_location.uri if main_location else None

    if emit_dev_config:
        dev_package_config = ctx.actions.declare_file(ctx.label.name + ".dev_package_config.json")
        dev_pc = generate_dev_package_config(packages, program_files, dev_package_config, scheme = APP_SCHEME)
        ctx.actions.write(dev_package_config, dev_pc.content)

        # A `main` with no `package:` URI is compiled under the app scheme,
        # and the dev loop's compiler has to mount the same root to name it
        # the same way.
        dev_filesystem_roots = with_root(dev_pc.filesystem_roots, main_location.root if main_location else None)

        # The sources the program reads by workspace path rather than by a
        # `package:` URI. Each is found under the root it sits in, which is
        # not the `main`'s when the two differ: a generated `main` (a
        # variant's test bootstrap) importing a source test beside the
        # application.
        for scheme_file in app_scheme_files(app_pkg_name, app_package_root, inputs.main, inputs.srcs) if inputs.main else []:
            dev_filesystem_roots = with_root(dev_filesystem_roots, app_scheme_location(scheme_file).root)
        dev_filesystem_scheme = dev_pc.scheme
        dev_app_sources = app_scheme_sources(app_pkg_name, app_package_root, inputs.main, inputs.srcs) if inputs.main else []
        dev_generated_source_uris = dev_pc.generated_source_uris
        dev_source_packages = dev_pc.source_packages
        dev_generated_sources = resolve_dev_generated_sources(
            dev_pc.generated_source_paths,
            program_files,
        )

        # The dev package_config's roots and the filesystem roots reach every
        # file the dev compiler may read.
        dev_package_config_names = program_files

    if aot == None:
        aot = mode != "debug"

    # Dev-tool support: what `flutter_bazel` needs in the running app. In
    # debug builds (non-AOT), if the rule carries a `_dev_tool_support_src`
    # attr and `--@rules_flutter//flutter:dev_tool_support` is on, stage the
    # agent and native-patch sources next to the generated registrant, which
    # registers their extensions from the engine's pre-main plugin-registrant
    # hook, and bake in `rules_flutter.build_info` below. Release/AOT/profile
    # builds skip this entirely — profile mode is for performance
    # investigation where added instrumentation distorts measurements, so it
    # must look the same as release on the agent surface.
    support_src_attr = getattr(ctx.attr, "_dev_tool_support_src", None)
    dev_tool_support = (not aot) and mode == "debug" and support_src_attr != None and ctx.attr._dev_tool_support[BuildSettingInfo].value
    staged_agent = None
    staged_native_agent = None
    if dev_tool_support:
        staged_agent = ctx.actions.declare_file(ctx.label.name + ".agent_extensions.dart")
        ctx.actions.symlink(output = staged_agent, target_file = ctx.file._dev_tool_support_src)

        # The native-only half (`dart:ffi`): loading a native hot patch. A
        # kernel compile is always native — web stages `agent.dart` alone, in
        # its own rule.
        staged_native_agent = ctx.actions.declare_file(ctx.label.name + ".native_agent_extensions.dart")
        ctx.actions.symlink(output = staged_native_agent, target_file = ctx.file._native_dev_tool_support_src)

    # Collect plugins from deps and generate the registrant. The registrant is
    # a side library (upstream _PluginRegistrant shape) the engine invokes
    # before main() on every root-isolate launch — including hot restart.
    # One Dart implementation of each federated plugin per platform.
    resolution = application_plugins(ctx.label, inputs.deps)
    plugins = resolution.dart
    registrant = generate_dart_plugin_registrant(
        ctx,
        plugins,
        target_platform = target_platform,
        agent_import = staged_agent.basename if staged_agent else None,
        native_agent_import = staged_native_agent.basename if staged_native_agent else None,
    )
    registrant_location = app_scheme_location(registrant) if registrant else None

    # Dev-loop registrants, one per platform (debug only). The dev tool reads
    # these from a HOST-configuration build while the app can be running on a
    # different platform, so the host build emits every platform's filter and
    # the dev tool selects by the platform the running app reports. See
    # generate_dev_plugin_registrants.
    dev_plugin_registrants = {}
    if emit_dev_config:
        dev_plugin_registrants = generate_dev_plugin_registrants(
            ctx,
            plugins,
            agent_import = staged_agent.basename if staged_agent else None,
            native_agent_import = staged_native_agent.basename if staged_native_agent else None,
        )

    if registrant:
        all_srcs = all_srcs + [registrant]
    if staged_agent:
        all_srcs = all_srcs + [staged_agent, staged_native_agent]

    # `synthesize_app_package` appends the app's own package last. What a rule
    # wrote for the program (`unchecked_srcs`, the plugin registrant, the debug
    # agent extensions) is compiled with it, so its imports are uses of `deps`;
    # they are that rule's to get right, so the check judges only the user's.
    generated = [f for f in inputs.unchecked_srcs if f.extension == "dart"]

    # `entry_srcs` stay among the checked sources, and start the program as
    # far as the reach check goes: what they import counts as reached.
    generated.extend([f for f in inputs.entry_srcs if f.extension == "dart" and f not in generated])
    if registrant:
        generated.append(registrant)
    if staged_agent:
        generated.extend([staged_agent, staged_native_agent])
    import_checks = import_check_output_groups(
        ctx,
        ctx.executable._kernel_tool,
        [f for f in [inputs.main] + inputs.srcs if f not in inputs.unchecked_srcs],
        packages[-1],
        inputs.deps,
        main = inputs.main,
        generated = generated,
    )

    # What flutter_tools warns of and builds on, printed by an action the
    # build requires.
    import_checks = dict(import_checks)
    import_checks["_validation"] = depset(
        plugin_warnings_validation(ctx, resolution),
        transitive = [import_checks["_validation"]],
    )

    # The user's attr + extra_dart_defines flag, the flavor's, and the ones
    # that describe the app and the SDK. Surfaced in the return struct so
    # dev-config writers can replay it on the dev tool's frontend_server; the
    # build mode's `dart.vm.*` keys are the runtime's, not in it.
    flag_defines = flag_dart_defines(ctx, inputs.defines)
    user_defines = list(inputs.defines) + flag_defines
    program_defines = user_defines + flavor_dart_defines(inputs.flavor) + program_version_dart_defines(
        tools.sdk_defines,
        inputs.build_name,
        inputs.build_number,
    )
    all_defines = list(program_defines)

    # A debug app describes its own build to itself. `ext.rules_flutter.buildInfo`
    # hands this straight back to the dev tool, which needs it because
    # `flutter_bazel attach` starts from nothing but a VM service URL: it has no
    # `-d` device, no knowledge of the configuration, and no way to ask the user
    # for flags they never typed. Debug only — profile mode must look like
    # release on the agent surface, and there is no dev loop to serve in AOT —
    # and only with the rest of the dev-tool support.
    #
    # Deliberately NOT added to `program_defines`: that list is replayed by the dev
    # tool's own frontend_server, which runs against the host-configured dev
    # build. Replaying this one would have the app start reporting the dev
    # pipeline's configuration as its launch truth. The dev tool re-injects the
    # value it read from the running app instead.
    if assets_dir != None and dev_tool_support:
        all_defines.append("rules_flutter.build_info=" + json.encode({
            "label": str(ctx.label),
            "compilationMode": ctx.var["COMPILATION_MODE"],
            "platformBuildArgs": platform_build_args,
            # The `extra_dart_defines` flag's value alone: the dev tool passes
            # back as that flag whatever of it a build of this label in its own
            # options does not already have. The target supplies its `defines`,
            # flavor and versions itself, and refuses the reserved keys.
            "extraDartDefines": flag_defines,
            "assetsDir": assets_dir.path,
            # The platform this kernel was compiled for. The dev tool's own
            # build runs in the host platform's configuration, so only the app can say
            # which platform-filtered plugin registrant its reloads need.
            "targetPlatform": target_platform,
            # Whether this kernel was compiled with `--track-widget-creation`.
            # The dev tool's frontend_server recompiles libraries on every hot
            # reload and restart, and must apply the same transform: a library
            # compiled without it would build its widgets with no location
            # while the rest of the app records them.
            "trackWidgetCreation": track_widget_creation,
        }))

    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile(
        ctx,
        tools,
        runtime = mode,
        main = inputs.main,
        srcs = depset(all_srcs),
        packages = packages,
        output = kernel_dill,
        # The user's main, keyed by the URI the dev tool's compiler keys it
        # by (`app_main_location`), so a hot reload's delta applies.
        entrypoint_uri = app_entrypoint_uri,
        aot = aot,
        target_os = target_platform,
        defines = all_defines,
        track_widget_creation = track_widget_creation,
        dart_plugin_registrant_uri = registrant_location.uri if registrant_location else None,
        recorded_uses = recorded_uses,
    )
    return struct(
        kernel_dill = kernel_dill,
        import_checks = import_checks,
        # Dev-loop plugin registrants, keyed by platform (empty outside
        # debug). The dev tool replays the entry matching the running app's
        # platform on its resident frontend_server so the engine hook keeps
        # firing — with the right plugin set — after hot restart.
        dev_plugin_registrants = dev_plugin_registrants,
        # Merged user defines (attr + flag) and the flavor's, without the
        # mode-specific dart.vm.* keys — the dev tool replays these on its own
        # compiler.
        dart_defines = program_defines,
        # Hot-reload dev metadata (None/empty outside debug). Consumed by the
        # rule impl to emit `_dev_config.json` for the dev tool.
        app_entrypoint_uri = app_entrypoint_uri,
        dev_package_config = dev_package_config,
        dev_filesystem_roots = dev_filesystem_roots,
        dev_filesystem_scheme = dev_filesystem_scheme,
        dev_package_config_names = dev_package_config_names,
        dev_generated_sources = dev_generated_sources,
        dev_generated_source_uris = dev_generated_source_uris,
        dev_source_packages = dev_source_packages,
        dev_app_sources = dev_app_sources,
    )

def collect_sdk_shader_srcs(deps):
    """Collect shader source files from transitive FlutterInfo deps.

    These are raw .frag/.glsl files (e.g. Flutter SDK material shaders)
    that need to be compiled per-platform before inclusion in the asset bundle.

    Args:
        deps: List of targets, some of which may provide FlutterInfo.

    Returns:
        List of shader source Files.
    """
    transitive_depsets = [
        dep[FlutterInfo].shader_srcs
        for dep in deps
        if FlutterInfo in dep
    ]
    if transitive_depsets:
        return depset(transitive = transitive_depsets).to_list()
    return []

def _shader_jobs(ctx, deps, target_platform, inputs):
    """Every shader this target bundles, as struct(bundle_path, file, includes, listed).

    `listed` says whether the asset manifest lists the shader. Flutter's own
    (`ink_sparkle.frag`, `stretch_effect.frag`) are bundled and not listed:
    flutter_tools adds them to every bundle beside, not among, the assets the
    manifest names, and the engine loads a shader by its path
    (`FragmentProgram.fromAsset`), never through the manifest.

    User shaders keep their path in the target's package ("shaders/my_effect.frag"),
    SDK shaders go under "shaders/<basename>" (Flutter's convention), and a
    package's are keyed as `asset_key` says: bare "<path>" for the program's
    own package, "packages/<pkg>/<path>" for any other. Two shaders claiming
    one bundle path fail here: one would otherwise overwrite the other.

    A package's shader that its `platforms:` entry restricts to other platforms
    than `target_platform` is no job, as flutter_tools leaves it out of a build
    for them; `tester` and None leave out nothing. One that its `flavors:` entry
    restricts is a job only for a build of one of those flavors (`inputs.flavor`),
    never for a build without one, `tester` included.
    """
    jobs = []
    program_root = package_root_of(inputs)
    for shader in inputs.shaders:
        jobs.append(struct(bundle_path = path_in_package(inputs.label, program_root, shader), file = shader, includes = inputs.shader_includes, listed = True))
    for shader in collect_sdk_shader_srcs(deps):
        jobs.append(struct(bundle_path = "shaders/" + shader.basename, file = shader, includes = [], listed = False))
    for dep in deps:
        if FlutterInfo in dep:
            for entry in dep[FlutterInfo].pub_shaders.to_list():
                if not ships_in(entry, target_platform, inputs.flavor):
                    continue
                jobs.append(struct(
                    bundle_path = bundle_key(entry, entry.shader_path, program_root),
                    file = entry.file,
                    includes = entry.includes,
                    listed = True,
                ))

    # One package can reach a target along several paths; the same file at
    # the same bundle path is one shader.
    by_path = {}
    for job in jobs:
        seen = by_path.get(job.bundle_path)
        if seen == None:
            by_path[job.bundle_path] = job
        elif seen.file != job.file:
            fail("%s: two shaders are bundled at %s: %s and %s." % (
                ctx.label,
                job.bundle_path,
                seen.file.short_path,
                job.file.short_path,
            ))
    return by_path.values()

def shader_sources(ctx, deps, target_platform, inputs = None):
    """The workspace files behind each bundled shader, for the dev tool.

    `{bundle path: [workspace-relative path]}`: the shader and what it may
    `#include`, where those are source files of this workspace. A shader from
    another repository maps to an empty list; it is still a shader, which is
    what the dev tool needs to know to make the app reload it.

    Args:
        ctx: Rule context (must have the shaders attr).
        deps: The dependencies whose packages' shaders are bundled: the ones
            `flutter_compile_shaders` was given.
        target_platform: The platform the build is for, as `flutter_compile_shaders`
            was given it.
        inputs: The program whose shaders these are, as `flutter_compile_shaders`
            was given it.

    Returns:
        The dict above.
    """
    if inputs == None:
        inputs = flutter_program_inputs(ctx)
    return {
        job.bundle_path: [
            f.short_path
            for f in [job.file] + list(job.includes)
            if f.is_source and not f.short_path.startswith("../")
        ]
        for job in _shader_jobs(ctx, deps, target_platform, inputs)
    }

def asset_roots(ctx, deps, inputs = None):
    """The workspace directories the first-party assets come from, for the dev tool.

    `{bundle path prefix: workspace-relative directory}`: `""` for the
    program's own package, whose assets are bare whichever target lists them,
    and `packages/<name>/` for each other package among `deps` with assets in
    this workspace. An asset is bundled under its path from its package's
    root, which says nothing of where in the workspace the package is; this
    does, so the dev tool can watch the files and find one added later.

    Args:
        ctx: Rule context.
        deps: The dependencies whose packages' assets are bundled: the ones
            `flutter_build_assets` was given.
        inputs: The program whose assets these are, as `flutter_build_assets`
            was given it; its `label` says which package is its own.

    Returns:
        The dict above.
    """
    if inputs == None:
        inputs = flutter_program_inputs(ctx)
    program_root = package_root_of(inputs)
    roots = {"": program_root or "."}
    for dep in deps:
        if FlutterInfo not in dep:
            continue
        for entry in dep[FlutterInfo].pub_assets.to_list():
            f = entry.file
            if not entry.package_name or entry.package_root == program_root:
                continue
            if not f.is_source or f.short_path.startswith("../"):
                continue
            roots["packages/%s/" % entry.package_name] = entry.package_root or "."
    return roots

def flutter_compile_shaders(ctx, tools, target_platform, deps, inputs = None):
    """Compile every shader this target bundles for the target platform.

    The shaders are the target's own (`shaders`), the SDK's (collected from
    FlutterInfo.shader_srcs) and its packages' (FlutterInfo.pub_shaders); see
    `_shader_jobs` for where each is bundled.

    Args:
        ctx: Rule context (must have the shaders attr).
        tools: `FlutterExecToolsInfo` of the `PORTABLE` group (`portable_tools`).
        target_platform: Target platform string ("ios", "macos", "android", "linux", "windows", "web").
        deps: The dependencies whose SDK and package shaders are bundled.
            Named by the caller rather than read off `ctx.attr.deps`: a rule
            whose `deps` edge is split sees every branch's copy there.
        inputs: The program whose shaders are bundled, from
            `flutter_program_inputs`; `ctx`'s own when None.

    Returns:
        struct(listed, unlisted): lists of (bundle destination path, compiled
        File), the shaders the asset manifest lists and the ones it does not.
        Pass to `flutter_build_assets`.
    """
    if inputs == None:
        inputs = flutter_program_inputs(ctx)
    jobs = _shader_jobs(ctx, deps, target_platform, inputs)
    compiled = struct(listed = [], unlisted = [])
    if not jobs or not tools.impellerc:
        return compiled

    for job in jobs:
        # Named by the bundle path, which is unique, so no two outputs meet.
        out_path = job.bundle_path.replace("../", "_external/")
        output = ctx.actions.declare_file(ctx.label.name + "_shaders/" + out_path + ".iplr")
        flutter_shader_compile_action(
            ctx = ctx,
            impellerc = tools.impellerc,
            shader_lib = tools.shader_lib,
            shader_include_dir = tools.shader_include_dir,
            shader = job.file,
            output = output,
            target_platform = target_platform,
            is_web = target_platform == "web",
            includes = job.includes,
            # What compiles a shader whose SkSL stage fails without it.
            dart = tools.dart,
            dart_files = tools.sdk_files.run,
            compile_tool = ctx.file._shader_compile_tool,
            require_sksl = inputs.require_sksl_shaders,
        )
        (compiled.listed if job.listed else compiled.unlisted).append((job.bundle_path, output))
    return compiled

def declare_flutter_assets_dir(ctx):
    """Declare the `flutter_assets/` tree artifact for this target.

    Split out from `flutter_build_assets` so a rule can name the directory
    before it compiles the kernel: an application bakes this path into
    `rules_flutter.build_info.assetsDir`, and the dev tool matches the app's
    reported value against the tree it watches and rebuilds. Every rule that
    bundles assets uses this one helper so the name is stated in a single
    place rather than re-spelled at each call site.

    Args:
        ctx: Rule context.

    Returns:
        The declared directory (tree artifact) File.
    """
    return ctx.actions.declare_directory(ctx.label.name + "_flutter_assets")

def program_package(inputs):
    """A program's own package record, as rules_dart's program helpers take it.

    The program's own package is one of its packages exactly as a
    dependency's is, whether or not a library in its `deps` names the same
    declaration: its code and data assets ship and its link hook runs. A
    library of the package in `deps` merges into this record.

    Args:
        inputs: The program, from `flutter_program_inputs`.

    Returns:
        The program's `DartPackageInfo`, or None for a program naming no
        `dart_package_metadata`.
    """
    if inputs.package == None:
        return None
    return package_info_from_metadata(inputs.label, inputs.package, inputs.package_root)

def program_package_files(inputs):
    """A program's own files under its package's `lib/`.

    What the package's link hook may import, as any package's hook imports
    its own `lib/`. The program's other files (a `main` outside `lib/`, say)
    are no part of what `package:<self>/` resolves to.

    Args:
        inputs: The program, from `flutter_program_inputs`.

    Returns:
        List of Files; empty for a program in no package.
    """
    if inputs.package == None:
        return []
    prefix = package_lib_prefix(inputs.package_root)
    return [
        f
        for f in ([inputs.main] if inputs.main else []) + inputs.srcs
        if f.short_path.startswith(prefix)
    ]

def shakes_icons(inputs, tools, is_debug):
    """Whether a program's bundle tree-shakes its icon fonts.

    A profile or release build with `tree_shake_icons` does, as `flutter
    build` does; it reads the `IconData` uses the program's compiles record,
    so only such a build (or one whose link hooks run) has them record any.

    Args:
        inputs: The program, from `flutter_program_inputs`.
        tools: `FlutterExecToolsInfo` of the `PORTABLE` group.
        is_debug: Whether this is a debug build.

    Returns:
        A bool.
    """
    return inputs.tree_shake_icons and not is_debug and tools.font_subset != None

def flutter_build_assets(ctx, tools, output_dir, deps, target_platform, compiled_shaders = struct(listed = [], unlisted = []), recorded_uses = [], is_debug = False, program_assets = None, native_assets_manifest = None, optional_code_points = [], inputs = None):
    """Run the shared asset bundling step.

    Walks `FlutterInfo.pub_fonts` / `pub_assets` from deps to bundle
    pub-package contributions (fonts/assets — shaders are pre-compiled by
    `flutter_compile_shaders` and arrive via `compiled_shaders`).

    Args:
        ctx: Rule context (must have assets, tree_shake_icons attrs, `_asset_bundle_tool`, `_notices_tool` and `_engine_license`).
        tools: `FlutterExecToolsInfo` of the `PORTABLE` group (`portable_tools`).
        output_dir: The tree artifact to bundle into, from
            `declare_flutter_assets_dir`. Passed in rather than declared here
            so an application can bake the path into its `build_info` before
            the kernel compile that this action depends on.
        deps: The dependencies whose assets and pub contributions are
            bundled. Named by the caller rather than read off
            `ctx.attr.deps`: a rule whose `deps` edge is split sees every
            branch's copy there, and would bundle each package once per
            branch.
        target_platform: The platform the bundle is for ("android", "ios",
            "linux", "macos", "windows", "web", or "tester" for a test), which
            leaves out the pub assets restricted to other platforms.
        compiled_shaders: What `flutter_compile_shaders` made.
        recorded_uses: The recorded-uses JSON Files the program's AOT
            compiles wrote (one per compiler), from which icon tree shaking
            reads the `IconData` the program uses. Needed when
            `shakes_icons`; empty otherwise.
        is_debug: Whether this is a debug build (icon tree shaking is skipped in debug).
        program_assets: Optional `DartProgramAssetsInfo` of the program. Each
            data asset it ships is placed at
            `flutter_assets/packages/<package>/<name>` and listed in the
            asset manifest under that key, as flutter_tools bundles a hook's
            data asset. They are read in the bundling action: a linked
            program's hooks decide what ships only when they run.
        native_assets_manifest: Optional File, the app's native-assets
            manifest, bundled as `NativeAssetsManifest.json`, where the engine
            reads it at startup. Not in the asset manifest, as upstream's is
            not.
        optional_code_points: Code points every subset icon font keeps if it
            has a glyph for them, whether or not the app uses them.
        inputs: The program whose assets are bundled, from
            `flutter_program_inputs`; `ctx`'s own when None. Its package,
            the one `inputs.label` is in, is the program's own: its assets,
            and those of every library of that package, are keyed by their
            path from the package root, with no `packages/<name>/`.

    Returns:
        The flutter_assets/ tree artifact File.
    """
    if inputs == None:
        inputs = flutter_program_inputs(ctx)

    # Walk pub-package font/asset contributions from FlutterInfo.
    # MaterialIcons is no longer special-cased here — apps depend on
    # `@rules_flutter//flutter:material_icons` to get it via this same path.
    fonts, pub_copies, unlisted_copies = aggregate_pub_contributions(deps, target_platform, inputs.flavor, package_root_of(inputs))
    extra_asset_copies = compiled_shaders.listed + pub_copies
    unlisted_copies = compiled_shaders.unlisted + unlisted_copies
    if native_assets_manifest != None:
        unlisted_copies = unlisted_copies + [("NativeAssetsManifest.json", native_assets_manifest)]

    # The licences the program ships, in the one asset the framework reads
    # them from. `inputs` has the program's own; a package's reach this when
    # the closure's licences are collected too.
    web = target_platform == "web"
    own_package = [(inputs.package_name, inputs.license_file)] if inputs.license_file else []
    own_additional = [(inputs.package_name, inputs.additional_licenses)] if inputs.additional_licenses else []
    notices = flutter_notices_action(
        ctx = ctx,
        tools = tools,
        packages = package_licenses_of(deps, own_package),
        additional = additional_licenses_of(deps, own_additional),
        engine_license = ctx.file._engine_license,
        web = web,
    )
    unlisted_copies = unlisted_copies + [(notices_asset_key(web), notices)]

    tree_shake_icons = shakes_icons(inputs, tools, is_debug)
    if tree_shake_icons:
        if not recorded_uses:
            fail("%s: icon tree shaking reads the uses the program's compiles record, and none were given" % ctx.label)

    return flutter_asset_bundle_action(
        ctx = ctx,
        dart = tools.dart,
        dart_files = tools.sdk_files.run,
        assets = inputs.assets,
        owner = inputs,
        fonts = fonts,
        output_dir = output_dir,
        font_subset = tools.font_subset if tree_shake_icons else None,
        recorded_uses = recorded_uses if tree_shake_icons else [],
        optional_code_points = optional_code_points,
        extra_asset_copies = extra_asset_copies,
        unlisted_asset_copies = unlisted_copies,
        program_assets = program_assets,
    )

def compute_desktop_bundle_copies(is_debug, kernel_dill_path, aot_output_path, aot_dst, icu_data_path, engine_basenames, native_basenames, engine_dst_prefix = "lib/", native_dst_prefix = "lib/"):
    """Compute the file-copy list for a desktop Flutter bundle.

    Builds the list of {"src": ..., "dst": ...} dicts that the Dart bundler
    tool uses to assemble a Linux or Windows application directory.

    Args:
        is_debug: Whether this is a debug build.
        kernel_dill_path: Source path to kernel .dill file (used in debug mode), or None.
        aot_output_path: Source path to AOT output (used in release mode), or None.
        aot_dst: Destination path for AOT output (e.g. "lib/libapp.so" or "app.so").
        icu_data_path: Source path to icudtl.dat.
        engine_basenames: List of (src_path, basename) tuples for engine files.
        native_basenames: List of (src_path, basename) tuples for native FFI libs.
        engine_dst_prefix: Destination prefix for engine files (default "lib/").
        native_dst_prefix: Destination prefix for native FFI / Native
            Assets `dynamic_loading_bundle` libs. Linux uses `lib/`
            (next to libapp.so); Windows uses `""` so DLLs land next to
            the runner `.exe` where Windows' dynamic loader picks them
            up via the standard search order.

    Returns:
        List of {"src": ..., "dst": ...} dicts.
    """
    copies = [{"src": icu_data_path, "dst": "data/icudtl.dat"}]

    if is_debug and kernel_dill_path:
        # The Flutter engine's embedder looks for kernel_blob.bin inside the
        # assets directory (settings.assets_path / "kernel_blob.bin").
        copies.append({"src": kernel_dill_path, "dst": "data/flutter_assets/kernel_blob.bin"})
    elif aot_output_path:
        copies.append({"src": aot_output_path, "dst": aot_dst})

    for src_path, basename in engine_basenames:
        copies.append({"src": src_path, "dst": engine_dst_prefix + basename})

    for src_path, basename in native_basenames:
        copies.append({"src": src_path, "dst": native_dst_prefix + basename})

    return copies

# Android ABIs with AOT cross-compilation support. Single source of truth
# mapping each ABI to the Bazel platform Android rules transition to and the
# ELF e_machine value native libraries packaged for that ABI must carry.
ANDROID_ABIS = {
    "armeabi-v7a": struct(
        platform = Label("@rules_android//:armeabi-v7a"),
        elf_machine = 40,  # EM_ARM
    ),
    "arm64-v8a": struct(
        platform = Label("@rules_android//:arm64-v8a"),
        elf_machine = 183,  # EM_AARCH64
    ),
    "x86_64": struct(
        platform = Label("@rules_android//:x86_64"),
        elf_machine = 62,  # EM_X86_64
    ),
}

def android_platform_for_abi(abi):
    """The Bazel platform label Android rules build for, given an ABI.

    Args:
        abi: Android ABI string ("armeabi-v7a", "arm64-v8a" or "x86_64").

    Returns:
        A Label for the platform under //flutter/platforms.
    """
    if abi not in ANDROID_ABIS:
        fail("Unsupported Android ABI '{}'. Supported: {}.".format(
            abi,
            ", ".join(ANDROID_ABIS.keys()),
        ))
    return ANDROID_ABIS[abi].platform

def android_elf_machine_for_abi(abi):
    """The ELF e_machine value native libraries must have for an ABI.

    Args:
        abi: Android ABI string ("armeabi-v7a", "arm64-v8a" or "x86_64").

    Returns:
        The e_machine value as an int (e.g. 183 for EM_AARCH64).
    """
    if abi not in ANDROID_ABIS:
        fail("Unsupported Android ABI '{}'. Supported: {}.".format(
            abi,
            ", ".join(ANDROID_ABIS.keys()),
        ))
    return ANDROID_ABIS[abi].elf_machine

def host_target_arch(ctx, flutter_sdk_info):
    """Best-effort target architecture string for Native Assets.

    The toolchain's `target_arch` is set on cross-compilation toolchains
    but empty for native builds. For native builds we infer from
    `bin_dir` path. Returns one of `arm64`, `x64`, `arm`, or "" if
    unknown. The empty string causes the Native Assets manifest to omit
    the target section, which is still valid for the engine.

    Args:
      ctx: Rule context — used only for `ctx.bin_dir`.
      flutter_sdk_info: `FlutterSdkInfo` from the toolchain. Carries the
        `target_arch` field, which when set wins over the heuristic.

    Returns:
      A lowercase architecture string (`arm64`, `x64`, `arm`) or "" when
      neither the toolchain nor the bin_dir hint at a known arch.
    """
    if flutter_sdk_info.target_arch:
        return flutter_sdk_info.target_arch

    # Heuristic: parse the bazel-out output dir for cpu hints. The bin_dir
    # path looks like `bazel-out/<cpu>-<mode>/bin`. Match the same `cpu`
    # values rules_flutter assumes elsewhere. Windows cpu names put the
    # arch first (`x64_windows`, `arm64_windows`), so match those before
    # the suffix-style patterns.
    bin_dir = ctx.bin_dir.path
    if "arm64_windows" in bin_dir:
        return "arm64"
    if "x64_windows" in bin_dir:
        return "x64"
    if "darwin_arm64" in bin_dir or "_arm64" in bin_dir:
        return "arm64"
    if "darwin_x86_64" in bin_dir or "_x86_64" in bin_dir or "_amd64" in bin_dir or "k8" in bin_dir:
        return "x64"
    if "darwin_x64" in bin_dir or "_x64" in bin_dir:
        return "x64"
    if "armv7" in bin_dir or "arm-" in bin_dir:
        return "arm"
    return ""

def detect_target_platform(is_ios, is_macos, is_linux, is_windows, is_android):
    """Detect the Flutter target platform from constraint booleans.

    Args:
        is_ios: True if target platform is iOS.
        is_macos: True if target platform is macOS.
        is_linux: True if target platform is Linux.
        is_windows: True if target platform is Windows.
        is_android: True if target platform is Android.

    Returns:
        Platform string: "ios", "macos", "linux", "windows", or "android".
        Fails if no platform matches.
    """
    if is_ios:
        return "ios"
    elif is_macos:
        return "macos"
    elif is_linux:
        return "linux"
    elif is_windows:
        return "windows"
    elif is_android:
        return "android"
    else:
        fail(
            "No supported Flutter target platform detected. " +
            "Supported platforms: android, ios, macos, linux, windows. " +
            "Use --platforms= to set the target platform.",
        )

# Shared platform constraint attrs used by rules that need to check target platform.
PLATFORM_CONSTRAINT_ATTRS = {
    "_macos_constraint": attr.label(
        default = "@platforms//os:macos",
    ),
    "_ios_constraint": attr.label(
        default = "@platforms//os:ios",
    ),
    "_linux_constraint": attr.label(
        default = "@platforms//os:linux",
    ),
    "_windows_constraint": attr.label(
        default = "@platforms//os:windows",
    ),
    "_android_constraint": attr.label(
        default = "@platforms//os:android",
    ),
    # CPU alongside OS, because Android's ABI selects a whole platform label
    # in `launch_build_args`. Read from the resolved platform rather than
    # parsed out of `ctx.bin_dir` the way `host_target_arch` still does — a
    # value the dev tool builds against has to be right or absent, not
    # guessed.
    "_arm64_constraint": attr.label(
        default = "@platforms//cpu:arm64",
    ),
    "_x86_64_constraint": attr.label(
        default = "@platforms//cpu:x86_64",
    ),
    "_armv7_constraint": attr.label(
        default = "@platforms//cpu:armv7",
    ),
}

def launch_build_args(target_platform, is_simulator, is_arm64, is_x86_64, is_armv7 = False):
    """The bazel flags the *launch target's* build needs to produce this app.

    MIRRORS `Device.buildArgs` in `tools/dev_tool/lib/device.dart`. The dev
    tool normally gets these from the `-d` device the user named — but
    `flutter_bazel attach` has no `-d`, and even on `run` these flags come
    from the device rather than from anything the user typed, so they are not
    something an attaching process can ask the user to repeat. The app
    therefore carries them, and the dev tool replays them when it builds and
    queries the wrapper. Keep the two lists in step; a drift shows up as the
    dev tool's `assetsDir` mismatch, loudly, rather than as a silent rebuild
    into a tree the app never reads.

    These are NOT flags that would reproduce this configuration on a bare
    build of the `flutter_application` itself. That is not expressible: the
    Apple and Android wrappers reach this target through split transitions
    whose output directories (`…-ST-<hash>`) no command line can name. These
    are the flags for the *wrapper*, which is what the dev tool builds.

    Takes booleans rather than `ctx` for the same reason
    `detect_target_platform` does: the interesting part is the mapping, and a
    mapping only a configured target can call is a mapping nothing can test.

    Args:
        target_platform: Platform string from `detect_target_platform`.
        is_simulator: True when the Apple target environment is the simulator.
            Resolved by the caller through `apple_support`, which is where
            that question is answerable; ignored off Apple.
        is_arm64: True when the target platform has the arm64 CPU constraint.
        is_x86_64: True when it has the x86_64 CPU constraint.
        is_armv7: True when it has the 32-bit ARM (armv7) CPU constraint.

    Returns:
        list[str] of bazel flags. Empty on desktop.
    """
    if target_platform == "ios":
        # `Device.buildArgs` hardcodes arm64 on both sides — a 32-bit or x86
        # simulator is not a target rules_flutter builds for.
        return ["--ios_multi_cpus=sim_arm64"] if is_simulator else ["--ios_multi_cpus=arm64"]

    if target_platform == "android":
        if is_arm64:
            abi = "arm64-v8a"
        elif is_x86_64:
            abi = "x86_64"
        elif is_armv7:
            abi = "armeabi-v7a"
        else:
            fail(
                "flutter_application: the Android target platform has no armv7, arm64 or " +
                "x86_64 CPU constraint, so the `--@rules_android//flags:android_platforms` flag a dev-loop rebuild " +
                "needs cannot be named. rules_android ships @rules_android//:armeabi-v7a, " +
                "@rules_android//:arm64-v8a and @rules_android//:x86_64.",
            )
        return ["--@rules_android//flags:android_platforms=@rules_android//:" + abi]

    # Desktop needs no flag: the app is already built in the top-level
    # configuration. `Device.buildArgs` emits `--platforms=` only when
    # cross-building, and that case is out of reach here anyway — the dev tool
    # reads the app's own bazel-out paths, so it has to be on the machine that
    # built it. Emitting the flag regardless would move a dev-loop rebuild to a
    # different output directory than the one the running app came from.
    return []

DEV_TOOL_SUPPORT_ATTRS = {
    "_dev_tool_support_src": attr.label(
        doc = "The service extensions `flutter_bazel` drives a debug app through. Registered from the generated plugin registrant in debug builds; ignored in AOT/release.",
        default = Label("//flutter/private/dev_tool_support:agent.dart"),
        allow_single_file = [".dart"],
    ),
    "_native_dev_tool_support_src": attr.label(
        doc = "The native-only extensions (`dart:ffi`): loading a `flutter_native_library.hot_patch`. Staged beside `_dev_tool_support_src` in native debug builds; never on web.",
        default = Label("//flutter/private/dev_tool_support:native_patch.dart"),
        allow_single_file = [".dart"],
    ),
    "_dev_tool_support": attr.label(
        doc = "`--@rules_flutter//flutter:dev_tool_support`: false leaves both, and `rules_flutter.build_info`, out of a debug build.",
        default = Label("//flutter:dev_tool_support"),
    ),
}

BUILD_MODE_ATTR = {
    "_profile_flag": attr.label(
        doc = "The //flutter:profile build setting. Read through `flutter_build_mode`.",
        default = Label("//flutter:profile"),
    ),
}

def flutter_build_mode(ctx):
    """Flutter's build mode for this configuration: "debug", "profile" or "release".

    `-c dbg` is debug and any other `-c` is release, unless
    `--@rules_flutter//flutter:profile` asks for profile, which needs `-c opt`:
    the engine and gen_snapshot selects match profile only there, and a
    profile Dart snapshot on any other engine does not start.

    Args:
        ctx: Rule context carrying `BUILD_MODE_ATTR`.

    Returns:
        "debug", "profile" or "release".
    """
    compilation_mode = ctx.var["COMPILATION_MODE"]
    if ctx.attr._profile_flag[BuildSettingInfo].value:
        if compilation_mode != "opt":
            fail(
                "--@rules_flutter//flutter:profile builds Flutter's profile mode, " +
                "which is optimized AOT code and needs -c opt (this build is -c " +
                compilation_mode + "). Add -c opt, or drop the flag.",
            )
        return "profile"
    return "debug" if compilation_mode == "dbg" else "release"

# The command-line defines flag is rules_dart's, so a Flutter compile and a
# Dart one in the same build read the same declarations.
EXTRA_DART_DEFINES_ATTR = {
    "_extra_dart_defines": attr.label(
        doc = "rules_dart's `//dart:extra_dart_defines` build setting, appended after the target's own `defines`.",
        default = Label("@rules_dart//dart:extra_dart_defines"),
        providers = [BuildSettingInfo],
    ),
}

# The define `appFlavor` reads. flutter_tools sets it from `--flavor` and
# refuses a user's own, as the ruleset does from `flavor`.
APP_FLAVOR_DEFINE = "FLUTTER_APP_FLAVOR"

def flavor_dart_defines(flavor):
    """The define `appFlavor` reads for `flavor`, as flutter_tools adds it; none for no flavor.

    Args:
        flavor: The program's `flavor`; empty for none.

    Returns:
        A list of zero or one `KEY=VALUE` define.
    """
    return ["%s=%s" % (APP_FLAVOR_DEFINE, flavor)] if flavor else []

def flag_dart_defines(ctx, defines = None):
    """The `extra_dart_defines` flag's defines, after checking them and the target's own.

    rules_dart reserves no key; the Flutter build sets some itself (see
    `RESERVED_DART_DEFINE_KEYS`), so they are refused here, from the target's
    `defines` and from the command line alike.

    Args:
        ctx: Rule context with `defines` and `_extra_dart_defines` attrs.
        defines: The target's own defines, if not `ctx`'s: a program rebuilt
            under another target carries the application's, and its own.

    Returns:
        The flag's list of KEY=VALUE define strings.
    """
    if defines == None:
        defines = ctx.attr.defines
    validate_dart_defines(defines, "defines attribute of %s" % ctx.label)
    flag = ctx.attr._extra_dart_defines[BuildSettingInfo].value
    validate_dart_defines(flag, "`--@rules_dart//dart:extra_dart_defines`, building %s" % ctx.label)
    return flag

def merge_dart_defines(ctx, defines = None):
    """Merge a target's `defines` attr with the extra_dart_defines flag.

    Flag values come after attr values, so on a duplicated key the command
    line wins (the compilers take the last -D). Both are checked for the
    keys the build reserves.

    Args:
        ctx: Rule context with `defines` and `_extra_dart_defines` attrs.
        defines: The target's own defines, if not `ctx`'s: a program rebuilt
            under another target carries the application's, and its own.

    Returns:
        The merged list of KEY=VALUE define strings.
    """
    if defines == None:
        defines = ctx.attr.defines
    return list(defines) + flag_dart_defines(ctx, defines)

def flutter_deps_attr(aspects = [], **kwargs):
    """The `deps` attribute of every rule that compiles a Flutter program.

    Args:
        aspects: Aspects a rule applies over its `deps` on top of the import
            check every such rule runs.
        **kwargs: Further arguments to `attr.label_list`, such as the `cfg` of
            a rule that builds its dependencies for several compilers.

    Returns:
        The `attr.label_list`.
    """
    return attr.label_list(
        doc = "`dart_library` or `flutter_library` dependencies. A rule that " +
              "builds an asset bundle needs `@rules_flutter//flutter:material_icons` " +
              "listed here to bundle `MaterialIcons-Regular.otf` into " +
              "`flutter_assets/` for Material widgets; the rules that emit only " +
              "a kernel or an AOT artifact have no bundle for it to reach.",
        providers = [DartInfo],
        # Each library's imports are checked against its own `deps`, in the
        # `_validation` output group. `FlutterInfo` is read across libraries
        # of other rule sets.
        aspects = [dart_import_check_aspect, flutter_info_forwarding_aspect] + aspects,
        **kwargs
    )

def flutter_program_inputs(ctx, metadata = None):
    """The Flutter program a rule compiles, read off its attributes.

    What the compile and bundling helpers (`flutter_compile_kernel`,
    `flutter_compile_shaders`, `flutter_build_assets`, `gen_snapshot_options`)
    read of the program, as one value. A rule that is not the program's own
    (`flutter_application_variant`: the application, with another `main`)
    passes an `inputs` of its own making, so those helpers need no rule
    context shaped like the application's.

    Every field is read whether or not `ctx` declares it, and is empty when it
    does not: a rule compiling a kernel has no assets, and one with no
    `main` attribute has no `main`.

    Args:
        ctx: Rule context.
        metadata: The `DartPackageMetadataInfo` of the package the program is
            in, when it comes from elsewhere than `ctx`'s `package` (a test
            compiled in its application's package). A `package` the rule also
            names must be the same declaration.

    Returns:
        A struct. `label` is the target the program is built for, and
        `package` the `DartPackageMetadataInfo` of the package it is in (None
        for a rule naming none), whose `package_name`, `package_root` (what
        each asset is keyed from), `language_version` and `license_file` are
        fields of their own; `main`, `srcs`, `assets`, `shaders`,
        `shader_includes`, `license_file` and `additional_licenses` are Files
        (`unchecked_srcs`, among `srcs`, are not checked against `deps`;
        `entry_srcs`, among `srcs`, need not be reached from `main`, as a
        variant's application's are;
        `staged_sources` are the sources of staged copies among them, which
        analysis checks in their place); `deps`,
        `native_deps` and `code_assets` are Targets, as is `package_target`,
        the `package` Target (None for a rule naming none); the rest, `flavor`
        among them, are as the attributes of `flutter_application` of the same
        names, but for `build_name` and `build_number`: those are the version
        the program has, which `--@rules_flutter//flutter:build_name` and
        `build_number` replace when set, and `stated_build_name` and
        `stated_build_number` are the attributes; `version_settings` names the
        settings that are set, as `program_version` does.
    """
    identity = resolve_package_identity(ctx, metadata = metadata)
    version = program_version(ctx)
    return struct(
        label = ctx.label,
        main = getattr(ctx.file, "main", None),
        srcs = list(getattr(ctx.files, "srcs", [])),
        unchecked_srcs = [],
        entry_srcs = [],
        staged_sources = [],
        deps = getattr(ctx.attr, "deps", []),
        package_target = getattr(ctx.attr, "package", None),
        defines = list(getattr(ctx.attr, "defines", [])),
        flavor = getattr(ctx.attr, "flavor", ""),
        build_name = version.build_name,
        build_number = version.build_number,
        stated_build_name = version.stated_build_name,
        stated_build_number = version.stated_build_number,
        version_settings = version.settings,
        package = identity.metadata,
        package_name = identity.package_name,
        package_root = identity.package_root,
        language_version = identity.language_version,
        assets = list(getattr(ctx.files, "assets", [])),
        shaders = list(getattr(ctx.files, "shaders", [])),
        shader_includes = list(getattr(ctx.files, "shader_includes", [])),
        require_sksl_shaders = getattr(ctx.attr, "require_sksl_shaders", False),
        license_file = identity.license_file,
        additional_licenses = list(getattr(ctx.files, "additional_licenses", [])),
        tree_shake_icons = getattr(ctx.attr, "tree_shake_icons", False),
        native_deps = list(getattr(ctx.attr, "native_deps", [])),
        code_assets = list(getattr(ctx.attr, "code_assets", [])),
        track_widget_creation = getattr(ctx.attr, "track_widget_creation", False),
        minimum_os_version = getattr(ctx.attr, "minimum_os_version", ""),
        extra_gen_snapshot_options = list(getattr(ctx.attr, "extra_gen_snapshot_options", [])),
    )

# The `package` of a program, the doc of `KERNEL_COMPILE_ATTRS`' own. A rule
# that applies an aspect to the declaration (to reach what it declares)
# redeclares the attribute with this doc.
PROGRAM_PACKAGE_DOC = (
    "The `dart_package_metadata` declaring the program's own Dart " +
    "package, the Bazel stand-in for its `pubspec.yaml`. Required: " +
    "its `package_name` keys the kernel's libraries under stable " +
    "`package:` URIs (hot-reload parity with the dev tool) and " +
    "resolves `package:<self>/...` imports; its `language_version` " +
    "is the program's own, as pub derives it from " +
    "`environment.sdk` (left unset, the program's sources compile " +
    "at the SDK's current version, newer than `flutter build` " +
    "would allow); its `license_file` is listed in `NOTICES.Z` " +
    "under the package's name. Its name is free. The package is " +
    "rooted at the declaration's directory, or, for one in a BUILD " +
    "file under `lib/`, at the directory above that `lib`; `srcs` " +
    "(its `lib/`) and the keys of `assets` are relative to that " +
    "root.\n\n" +
    "The `flutter_library` targets of the same package — the app's " +
    "own `lib/`, beside it — name the same declaration. Two Dart " +
    "packages cannot share a directory, so a dependency declaring " +
    "a different package at the program's root is refused."
)

# The attrs `flutter_compile_kernel` reads off its caller's `ctx`. Every rule
# that calls it spreads this bundle wholesale rather than naming the members,
# because naming them is what let the contract break: `flutter_compile_kernel`
# reaches into `ctx.attr.package` on whatever context it is handed,
# and the two callers that built a narrowed attr surface — `flutter_aot_snapshot`
# cherry-picking from `FLUTTER_APPLICATION_ATTRS`, `flutter_kernel`
# hand-rolling a near-copy that had already drifted — simply did not have it.
# One failed at analysis, the other silently; a caller that spreads the bundle
# can omit nothing.
#
# Per-rule inputs stay out. `track_widget_creation` and `assets_dir`
# are function parameters of `flutter_compile_kernel` for the reason its
# docstring gives — the callers genuinely disagree about whether they have one
# — and `_dev_tool_support_src` is declared by the rules that inject the agent,
# not by every kernel compile.
KERNEL_COMPILE_ATTRS = package_identity_attrs(
    mandatory = True,
    doc = PROGRAM_PACKAGE_DOC,
) | {
    "main": attr.label(
        doc = "The main .dart entry point.",
        mandatory = True,
        allow_single_file = [".dart"],
        # A `main` a rule writes is written in the configuration the build
        # had before any web app's transition, so it is in the same output
        # directory as the web app's own wrapper that imports it.
        cfg = runtime_reset,
    ),
    "srcs": attr.label_list(
        doc = "Additional Dart source files.",
        allow_files = [".dart"],
    ),
    "deps": flutter_deps_attr(),
    "defines": attr.string_list(
        doc = "Dart environment defines (-D flags).",
    ),
    "build_name": attr.string(
        doc = "The app's version name, as the `version:` of `pubspec.yaml`: " +
              "`appBuildName` (`package:flutter/services.dart`) reads it. " +
              "Unset is `flutter create`'s `1.0.0`. The platform apps built over " +
              "this application take their bundle's version from it, unless " +
              "they set their own `build_name`, which must then be this one. " +
              "`--@rules_flutter//flutter:build_name` replaces it for one build, " +
              "as `flutter build --build-name` does.",
    ),
    "build_number": attr.string(
        doc = "The app's build number, as the `version:` of `pubspec.yaml`: " +
              "`appBuildNumber` (`package:flutter/services.dart`) reads it. " +
              "Unset is `flutter create`'s `1`. " +
              "`--@rules_flutter//flutter:build_number` replaces it for one build, " +
              "as `flutter build --build-number` does.",
    ),
    "flavor": attr.string(
        doc = "The app's flavor, as `flutter build --flavor`: `appFlavor` " +
              "(`package:flutter/services.dart`) reads it, and a pub package's " +
              "assets and shaders whose `flavors:` name it are bundled. Empty, " +
              "the default, is no flavor: `appFlavor` is null and no `flavors:` " +
              "entry ships. A flavor is a target: declare one application per " +
              "flavor, and give each flavor's platform target its own app id, " +
              "name and resources. The app's own `assets` are not filtered by " +
              "flavor: list a flavor's assets in that flavor's target.",
    ),
} | VERSION_SETTING_ATTRS | EXTRA_DART_DEFINES_ATTR | BUILD_MODE_ATTR | KERNEL_TOOL_ATTR | PLUGIN_WARNINGS_TOOL_ATTR

# Shared attrs for all flutter application rules.
FLUTTER_APPLICATION_ATTRS = KERNEL_COMPILE_ATTRS | {
    "assets": attr.label_list(
        doc = "Asset files to include in the bundle, each under its path in this target's package. A file from another package fails the build.",
        allow_files = True,
    ),
    "native_deps": attr.label_list(
        doc = "cc_library targets providing shared libraries for dart:ffi. A web app built over the application bundles none of them, as `flutter build web` builds no native code.",
        aspects = [native_sources_aspect],
        # Built for the platform the build had before any web app's
        # transition: no C++ toolchain targets a web platform.
        cfg = runtime_reset,
    ),
    "extra_gen_snapshot_options": attr.string_list(
        doc = "Additional flags passed directly to gen_snapshot (AOT compiler). " +
              "A flag that makes gen_snapshot write a file (`--save-obfuscation-map`, " +
              "`--write-v8-snapshot-profile-to`, `--print-instructions-sizes-to`) names " +
              "it relative to the package; it is declared as an output of the target " +
              "(`<name>_gen_snapshot/<path>`) in the `gen_snapshot_files` output group. " +
              "`--resolve-dwarf-paths` is refused: the kernel names its sources by " +
              "workspace-relative URIs, which gen_snapshot cannot turn into paths, and " +
              "with `--@rules_dart//dart:split_debug_info` the debug info names them by those URIs instead.",
    ),
    "track_widget_creation": attr.bool(
        doc = "If True, a debug or profile build records where each widget was created, for the DevTools widget inspector, as `flutter run` does. A release build never does. Default `True`.",
        default = True,
    ),
    "shaders": attr.label_list(
        doc = "Fragment shader files (.frag) to compile with impellerc. Compiled shaders are included in the asset bundle.",
        allow_files = [".frag", ".glsl"],
    ),
    "shader_includes": attr.label_list(
        doc = "Files the `shaders` may `#include`. A shader compiles in a " +
              "sandbox holding only its declared inputs, so an include not " +
              "listed here is not found.",
        allow_files = True,
    ),
    "require_sksl_shaders": attr.bool(
        doc = "Fail the build when a shader cannot be compiled for Skia " +
              "(SkSL). By default such a shader is compiled for Impeller " +
              "alone with a warning, as `flutter build` does, and fails to " +
              "load only where the app renders with Skia. Set this for an " +
              "app that renders with Skia. Web builds always need SkSL.",
        default = False,
    ),
    "_shader_compile_tool": attr.label(
        default = Label("//flutter/private/tools:compile_shader.dart"),
        allow_single_file = True,
    ),
    "tree_shake_icons": attr.bool(
        doc = "If True, tree-shake icon fonts to only include used glyphs. " +
              "Requires all IconData instances to be const, and one font file in each icon font family; " +
              "otherwise the build fails, as `flutter build` does. Applies to profile and release builds; " +
              "a debug build keeps every glyph, as `flutter build` does.",
        default = True,
    ),
    "additional_licenses": attr.label_list(
        doc = "Licence files appended to `NOTICES.Z` as they are, after the packages' " +
              "licences: what `flutter: licenses:` lists in the program's `pubspec.yaml`.",
        allow_files = True,
    ),
    "minimum_os_version": attr.string(
        doc = "Minimum OS deployment target for Apple platforms (iOS/macOS). " +
              "Passed to gen_snapshot as --macho-min-os-version. " +
              "Platform-specific bundle rules set appropriate defaults.",
    ),
    "_asset_bundle_tool": attr.label(
        default = Label("//flutter/private/tools:generate_asset_manifest.dart"),
        allow_single_file = True,
    ),
    "_sky_engine": program_sky_engine_attr(),
} | NOTICES_ATTRS | DEV_TOOL_SUPPORT_ATTRS | GEN_SNAPSHOT_SETTINGS_ATTRS

# What a `flutter_application` states about its program: the attributes
# `flutter_program_inputs` reads, and so the ones a rule that rebuilds the
# program under another target (`flutter_application_variant`) takes from the
# application instead of declaring its own.
FLUTTER_PROGRAM_ATTR_NAMES = [
    "additional_licenses",
    "assets",
    "build_name",
    "build_number",
    "defines",
    "deps",
    "extra_gen_snapshot_options",
    "flavor",
    "main",
    "minimum_os_version",
    "native_deps",
    "package",
    "require_sksl_shaders",
    "shader_includes",
    "shaders",
    "srcs",
    "track_widget_creation",
    "tree_shake_icons",
]

# The rest of `FLUTTER_APPLICATION_ATTRS`: the tools and build settings every
# application target carries, which a rebuild under another target needs for
# itself. Every one is private: a public attribute here is one nobody decided
# the variant's behaviour for, so adding it to `FLUTTER_APPLICATION_ATTRS`
# without listing it above fails at load.
FLUTTER_APPLICATION_TOOL_ATTRS = {
    name: value
    for name, value in FLUTTER_APPLICATION_ATTRS.items()
    if name not in FLUTTER_PROGRAM_ATTR_NAMES
}

def _check_program_attrs():
    unclassified = [name for name in FLUTTER_APPLICATION_TOOL_ATTRS if not name.startswith("_")]
    unknown = [name for name in FLUTTER_PROGRAM_ATTR_NAMES if name not in FLUTTER_APPLICATION_ATTRS]
    if unclassified or unknown:
        fail(
            "common.bzl: FLUTTER_APPLICATION_ATTRS and FLUTTER_PROGRAM_ATTR_NAMES disagree: " +
            "%s are public attributes of the application not listed as program content, " % unclassified +
            "%s are listed as program content and are not attributes of it. " % unknown +
            "A flutter_application_variant takes the first from the application and would " +
            "silently ignore them.",
        )

_check_program_attrs()
