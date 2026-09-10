"""Flutter web compilation actions (dart2wasm and dart2js).

Compiles Dart source to WASM or JavaScript for web deployment.
Both `dart compile wasm` and `dart compile js` take .dart source directly,
not a kernel .dill.
"""

def web_build_mode(ctx):
    """The web build mode for the current Bazel compilation mode.

    Mirrors the native path (`flutter_application`): the `profile` attr
    overrides the compilation-mode mapping in either direction, and without it
    `-c dbg` is a debug build and everything else is release.

    Args:
        ctx: Rule context.

    Returns:
        "debug", "profile" or "release".
    """
    if ctx.attr.profile:
        return "profile"
    return "debug" if ctx.var["COMPILATION_MODE"] == "dbg" else "release"

def web_mode_defines(mode):
    """The Dart mode defines a web compile carries for a build mode.

    Matches upstream's `Dart2WasmTarget`/`Dart2JSTarget.buildModeOptions`:
    release carries `dart.vm.product=true`, profile carries
    `dart.vm.profile=true`, and debug carries neither (`kReleaseMode` and
    `kProfileMode` are `bool.fromEnvironment` reads that default to false —
    the native kernel path also appends nothing in dbg).

    Upstream additionally emits the *false* halves explicitly
    (`-Ddart.vm.product=false` in debug and profile). Those are no-ops for the
    same `bool.fromEnvironment` reason, and emitting them here would only make
    the two compilers' argv disagree with the native path for no behavioural
    difference. Upstream emits them conditionally so a user `--dart-define` can
    override the mode; here `dart.vm.profile` and `dart.vm.product` are
    reserved define keys (see `RESERVED_DART_DEFINE_KEYS`), so there is no user
    value to defer to and the condition would never fire.

    Args:
        mode: A `web_build_mode` value.

    Returns:
        List of KEY=VALUE define strings (no -D prefix).
    """
    if mode == "release":
        return ["dart.vm.product=true"]
    if mode == "profile":
        return ["dart.vm.profile=true"]
    if mode == "debug":
        return []
    fail("unknown web build mode: %s" % mode)

def resolve_web_minify(minify, mode):
    """Resolve a tristate `minify_*` attr against the build mode.

    Both web compilers take `--minify`/`--no-minify`, and upstream states one
    of them on every invocation rather than letting the compiler infer it from
    `-O` (`minify ?? buildMode == BuildMode.release` in both
    `JsCompilerConfig` and `WasmCompilerConfig`). Stating it is what keeps the
    setting independent of the optimization level, which is a separate attr
    here and a separate flag upstream.

    Args:
        minify: The attr value: "auto", "true" or "false".
        mode: A `web_build_mode` value.

    Returns:
        True if the compile should minify.
    """
    if minify == "auto":
        return mode == "release"
    if minify == "true":
        return True
    if minify == "false":
        return False
    fail("unknown minify value: %s" % minify)

def default_dart2js_optimization_level(mode):
    """The `-O` level a dart2js compile takes in a build mode.

    Upstream `JsCompilerConfig.optimizationLevelForBuildMode`: 1 in debug, 4
    in profile and release. Debug is 1 rather than 0 because, in upstream's
    own words, dart2js level 0 "is not well supported".

    Both compilers state `-O` on every invocation rather than leaving it off
    and taking whatever the CLI defaults to — `dart compile js` and
    `dart compile wasm` both default to `-O1`, so an unstated level is not a
    neutral one, and 0 could not be expressed at all.

    Args:
        mode: A `web_build_mode` value.

    Returns:
        The optimization level as an int.
    """
    if mode == "debug":
        return 1
    if mode == "profile" or mode == "release":
        return 4
    fail("unknown web build mode: %s" % mode)

def default_dart2wasm_optimization_level(mode):
    """The `-O` level a dart2wasm compile takes in a build mode.

    Upstream `WasmCompilerConfig.optimizationLevelForBuildMode`: 0 in debug, 2
    in profile and release. Release stops at 2 deliberately — upstream's
    comment records that their web benchmarks put the gap between 2 and 4 at
    marginal, and 2 is the highest level that uses only sound optimizations.
    The two compilers therefore disagree about their release level, which is
    why this is a per-compiler answer rather than one shared number.

    Args:
        mode: A `web_build_mode` value.

    Returns:
        The optimization level as an int.
    """
    if mode == "debug":
        return 0
    if mode == "profile" or mode == "release":
        return 2
    fail("unknown web build mode: %s" % mode)

def resolve_web_optimization_level(level, mode_default):
    """Resolve a tristate `optimization_level_*` attr against its mode default.

    Same shape as `resolve_web_minify`: "auto" defers to the build mode, and
    an explicit level holds across every mode. Kept as a string attr for
    exactly that reason — an int attr has no value that means "whatever this
    mode calls for", and picking one out of 0-4 to mean it would make that
    level unaskable.

    Args:
        level: The attr value: "auto", or a level as a decimal string.
        mode_default: The level for this mode, from
            `default_dart2js_optimization_level` or
            `default_dart2wasm_optimization_level`.

    Returns:
        The optimization level as an int.
    """
    if level == "auto":
        return mode_default
    return int(level)

def web_experiment_flags(enable_experiments):
    """The `--enable-experiment` flags for a list of experiment names.

    Both `dart compile js` and `dart compile wasm` take these bare, and so
    does the frontend_server the icon tree-shake kernel goes through — the
    same shape upstream produces by folding `--enable-experiment=<name>` into
    `extraFrontEndOptions`, which every web compile splices in unwrapped.

    Args:
        enable_experiments: Experiment names, without the flag.

    Returns:
        List of `--enable-experiment=<name>` strings.
    """
    return ["--enable-experiment=" + e for e in enable_experiments]

def _sandbox_env(dart, writable_dir):
    """Build env dict that suppresses analytics and provides a writable HOME."""
    env = {"CI": "true", "FLUTTER_SUPPRESS_ANALYTICS": "true"}
    if dart.basename.endswith(".exe"):
        env["USERPROFILE"] = writable_dir
        env["LOCALAPPDATA"] = writable_dir
    else:
        env["HOME"] = writable_dir
    return env

def flutter_dart2wasm_action(
        ctx,
        dart,
        flutter_sdk_files,
        web_sdk_files,
        dart2wasm_platform_dill,
        main_dart,
        srcs,
        package_config,
        output_wasm,
        output_mjs,
        mode,
        output_source_map = None,
        strip_wasm = True,
        optimization_level = "auto",
        minify = "auto",
        enable_experiments = [],
        defines = [],
        renderer = "skwasm"):
    """Compiles Dart source to WebAssembly using dart2wasm.

    Args:
        ctx: Rule context.
        dart: The `dart` executable File.
        flutter_sdk_files: SDK files needed to run dart.
        web_sdk_files: Flutter web SDK files.
        dart2wasm_platform_dill: The dart2wasm_platform.dill File.
        main_dart: The main .dart source File.
        srcs: All transitive source Files needed for compilation.
        package_config: The package_config.json File.
        output_wasm: Output .wasm File.
        output_mjs: Output .mjs File (JS support runtime).
        mode: A `web_build_mode` value; selects the mode defines and, in
            debug, enables asserts (upstream `WasmCompilerConfig` does the
            same for debug builds).
        output_source_map: Output .wasm.map File, or None to disable source
            maps. dart2wasm writes the map at `<output_wasm>.map`, so the
            declared File must sit exactly there.
        strip_wasm: Whether a *release* build strips static symbol names from
            the WASM output. Debug and profile builds never strip, matching
            upstream's `buildMode == BuildMode.release && stripWasm` — the
            names are what those two modes exist to show.
        optimization_level: Tristate `-O` level, resolved by
            `resolve_web_optimization_level` against the mode default.
        minify: Tristate name minification, resolved by `resolve_web_minify`.
        enable_experiments: Dart language experiments to enable.
        defines: Dart -D defines.
        renderer: Web renderer ("skwasm" or "canvaskit").
    """
    if output_source_map != None and output_source_map.path != output_wasm.path + ".map":
        fail("output_source_map must be declared at <output_wasm>.map " +
             "(dart2wasm writes it there): got %s for %s" %
             (output_source_map.path, output_wasm.path))

    args = ctx.actions.args()
    args.add("compile")
    args.add("wasm")

    # Platform dill.
    args.add("--extra-compiler-option=--platform=" + dart2wasm_platform_dill.path)

    # Package config.
    args.add("--packages=" + package_config.path)

    args.add_all(web_experiment_flags(enable_experiments))

    # Optimization.
    args.add("-O%d" % resolve_web_optimization_level(
        optimization_level,
        default_dart2wasm_optimization_level(mode),
    ))
    args.add("--strip-wasm" if (mode == "release" and strip_wasm) else "--no-strip-wasm")
    args.add("--minify" if resolve_web_minify(minify, mode) else "--no-minify")
    if output_source_map == None:
        args.add("--no-source-maps")

    # SkWasm shared memory support.
    if renderer == "skwasm":
        args.add("--extra-compiler-option=--import-shared-memory")
        args.add("--extra-compiler-option=--shared-memory-max-pages=32768")

    # Mode defines and flags — matching `flutter build web` per build mode.
    for d in web_mode_defines(mode):
        args.add("-D" + d)
    if mode == "debug":
        args.add("--extra-compiler-option=--enable-asserts")
    else:
        # Upstream `Dart2WasmTarget.buildModeOptions` drops `toString()` bodies
        # in every non-debug mode. It is a size optimization that also changes
        # observable behaviour — `'$widget'` stops naming the type — so it must
        # track the mode rather than be inferred from `-O`, and profile has to
        # carry it or a profile build stops representing the release it is
        # meant to measure.
        for uri in ("dart:ui", "package:flutter"):
            args.add("--extra-compiler-option=--delete-tostring-package-uri=" + uri)
    if renderer == "skwasm":
        args.add("-DFLUTTER_WEB_USE_SKIA=false")
        args.add("-DFLUTTER_WEB_USE_SKWASM=true")
    else:
        args.add("-DFLUTTER_WEB_USE_SKIA=true")
        args.add("-DFLUTTER_WEB_USE_SKWASM=false")
    for d in defines:
        args.add("-D" + d)

    args.add("-o", output_wasm)
    args.add(main_dart)

    ctx.actions.run(
        executable = dart,
        arguments = [args],
        inputs = depset(
            direct = [main_dart, package_config, dart2wasm_platform_dill] + srcs,
            transitive = [flutter_sdk_files, depset(web_sdk_files)],
        ),
        outputs = [output_wasm, output_mjs] + ([output_source_map] if output_source_map != None else []),
        mnemonic = "FlutterDart2Wasm",
        progress_message = "Compiling Flutter to WASM %s" % ctx.label,
        env = _sandbox_env(dart, output_wasm.dirname),
    )

def flutter_dart2js_action(
        ctx,
        dart,
        flutter_sdk_files,
        web_sdk_files,
        dart2js_platform_dill,
        main_dart,
        srcs,
        package_config,
        output_dir,
        mode,
        optimization_level = "auto",
        minify = "auto",
        native_null_assertions = True,
        frequency_based_minification = True,
        enable_experiments = [],
        dump_info = False,
        source_maps = False,
        defines = [],
        renderer = "canvaskit"):
    """Compiles Dart source to JavaScript using dart2js.

    Output is a tree artifact (directory) because dart2js may produce
    additional `*.part.js` files for deferred imports alongside main.dart.js.
    Apps without deferred imports get a single file in the directory. Source
    maps (`main.dart.js.map` and per-part maps) land in the same directory,
    so unlike dart2wasm they need no separate declared output.

    Args:
        ctx: Rule context.
        dart: The `dart` executable File.
        flutter_sdk_files: SDK files needed to run dart.
        web_sdk_files: Flutter web SDK files.
        dart2js_platform_dill: The dart2js_platform.dill File.
        main_dart: The main .dart source File.
        srcs: All transitive source Files needed for compilation.
        package_config: The package_config.json File.
        output_dir: Output directory (declare_directory). dart2js writes
            main.dart.js and any *.part.js files here.
        mode: A `web_build_mode` value; selects the mode defines and, in
            debug, enables asserts (upstream `JsCompilerConfig` does the
            same for debug builds).
        optimization_level: Tristate `-O` level, resolved by
            `resolve_web_optimization_level` against the mode default.
        minify: Tristate name minification, resolved by `resolve_web_minify`.
        native_null_assertions: Whether to check at runtime that values coming
            back from JS interop and the web libraries match their declared
            nullability.
        frequency_based_minification: Whether the minifier may pick short
            names by how often an identifier occurs. False makes the naming
            depend only on the program, so two builds can be diffed.
        enable_experiments: Dart language experiments to enable.
        dump_info: Whether to write `<output>.info.json` describing what ended
            up in the output and why.
        source_maps: Whether to generate source maps.
        defines: Dart -D defines.
        renderer: Web renderer ("canvaskit" or "skwasm").
    """
    args = ctx.actions.args()
    args.add("compile")
    args.add("js")

    # libraries.json is one level above the kernel/ directory containing the dill.
    # The web SDK's libraries.json includes the Dart SDK's via a relative path.
    args.add("--libraries-spec=" + dart2js_platform_dill.dirname + "/../libraries.json")

    # Package config.
    args.add("--packages=" + package_config.path)

    args.add_all(web_experiment_flags(enable_experiments))

    args.add("-O%d" % resolve_web_optimization_level(
        optimization_level,
        default_dart2js_optimization_level(mode),
    ))
    if native_null_assertions:
        args.add("--native-null-assertions")
    args.add("--minify" if resolve_web_minify(minify, mode) else "--no-minify")
    if not frequency_based_minification:
        args.add("--no-frequency-based-minification")
    if dump_info:
        # Upstream passes this exact stage rather than the older bare
        # `--dump-info`, which now writes a *binary* `.info.data` instead —
        # so the flag whose name promises the JSON no longer produces it.
        args.add("--stage=dump-info-all")
    if not source_maps:
        args.add("--no-source-maps")

    # Mode defines and flags — matching `flutter build web` per build mode.
    for d in web_mode_defines(mode):
        args.add("-D" + d)
    if mode == "debug":
        args.add("--enable-asserts")
    if renderer == "canvaskit":
        args.add("-DFLUTTER_WEB_USE_SKIA=true")
        args.add("-DFLUTTER_WEB_USE_SKWASM=false")
    for d in defines:
        args.add("-D" + d)

    # Output into the directory — dart2js writes main.dart.js + *.part.js here.
    args.add("-o", output_dir.path + "/main.dart.js")
    args.add(main_dart)

    ctx.actions.run(
        executable = dart,
        arguments = [args],
        inputs = depset(
            direct = [main_dart, package_config, dart2js_platform_dill] + srcs,
            transitive = [flutter_sdk_files, depset(web_sdk_files)],
        ),
        outputs = [output_dir],
        mnemonic = "FlutterDart2JS",
        progress_message = "Compiling Flutter to JavaScript %s" % ctx.label,
        env = _sandbox_env(dart, output_dir.path),
    )
