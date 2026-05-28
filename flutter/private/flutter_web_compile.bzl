"""Flutter web compilation actions (dart2wasm and dart2js).

Compiles Dart source to WASM or JavaScript for web deployment.
Both `dart compile wasm` and `dart compile js` take .dart source directly,
not a kernel .dill.
"""

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
        strip = True,
        optimization_level = 2,
        source_maps = False,
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
        strip: Whether to strip the WASM output.
        optimization_level: Optimization level (0-4).
        source_maps: Whether to generate source maps.
        defines: Dart -D defines.
        renderer: Web renderer ("skwasm" or "canvaskit").
    """
    args = ctx.actions.args()
    args.add("compile")
    args.add("wasm")

    # Platform dill.
    args.add("--extra-compiler-option=--platform=" + dart2wasm_platform_dill.path)

    # Package config.
    args.add("--packages=" + package_config.path)

    # Optimization.
    if optimization_level > 0:
        args.add("-O%d" % optimization_level)
    if strip:
        args.add("--strip-wasm")
    if not source_maps:
        args.add("--no-source-maps")

    # SkWasm shared memory support.
    if renderer == "skwasm":
        args.add("--extra-compiler-option=--import-shared-memory")
        args.add("--extra-compiler-option=--shared-memory-max-pages=32768")

    # Defines — must match flutter build web exactly.
    args.add("-Ddart.vm.product=true")
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
        outputs = [output_wasm, output_mjs],
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
        optimization_level = 2,
        source_maps = False,
        defines = [],
        renderer = "canvaskit"):
    """Compiles Dart source to JavaScript using dart2js.

    Output is a tree artifact (directory) because dart2js may produce
    additional `*.part.js` files for deferred imports alongside main.dart.js.
    Apps without deferred imports get a single file in the directory.

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
        optimization_level: Optimization level (0-4).
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

    if optimization_level > 0:
        args.add("-O%d" % optimization_level)
    if not source_maps:
        args.add("--no-source-maps")

    # Defines — must match flutter build web exactly.
    args.add("-Ddart.vm.product=true")
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
