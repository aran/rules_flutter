"""Flutter web compilation actions (dart2wasm and dart2js).

Compiles Dart source to WASM or JavaScript for web deployment.
Both `dart compile wasm` and `dart compile js` take .dart source directly,
not a kernel .dill.
"""

load("//flutter/private:app_entrypoint.bzl", "stage_generated_inputs")
load("//flutter/private:common.bzl", "flutter_build_mode")

def web_renderer_defines(renderer):
    """The Dart renderer defines a web compile carries for `renderer`.

    Args:
        renderer: "skwasm" or "canvaskit".

    Returns:
        List of KEY=VALUE define strings (no -D prefix).
    """
    if renderer == "skwasm":
        return [
            "FLUTTER_WEB_USE_SKIA=false",
            "FLUTTER_WEB_USE_SKWASM=true",
        ]
    return [
        "FLUTTER_WEB_USE_SKIA=true",
        "FLUTTER_WEB_USE_SKWASM=false",
    ]

def web_build_mode(ctx):
    """The web build mode for the current Bazel compilation mode.

    The build-wide mode (`flutter_build_mode`), unless the `profile` attr
    asks for profile, which it does under any compilation mode. Web keeps a
    per-target attr where native builds do not because a web profile build
    needs no engine of its own: nothing outside this rule has to agree.

    Args:
        ctx: Rule context.

    Returns:
        "debug", "profile" or "release".
    """
    if ctx.attr.profile:
        return "profile"
    return flutter_build_mode(ctx)

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

def default_dart2wasm_optimization_level(mode, _compilation_mode = None):
    """The `-O` level a dart2wasm compile takes in a build mode.

    Upstream `WasmCompilerConfig.optimizationLevelForBuildMode`: 0 in debug, 2
    in profile and release. Release stops at 2 deliberately — upstream's
    comment records that their web benchmarks put the gap between 2 and 4 at
    marginal, and 2 is the highest level that uses only sound optimizations.
    The two compilers therefore disagree about their release level, which is
    why this is a per-compiler answer rather than one shared number.

    Args:
        mode: A `web_build_mode` value.
        _compilation_mode: Unused optional compilation mode (retained for call compatibility).

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

# The web compile request: the values every web compile carries, gathered once
# where the rule implementation stages them and passed down as one struct.
#
# `compile` is what the rule builds: the program being compiled plus the tools
# around it. `options` is the per-compiler tuning the rule reads from its own
# attrs (one shape per compiler family: `wasm_options` holds
# `optimization_level`, `minify` and `strip_wasm`; `js_options` holds
# `optimization_level`, `minify`, `native_null_assertions`,
# `frequency_based_minification`, `dump_info` and `source_maps`). `req` is the
# union the `flutter_dart2js_action`, `flutter_dart2js_cfe_action` and
# `flutter_dart2wasm_action` entry points take: every `compile` field plus
# `flutter_sdk_files`, the option fields and the outputs. Each action reads
# only its own subset; the fields it ignores are always present but never
# read, so every request has the same total shape whatever compiles it.
#
# `compile` fields:
#   dart: The `dart` executable File.
#   flutter_sdk_info: The Flutter SDK info struct (per-compiler file sets are
#       read from it: `dart2wasm_files` or `dart2js_files`).
#   dart2wasm_platform_dill, dart2js_platform_dill: The platform dill Files.
#   web_sdk_files: The dart2js web SDK `libraries*.json` Files.
#   main_dart: The main .dart source File (the wrapper entrypoint).
#   srcs: All transitive source Files.
#   package_config: The package_config.json File.
#   mode: A `web_build_mode` value.
#   defines: Dart -D defines (user defines; mode and renderer defines are
#       added by the actions to match each shipped program).
#   renderer: Web renderer ("skwasm" or "canvaskit").
#   stage_salt: Salt mixed into the staging directory hash.
#   web_compile_tool: Optional staging wrapper File, or None.
#   web_compile_inputs: Additional input Files the wrapper needs.
#   web_guard_tool: Optional `web_guard` executable File, or None.
#   enable_experiments: Dart language experiments to enable.

def web_sdk_files_for_dart2js(web_sdk):
    """Selects the `libraries*.json` files a dart2js compile resolves against.

    Prefers the exec-platform `libraries.<platform>.json` files and keeps the
    kernel-side `libraries.json`, dropping everything else the web SDK target
    carries.

    Args:
        web_sdk: The web SDK target (`ctx.attr._web_sdk`), or None.

    Returns:
        The list of `File`s `_web_libraries_spec` picks from.
    """
    files = web_sdk.files.to_list() if web_sdk else []
    return [
        f
        for f in files
        if f.path.endswith("/libraries.json") or (
            "/web-sdk/libraries." in f.path and f.path.endswith(".json")
        )
    ]

def web_compile_tool_inputs(dart_vm_files):
    """The `dartvm` executables a staging wrapper needs alongside `dart`.

    `web_template` is compiled against the Flutter toolchain and resolves
    `dartaotruntime` relative to the running `dart` executable's directory, so
    the compile actions carry the VM files and pass the executables on.

    Args:
        dart_vm_files: The `dart_vm_files` depset from the Flutter SDK info.

    Returns:
        The `dartvm`/`dartvm.exe` Files in it.
    """
    return [
        f
        for f in dart_vm_files.to_list()
        if f.basename in ("dartvm", "dartvm.exe")
    ]

def make_dart2wasm_request(compile, options, output_wasm, output_mjs, output_source_map):
    """Builds the dart2wasm compile request from the gathered values.

    Args:
        compile: The `compile` struct the rule implementation gathered.
        options: The `wasm_options` struct (`optimization_level`, `minify`,
            `strip_wasm`).
        output_wasm: Output .wasm File.
        output_mjs: Output .mjs File (JS support runtime).
        output_source_map: Output .wasm.map File, or None to disable source
            maps. Must sit at `<output_wasm>.map` (dart2wasm writes it there).

    Returns:
        The `req` struct `flutter_dart2wasm_action` takes.
    """
    if output_source_map != None and output_source_map.path != output_wasm.path + ".map":
        fail("output_source_map must be declared at <output_wasm>.map " +
             "(dart2wasm writes it there): got %s for %s" %
             (output_source_map.path, output_wasm.path))
    return struct(
        dart = compile.dart,
        flutter_sdk_files = compile.flutter_sdk_info.dart2wasm_files,
        dart2wasm_platform_dill = compile.dart2wasm_platform_dill,
        dart2js_platform_dill = None,
        web_sdk_files = [],
        main_dart = compile.main_dart,
        srcs = compile.srcs,
        package_config = compile.package_config,
        mode = compile.mode,
        optimization_level = options.optimization_level,
        minify = options.minify,
        strip_wasm = options.strip_wasm,
        native_null_assertions = True,
        frequency_based_minification = True,
        enable_experiments = compile.enable_experiments,
        dump_info = False,
        source_maps = False,
        defines = compile.defines,
        renderer = compile.renderer,
        output_wasm = output_wasm,
        output_mjs = output_mjs,
        output_source_map = output_source_map,
        output_dir = None,
        output_dill = None,
        output_deps = None,
        web_compile_tool = compile.web_compile_tool,
        web_compile_inputs = compile.web_compile_inputs,
        stage_salt = compile.stage_salt,
        web_guard_tool = compile.web_guard_tool,
    )

def make_dart2js_request(compile, options, renderer, output_dir):
    """Builds the dart2js compile request from the gathered values.

    Args:
        compile: The `compile` struct the rule implementation gathered.
        options: The `js_options` struct (`optimization_level`, `minify`,
            `native_null_assertions`, `frequency_based_minification`,
            `dump_info`, `source_maps`).
        renderer: Web renderer for the shipped program ("canvaskit", or the
            fallback's fixed `"canvaskit"` under a dart2wasm compile).
        output_dir: Output directory (declare_directory). dart2js writes
            main.dart.js and any *.part.js files here.

    Returns:
        The `req` struct `flutter_dart2js_action` takes.
    """
    return struct(
        dart = compile.dart,
        flutter_sdk_files = compile.flutter_sdk_info.dart2js_files,
        dart2wasm_platform_dill = None,
        dart2js_platform_dill = compile.dart2js_platform_dill,
        web_sdk_files = compile.web_sdk_files,
        main_dart = compile.main_dart,
        srcs = compile.srcs,
        package_config = compile.package_config,
        mode = compile.mode,
        optimization_level = options.optimization_level,
        minify = options.minify,
        strip_wasm = True,
        native_null_assertions = options.native_null_assertions,
        frequency_based_minification = options.frequency_based_minification,
        enable_experiments = compile.enable_experiments,
        dump_info = options.dump_info,
        source_maps = options.source_maps,
        defines = compile.defines,
        renderer = renderer,
        output_wasm = None,
        output_mjs = None,
        output_source_map = None,
        output_dir = output_dir,
        output_dill = None,
        output_deps = None,
        web_compile_tool = compile.web_compile_tool,
        web_compile_inputs = compile.web_compile_inputs,
        stage_salt = compile.stage_salt,
        web_guard_tool = compile.web_guard_tool,
    )

def make_dart2js_cfe_request(compile, renderer, stage_salt, output_dill, output_deps):
    """Builds the icon tree-shake kernel request from the gathered values.

    Runs with the frontend defaults (`-O` and minification on "auto", null
    assertions and frequency_based_minification on), matching what the shipped
    dart2js program resolves the platform-conditional imports against.

    Args:
        compile: The `compile` struct the rule implementation gathered.
        renderer: Web renderer for this kernel's defines ("canvaskit" or
            "skwasm").
        stage_salt: Salt mixed into the staging directory hash (the caller's
            renderer-specific salt, so each renderer's kernel stages apart).
        output_dill: Output kernel .dill File (`-o`). dart2js also writes
            `<dill>.deps` beside it, declared as `output_deps`.
        output_deps: Output depfile File (`<dill>.deps`).

    Returns:
        The `req` struct `flutter_dart2js_cfe_action` takes.
    """
    return struct(
        dart = compile.dart,
        flutter_sdk_files = compile.flutter_sdk_info.dart2js_files,
        dart2wasm_platform_dill = None,
        dart2js_platform_dill = compile.dart2js_platform_dill,
        web_sdk_files = compile.web_sdk_files,
        main_dart = compile.main_dart,
        srcs = compile.srcs,
        package_config = compile.package_config,
        mode = compile.mode,
        optimization_level = "auto",
        minify = "auto",
        strip_wasm = True,
        native_null_assertions = True,
        frequency_based_minification = True,
        enable_experiments = compile.enable_experiments,
        dump_info = False,
        source_maps = False,
        defines = compile.defines,
        renderer = renderer,
        output_wasm = None,
        output_mjs = None,
        output_source_map = None,
        output_dir = None,
        output_dill = output_dill,
        output_deps = output_deps,
        web_compile_tool = compile.web_compile_tool,
        web_compile_inputs = compile.web_compile_inputs,
        stage_salt = stage_salt,
        web_guard_tool = compile.web_guard_tool,
    )

def _sandbox_env(dart, writable_dir):
    """Build env dict that suppresses analytics and provides a writable HOME."""
    env = {"CI": "true", "FLUTTER_SUPPRESS_ANALYTICS": "true"}
    if dart.basename.endswith(".exe"):
        env["USERPROFILE"] = writable_dir
        env["LOCALAPPDATA"] = writable_dir
    else:
        env["HOME"] = writable_dir
    return env

def _write_web_guard_manifest(ctx, scope, compile_sources, stage):
    """Writes the declared-inputs manifest `web_guard` checks a compile against.

    The manifest lists the declared sources, then a `# staged` marker, then
    the staging root's symlinks to them — the same shape `kernel_filter`
    reads (see `flutter_compile.bzl`). Written by path so the tool reads the
    same files the compilers resolve through the staging root.

    Args:
        ctx: Rule context.
        scope: Action-unique prefix for the manifest file: mirror the stage
            tree's `<output-dir>.<output-base>` form, since a bare output
            basename (`main.dart.wasm`) repeats across every bundle in the
            package and collides.
        compile_sources: The declared main and source `File`s.
        stage: The `stage_generated_inputs` struct for the compile.

    Returns:
        The manifest `File`. The guard itself runs as a self-contained native
        executable (see `//flutter/private/tools:web_guard`), so the compile
        needs no Dart VM of its own: the guarded action's inputs grow only by
        the guard executable and this manifest.
    """
    manifest = ctx.actions.declare_file(scope + ".web_inputs")
    ctx.actions.write(
        output = manifest,
        content = "\n".join(
            [f.path for f in compile_sources if f != None] +
            ["# staged"] +
            [f.path for f in stage.files],
        ) + "\n",
    )
    return manifest

def _web_stage_inputs(ctx, web_compile_tool, sources, scope, stage_salt):
    """Stage generated sources for a web compile, or return an empty stage."""
    if web_compile_tool != None:
        return stage_generated_inputs(ctx, sources, scope, include_sources = True, salt = stage_salt)
    return struct(root = None, files = [])

def _web_base_args(ctx, web_compile_tool, stage, command):
    """Start a web compiler argv: optional wrapper, `compile <command>`, multi-root."""
    args = ctx.actions.args()
    if web_compile_tool != None:
        args.add(web_compile_tool)
    args.add("compile")
    args.add(command)
    if stage.root != None:
        args.add("--multi-root=" + stage.root)
    return args

def _web_libraries_spec(web_sdk_files, dart2js_platform_dill):
    """Pick the exec-platform `libraries.<platform>.json`, else `web-sdk/libraries.json`.

    Falls back to the kernel-side `libraries.json` one level above the
    platform dill when no web SDK file matches.
    """
    libraries_spec = dart2js_platform_dill.dirname + "/../libraries.json"
    for f in web_sdk_files:
        if f.basename.startswith("libraries.") and f.basename != "libraries.json" and f.basename.endswith(".json"):
            return f.path
        elif f.basename == "libraries.json" and "/web-sdk/" in f.path:
            libraries_spec = f.path
    return libraries_spec

def _web_guarded_run(ctx, args, req, run):
    """Run a web compile behind the optional `web_guard` wrapper.

    Args:
        ctx: Rule context.
        args: The `ctx.actions.args()` the compile runs with.
        req: The `req` struct (carries `dart` and `web_guard_tool`).
        run: The invocation struct (guard scope, sources, stage, inputs,
            outputs, mnemonic, progress message and sandbox directory).
    """
    executable = req.dart
    arguments = [args]
    if req.web_guard_tool != None:
        manifest = _write_web_guard_manifest(ctx, run.guard_scope, run.compile_sources, run.stage)
        executable = req.web_guard_tool
        arguments = ["--declared-inputs", manifest.path, "--", req.dart.path, args]
        direct_inputs = run.direct_inputs + [req.web_guard_tool, manifest]
    else:
        direct_inputs = run.direct_inputs
    ctx.actions.run(
        executable = executable,
        arguments = arguments,
        inputs = depset(
            direct = direct_inputs,
            transitive = run.transitive_inputs,
        ),
        outputs = run.outputs,
        mnemonic = run.mnemonic,
        progress_message = run.progress_message,
        env = _sandbox_env(req.dart, run.env_dir),
    )

def _dart2wasm_compiler_args(args, req):
    """Append the dart2wasm-only flags: platform, optimization, mode and renderer.

    Args:
        args: The `ctx.actions.args()` the compile runs with, mutated.
        req: The `req` struct `make_dart2wasm_request` built.
    """
    args.add("--extra-compiler-option=--platform=" + req.dart2wasm_platform_dill.path)
    args.add("--packages=" + req.package_config.path)
    args.add_all(web_experiment_flags(req.enable_experiments))
    args.add("-O%d" % resolve_web_optimization_level(
        req.optimization_level,
        default_dart2wasm_optimization_level(req.mode),
    ))
    args.add("--strip-wasm" if (req.mode == "release" and req.strip_wasm) else "--no-strip-wasm")
    args.add("--minify" if resolve_web_minify(req.minify, req.mode) else "--no-minify")
    if req.output_source_map == None:
        args.add("--no-source-maps")

    # SkWasm shared memory support.
    if req.renderer == "skwasm":
        args.add("--extra-compiler-option=--import-shared-memory")
        args.add("--extra-compiler-option=--shared-memory-max-pages=32768")

    # Mode defines and flags — matching `flutter build web` per build mode.
    for d in web_mode_defines(req.mode):
        args.add("-D" + d)
    if req.mode == "debug":
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
    for d in web_renderer_defines(req.renderer):
        args.add("-D" + d)

def flutter_dart2wasm_action(ctx, req):
    """Compiles Dart source to WebAssembly using dart2wasm.

    The outputs ride the request: `output_wasm` and `output_mjs` are always
    produced, `output_source_map` (at `<output_wasm>.map`) only when the rule
    asked for source maps. dart2wasm writes the map at `<output_wasm>.map`,
    so `make_dart2wasm_request` already refused a declaration anywhere else.

    Args:
        ctx: Rule context.
        req: The `req` struct `make_dart2wasm_request` built.
    """
    scope = req.output_wasm.dirname.split("/")[-1] + "." + req.output_wasm.basename
    stage = _web_stage_inputs(ctx, req.web_compile_tool, [req.main_dart] + req.srcs, scope, req.stage_salt)

    args = _web_base_args(ctx, req.web_compile_tool, stage, "wasm")
    _dart2wasm_compiler_args(args, req)
    for d in req.defines:
        args.add("-D" + d)

    args.add("-o", req.output_wasm)
    args.add(req.main_dart)

    direct_inputs = [req.main_dart, req.package_config, req.dart2wasm_platform_dill] + req.srcs + stage.files + req.web_compile_inputs
    if req.web_compile_tool != None:
        direct_inputs.append(req.web_compile_tool)
    _web_guarded_run(
        ctx,
        args,
        req,
        struct(
            guard_scope = scope,
            compile_sources = [req.main_dart] + req.srcs,
            stage = stage,
            direct_inputs = direct_inputs,
            transitive_inputs = [req.flutter_sdk_files],
            outputs = [req.output_wasm, req.output_mjs] + ([req.output_source_map] if req.output_source_map != None else []),
            mnemonic = "FlutterDart2Wasm",
            progress_message = "Compiling Flutter to WASM %s" % ctx.label,
            env_dir = req.output_wasm.dirname,
        ),
    )

def _dart2js_common_args(args, req):
    """Append the flags `dart2js` and its `--cfe-only` frontend share.

    Args:
        args: The `ctx.actions.args()` the compile runs with, mutated.
        req: The `req` struct `make_dart2js_request` (or
            `make_dart2js_cfe_request`) built.
    """
    args.add("--platform-binaries=" + req.dart2js_platform_dill.dirname)
    args.add("--libraries-spec=" + _web_libraries_spec(req.web_sdk_files, req.dart2js_platform_dill))
    args.add("--packages=" + req.package_config.path)
    args.add_all(web_experiment_flags(req.enable_experiments))
    args.add("-O%d" % resolve_web_optimization_level(
        req.optimization_level,
        default_dart2js_optimization_level(req.mode),
    ))
    if req.native_null_assertions:
        args.add("--native-null-assertions")
    args.add("--minify" if resolve_web_minify(req.minify, req.mode) else "--no-minify")
    if not req.frequency_based_minification:
        args.add("--no-frequency-based-minification")

def _dart2js_mode_args(args, mode):
    """Append the mode defines and debug asserts both dart2js entry points share."""
    for d in web_mode_defines(mode):
        args.add("-D" + d)
    if mode == "debug":
        args.add("--enable-asserts")

def flutter_dart2js_action(ctx, req):
    """Compiles Dart source to JavaScript using dart2js.

    Output is the request's `output_dir` tree artifact (directory) because
    dart2js may produce additional `*.part.js` files for deferred imports
    alongside main.dart.js. Apps without deferred imports get a single file
    in the directory. Source maps (`main.dart.js.map` and per-part maps) land
    in the same directory, so unlike dart2wasm they need no separate declared
    output.

    Args:
        ctx: Rule context.
        req: The `req` struct `make_dart2js_request` built.
    """
    scope = req.output_dir.basename + ".dart2js"
    stage = _web_stage_inputs(ctx, req.web_compile_tool, [req.main_dart] + req.srcs, scope, req.stage_salt)

    args = _web_base_args(ctx, req.web_compile_tool, stage, "js")

    # Prefer the exec-platform-specific libraries.<platform>.json from web_sdk_files
    # (falling back to web-sdk/libraries.json one level above kernel/).
    _dart2js_common_args(args, req)
    if req.dump_info:
        # Upstream passes this exact stage rather than the older bare
        # `--dump-info`, which now writes a *binary* `.info.data` instead —
        # so the flag whose name promises the JSON no longer produces it.
        args.add("--stage=dump-info-all")
    if not req.source_maps:
        args.add("--no-source-maps")

    # Mode defines and flags — matching `flutter build web` per build mode.
    _dart2js_mode_args(args, req.mode)
    if req.renderer == "canvaskit":
        args.add("-DFLUTTER_WEB_USE_SKIA=true")
        args.add("-DFLUTTER_WEB_USE_SKWASM=false")
    for d in req.defines:
        args.add("-D" + d)

    # Output into the directory — dart2js writes main.dart.js + *.part.js here.
    args.add("-o", req.output_dir.path + "/main.dart.js")
    args.add(req.main_dart)

    direct_inputs = [req.main_dart, req.package_config, req.dart2js_platform_dill] + req.srcs + stage.files + req.web_compile_inputs
    if req.web_compile_tool != None:
        direct_inputs.append(req.web_compile_tool)
    _web_guarded_run(
        ctx,
        args,
        req,
        struct(
            guard_scope = req.output_dir.dirname.split("/")[-1] + "." + req.output_dir.basename,
            compile_sources = [req.main_dart] + req.srcs,
            stage = stage,
            direct_inputs = direct_inputs,
            transitive_inputs = [req.flutter_sdk_files, depset(req.web_sdk_files)],
            outputs = [req.output_dir],
            mnemonic = "FlutterDart2JS",
            progress_message = "Compiling Flutter to JavaScript %s" % ctx.label,
            env_dir = req.output_dir.path,
        ),
    )

def flutter_dart2js_cfe_action(ctx, req):
    """Compiles Dart to a kernel dill with dart2js's frontend for icon tree-shaking.

    Runs `dart compile js --cfe-only`, the same frontend upstream runs to
    produce the `app.dill` const_finder reads on web builds. The kernel
    resolves platform-conditional imports (`if (dart.library.js_interop)`)
    to the web branch, as the shipped dart2js/dart2wasm programs do, and
    type-checks `dart:js_interop`/`dart:ui_web` against the real web
    libraries. One dill is compiled per shipped renderer (with that
    renderer's defines); const_finder unions the code points across them.

    Args:
        ctx: Rule context.
        req: The `req` struct `make_dart2js_cfe_request` built.
    """
    scope = req.output_dill.basename + ".dart2js_cfe"
    stage = _web_stage_inputs(ctx, req.web_compile_tool, [req.main_dart] + req.srcs, scope, req.stage_salt)

    args = _web_base_args(ctx, req.web_compile_tool, stage, "js")

    _dart2js_common_args(args, req)

    _dart2js_mode_args(args, req.mode)
    if req.renderer == "canvaskit":
        args.add("-DFLUTTER_WEB_USE_SKIA=true")
        args.add("-DFLUTTER_WEB_USE_SKWASM=false")
    elif req.renderer == "skwasm":
        args.add("-DFLUTTER_WEB_USE_SKIA=false")
        args.add("-DFLUTTER_WEB_USE_SKWASM=true")
    for d in req.defines:
        args.add("-D" + d)

    # Frontend-only: emit the kernel const_finder reads, not JavaScript.
    args.add("--cfe-only")
    args.add("-o", req.output_dill)
    args.add(req.main_dart)

    direct_inputs = [req.main_dart, req.package_config, req.dart2js_platform_dill] + req.srcs + stage.files + req.web_compile_inputs
    if req.web_compile_tool != None:
        direct_inputs.append(req.web_compile_tool)
    _web_guarded_run(
        ctx,
        args,
        req,
        struct(
            guard_scope = req.output_dill.dirname.split("/")[-1] + "." + req.output_dill.basename,
            compile_sources = [req.main_dart] + req.srcs,
            stage = stage,
            direct_inputs = direct_inputs,
            transitive_inputs = [req.flutter_sdk_files, depset(req.web_sdk_files)],
            outputs = [req.output_dill, req.output_deps],
            mnemonic = "FlutterDart2JSCFE",
            progress_message = "Compiling Flutter web icon kernel %s" % ctx.label,
            env_dir = req.output_dill.dirname,
        ),
    )
