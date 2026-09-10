"""Flutter web application build.

Produces a deployable web directory containing:
- main.dart.wasm + main.dart.mjs + main.dart.js (WASM mode with JS fallback)
  or main.dart.js (JS-only mode)
- flutter.js (Flutter engine bootstrapper from web SDK)
- canvaskit/ or skwasm/ (renderer engine artifacts)
- flutter_assets/ (AssetManifest.bin.json for web)
- index.html
- flutter_bootstrap.js
- flutter_service_worker.js (optional; tears down a previously installed
  caching service worker — see flutter/private/web_service_worker.bzl)

When compiler="dart2wasm", both WASM and JS outputs are produced. The
bootstrap JS lists both builds so the Flutter engine tries WASM first and
falls back to JS on browsers without WASM support (matching `flutter build web`).

Both dart2wasm and dart2js take .dart source directly (not kernel .dill),
so we skip the frontend_server kernel compilation step used by desktop/mobile.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "collect_packages", "collect_transitive_srcs", "dart_analyzable_info_with_package", "derive_lib_root", "generate_dev_package_config")
load("//flutter:providers.bzl", "FlutterInfo")
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_main_package_uri",
    "compile_package_config",
    "package_lib_prefix",
    "resolve_wrapper_main_import",
    "synthesize_app_package",
)
load(
    "//flutter/private:common.bzl",
    "AGENT_EXTENSIONS_ATTR",
    "FLUTTER_APPLICATION_ATTRS",
    "KERNEL_COMPILE_ATTRS",
    "declare_flutter_assets_dir",
    "flutter_build_assets",
    "flutter_compile_shaders",
    "make_web_wrapper_main_content",
    "merge_dart_defines",
)
load("//flutter/private:flutter_compile.bzl", "flutter_kernel_compile_action")
load("//flutter/private:flutter_info.bzl", "dedup_plugins")
load(
    "//flutter/private:flutter_web_compile.bzl",
    "flutter_dart2js_action",
    "flutter_dart2wasm_action",
    "web_build_mode",
    "web_experiment_flags",
    "web_mode_defines",
)
load("//flutter/private:plugin_registrant.bzl", "generate_dart_plugin_registrant")
load(
    "//flutter/private:validation.bzl",
    "escape_html",
    "validate_base_href",
    "validate_static_assets_url",
    "validate_web_compiler_renderer",
    "validate_web_wasm_only_attrs",
)
load(
    "//flutter/private:web_service_worker.bzl",
    "SERVICE_WORKER_JS",
    "SERVICE_WORKER_VERSION",
    "service_worker_load_args",
)

# The index.html the rule falls back to when the target supplies none.
#
# Carries `$FLUTTER_BASE_HREF` rather than a formatted value so it reaches the
# templating action as the same kind of input a user's `web/index.html` is:
# one substitution path, exercised by every build.
_INDEX_HTML_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
  <base href="$FLUTTER_BASE_HREF">
  <meta charset="UTF-8">
  <meta content="IE=Edge" http-equiv="X-UA-Compatible">
  <meta name="description" content="A Flutter web application built with Bazel">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black">
  <meta name="apple-mobile-web-app-title" content="{title}">
  <link rel="icon" type="image/png" href="favicon.png">
  <link rel="manifest" href="manifest.json">
  <title>{title}</title>
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
"""

# The flutter_bootstrap.js the rule falls back to when the target supplies none.
#
# `{{flutter_build_config}}` and `{{flutter_service_worker_version}}` are the
# same built-ins a user-supplied `web/flutter_bootstrap.js` may reference, so
# the default template goes through the templating action too rather than
# around it. `%s` is the load argument, which is empty when no worker ships.
_BOOTSTRAP_JS_TEMPLATE = """\
{{flutter_build_config}}
{
  let script = document.createElement("script");
  script.src = "flutter.js";
  script.addEventListener("load", function() {
    _flutter.loader.load(%s);
  });
  document.head.appendChild(script);
}
"""

def _build_config_js(engine_revision, builds, use_local_canvaskit):
    """The `{{flutter_build_config}}` built-in, in upstream's exact shape.

    Emitted as JSON assigned to `_flutter.buildConfig` — the same text
    `WebTemplatedFiles.buildConfigString` produces — so a user who copies
    upstream's `flutter_bootstrap.js` into `web/` gets a working bundle.

    Args:
        engine_revision: The engine the app was compiled against.
        builds: Build descriptions, most preferred first.
        use_local_canvaskit: Whether to load the renderer from the app's server.

    Returns:
        A JavaScript snippet.
    """
    config = {"engineRevision": engine_revision, "builds": builds}
    if use_local_canvaskit:
        config["useLocalCanvasKit"] = True
    return """if (!window._flutter) {
  window._flutter = {};
}
_flutter.buildConfig = %s;
""" % json.encode(config)

def _wasm_build(renderer):
    return {
        "compileTarget": "dart2wasm",
        "renderer": renderer,
        "mainWasmPath": "main.dart.wasm",
        "jsSupportRuntimePath": "main.dart.mjs",
    }

_JS_BUILD = {
    "compileTarget": "dart2js",
    "renderer": "canvaskit",
    "mainJsPath": "main.dart.js",
}

# What `flutter_bazel run -d chrome` actually serves, whatever the bundle is.
#
# The dev loop compiles with DDC and serves `main.dart.js` as its own loader
# script, so the page's build config describes that and not the target's
# dart2wasm/dart2js output. `canvaskit` because the DDC loop has no skwasm
# build to boot. Upstream's dev server pins the same three values
# (`isolated/web_asset_server.dart`, `_buildConfigString`).
_DDC_BUILD = {
    "compileTarget": "dartdevc",
    "renderer": "canvaskit",
    "mainJsPath": "main.dart.js",
}

_MANIFEST_JSON_TEMPLATE = """\
{{
    "name": "{name}",
    "short_name": "{short_name}",
    "start_url": ".",
    "display": "standalone",
    "background_color": "#0175C2",
    "theme_color": "#0175C2",
    "description": "A Flutter web application.",
    "orientation": "portrait-primary",
    "prefer_related_applications": false
}}
"""

# `flutter build web` writes version.json to the bundle root. The web
# `package_info_plus` plugin (and any future PackageInfo-style web plugins)
# fetches it to populate `appName`, `version`, `buildNumber`, and
# `packageName`. Without it, those fields come back empty even when the
# plugin registrant fired correctly.
_VERSION_JSON_TEMPLATE = """\
{{
    "app_name": "{app_name}",
    "version": "{version}",
    "build_number": "{build_number}",
    "package_name": "{package_name}"
}}
"""

# Bundle destinations the rule generates itself, and what a user who wants to
# supply their own should do instead.
#
# Every one of these is appended to `copies` before `web_assets`, and
# `bundle_app.dart` copies in list order with no duplicate detection — so
# without this table a `web/` file that happens to share a name silently
# replaces a generated one. The failures that produced are all far from their
# cause: a `web/flutter_bootstrap.js` full of unsubstituted placeholders is a
# blank page, and a stale `web/canvaskit/canvaskit.wasm` is a renderer that
# does not match the engine it was built against.
_RESERVED_DST_REMEDY = {
    "index.html": "pass it to `index_html` instead (Tier 1 discovers `web/index.html` for you).",
    "manifest.json": "pass it to `manifest_json` instead (Tier 1 discovers `web/manifest.json` for you).",
    "version.json": "pass it to `version_json` instead (Tier 1 discovers `web/version.json` for you).",
    "flutter_bootstrap.js": "pass your template to `bootstrap_js` instead (Tier 1 discovers " +
                            "`web/flutter_bootstrap.js` for you), so it goes through the same " +
                            "substitution pass and picks up this target's build config.",
    "flutter.js": "this is the engine loader, taken from the Flutter web SDK so that it " +
                  "matches the engine the app was compiled against. It cannot be replaced.",
    "flutter_service_worker.js": "set `pwa = False` to stop the rule shipping its own worker, " +
                                 "and yours will be the only one at this name.",
}

# Directory destinations the rule fills, checked as prefixes.
_RESERVED_DST_PREFIX_REMEDY = {
    "assets/": "declare Flutter assets through the `assets` attr, which routes them " +
               "through the asset bundler and into AssetManifest.bin.json.",
    "canvaskit/": "the renderer artifacts come from the Flutter web SDK and must match " +
                  "the engine revision the app was compiled against. They cannot be replaced.",
}

def _reserve(reserved, copies, src, dst):
    """Append a rule-generated copy and reserve its destination.

    Args:
        reserved: Destination-to-source dict, mutated.
        copies: The bundler's copy list, mutated.
        src: Source path.
        dst: Bundle-relative destination.
    """
    reserved[dst] = src
    copies.append({"src": src, "dst": dst})

def _check_web_asset_dst(ctx, reserved, dst, short_path):
    """Fail when a `web_assets` entry lands on a destination the rule generates.

    The dart2js output is a tree artifact copied over the bundle root *after*
    `copies`, so its contents cannot be reserved from the copy list. Its
    entrypoint is always `main.dart.js` and is named explicitly by the caller;
    the deferred `*.part.js` files it may also produce depend on the app's
    imports and are unknown until the action runs, so a web asset colliding
    with one of those is still lost silently.

    Args:
        ctx: Rule context, for the label in the message.
        reserved: Destinations the rule generates *for this target* — the
            conditional ones (the service worker) are absent when the target
            does not generate them, which is what lets a user supply their own.
        dst: The destination this web asset would take.
        short_path: The asset's workspace-relative path, for the message.
    """

    # Most specific first: a named destination has its own way out, a
    # directory has one shared by everything under it, and what is left is a
    # compile output, which nothing can stand in for.
    #
    # The named lookup is gated on this target actually generating the
    # destination. `flutter_service_worker.js` is the conditional one: with
    # `pwa = False` the rule ships no worker, and refusing the user's would
    # answer a request the rule already granted.
    remedy = _RESERVED_DST_REMEDY.get(dst) if dst in reserved else None
    if not remedy:
        for prefix, prefix_remedy in _RESERVED_DST_PREFIX_REMEDY.items():
            if dst.startswith(prefix):
                remedy = prefix_remedy
                break
    if not remedy and dst in reserved:
        remedy = "it is produced by the compile step; a web asset cannot stand in for it."
    if remedy:
        fail(
            "%s: web asset %r would be bundled as %r, which this rule already " % (ctx.label, short_path, dst) +
            "generates. Bundling both writes one over the other with no error, " +
            "so this is refused instead: " + remedy,
        )

def _flutter_web_bundle_impl(ctx):
    validate_web_compiler_renderer(ctx.attr.compiler, ctx.attr.renderer)
    validate_web_wasm_only_attrs(
        ctx.attr.compiler,
        [
            n
            for n, set_away in [
                ("minify_wasm", ctx.attr.minify_wasm != "auto"),
                ("optimization_level_wasm", ctx.attr.optimization_level_wasm != "auto"),
                ("strip_wasm", not ctx.attr.strip_wasm),
            ]
            if set_away
        ],
        ctx.label,
    )
    validate_base_href(ctx.attr.base_href, ctx.label)
    validate_static_assets_url(ctx.attr.static_assets_url, ctx.label)

    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    # Merged once for all compile actions below (dart2wasm, dart2js, icon
    # tree-shake kernel) and the dev-config emission.
    user_defines = merge_dart_defines(ctx)

    # The build mode drives the mode defines of every compile action below,
    # the same way the native kernel path switches on COMPILATION_MODE.
    mode = web_build_mode(ctx)
    is_debug = mode == "debug"

    # Step 1: Collect sources, generate package config, handle plugin registrant.
    # dart compile wasm/js take .dart source directly (not kernel .dill).
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list()
    packages = collect_packages(ctx.attr.deps)

    # The app's own library root — the single answer to "what is
    # `package:<self>/…` rooted at" for this target. Everything downstream
    # that asks the question (package synthesis, the wrapper's import, the
    # dev-config entrypoint, the analyzer's source split) takes it from here
    # rather than deriving its own, which is how the compile path and the
    # analysis path came to disagree: analysis derived it, compilation
    # assumed `""`, and a nested app's `package:` URIs silently resolved
    # against the workspace root instead of its own package.
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # Register the app's own package (when declared) so `package:<name>/main.dart`
    # is a valid URI for the wrapper to import. Include `main` in the colocate
    # inputs so it ends up inside the same assembled directory as its lib/
    # siblings — that's what lets `main.dart`'s relative imports resolve to
    # the assembled (codegen-co-located) copies of its package siblings.
    packages = synthesize_app_package(ctx.label, packages, ctx.attr.package_name, lib_root, ctx.attr.language_version)

    # Hot-reload dev metadata (debug only): a multi-root dev package_config so a
    # source-assembled (codegen) app resolves package: URIs across the live
    # source tree + generated bazel-out roots, instead of the frozen assembled
    # `.pkgsrcs` dir the build config uses. Computed pre-colocation (lib_root +
    # File.is_source intact). See rules_dart generate_dev_package_config.
    dev_package_config = None
    dev_filesystem_roots = []
    dev_filesystem_scheme = ""
    dev_generated_source_paths = []
    dev_generated_source_uris = []
    dev_source_packages = []
    if is_debug:
        dev_package_config = ctx.actions.declare_file(ctx.label.name + ".dev_package_config.json")
        dev_pc = generate_dev_package_config(packages, all_srcs + [ctx.file.main], dev_package_config)
        ctx.actions.write(dev_package_config, dev_pc.content)
        dev_filesystem_roots = dev_pc.filesystem_roots
        dev_filesystem_scheme = dev_pc.scheme
        dev_generated_source_paths = dev_pc.generated_source_paths
        dev_generated_source_uris = dev_pc.generated_source_uris
        dev_source_packages = dev_pc.source_packages

    pc = compile_package_config(ctx, packages, all_srcs + [ctx.file.main])
    config_file = pc.config_file
    all_srcs = pc.srcs

    # Generate web wrapper main with ui_web.bootstrapEngine().
    # Flutter web ALWAYS needs this wrapper to properly initialize the engine
    # (create the implicit view, set up the platform dispatcher, etc.)
    # before calling the user's main(). This matches `flutter build web`.
    all_dep_plugins = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
    plugins = dedup_plugins(all_dep_plugins)
    registrant = generate_dart_plugin_registrant(ctx, plugins, target_platform = "web")

    wrapper = ctx.actions.declare_file(ctx.label.name + "_wrapper_main.dart")
    wrapper_depth = len(wrapper.dirname.split("/"))

    # Import the user's main via its `package:` URI when available. That URI
    # resolves through `package_config.json` to the colocated package's
    # `rootUri`, so the user's `main.dart` is read from the assembled
    # directory and its relative imports find their colocated siblings.
    wrapper_content = make_web_wrapper_main_content(
        resolve_wrapper_main_import(
            ctx.attr.package_name,
            lib_root,
            ctx.file.main.short_path,
            ctx.file.main.path,
            wrapper_depth,
        ),
        registrant.basename if registrant else None,
    )
    ctx.actions.write(wrapper, wrapper_content)
    entrypoint = wrapper
    extra_wrapper_srcs = [ctx.file.main, wrapper]
    if registrant:
        extra_wrapper_srcs.append(registrant)
    all_srcs = all_srcs + extra_wrapper_srcs

    # Step 2: Compile to WASM (with JS fallback) or JS only.
    # dart2js outputs to a tree artifact (directory) to support deferred loading:
    # dart2js may produce main.dart.js + *.part.js files for deferred imports.
    web_sdk_file_list = ctx.attr._web_sdk.files.to_list() if ctx.attr._web_sdk else []
    compile_outputs = []  # Files (wasm, mjs, wasm.map)
    compile_copies = []  # Bundle copy entries for compile_outputs
    dart2js_dirs = []  # Tree artifacts from dart2js

    # flutter.js does the registering: it waits for the new worker to activate
    # (with a timeout) before booting the app, and — given only a version — it
    # registers nothing unless the visitor already has a worker to replace.
    load_args = service_worker_load_args(ctx.attr.pwa)
    if ctx.attr.compiler == "dart2wasm":
        # Primary: dart2wasm. Outputs are declared under a subdirectory with
        # their canonical bundle names: dart2wasm embeds a sourceMappingURL
        # referencing `<output>.map` by name, so the compiled name and the
        # shipped name must be the same for the browser to find the map.
        output_wasm = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm")
        output_mjs = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.mjs")
        output_wasm_map = None
        if ctx.attr.source_maps:
            output_wasm_map = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm.map")
        flutter_dart2wasm_action(
            ctx = ctx,
            dart = flutter_sdk_info.dart,
            flutter_sdk_files = flutter_sdk_info.tool_files,
            web_sdk_files = web_sdk_file_list,
            dart2wasm_platform_dill = ctx.file._dart2wasm_platform_dill,
            main_dart = entrypoint,
            srcs = all_srcs,
            package_config = config_file,
            output_wasm = output_wasm,
            output_mjs = output_mjs,
            mode = mode,
            output_source_map = output_wasm_map,
            optimization_level = ctx.attr.optimization_level_wasm,
            strip_wasm = ctx.attr.strip_wasm,
            minify = ctx.attr.minify_wasm,
            enable_experiments = ctx.attr.enable_experiments,
            defines = user_defines,
            renderer = ctx.attr.renderer,
        )

        # Fallback: dart2js (always canvaskit renderer) — tree artifact for deferred loading
        output_js_fallback_dir = ctx.actions.declare_directory(ctx.label.name + "_dart2js_fallback")
        flutter_dart2js_action(
            ctx = ctx,
            dart = flutter_sdk_info.dart,
            flutter_sdk_files = flutter_sdk_info.tool_files,
            web_sdk_files = web_sdk_file_list,
            dart2js_platform_dill = ctx.file._dart2js_platform_dill,
            main_dart = entrypoint,
            srcs = all_srcs,
            package_config = config_file,
            output_dir = output_js_fallback_dir,
            mode = mode,
            optimization_level = ctx.attr.optimization_level_js,
            minify = ctx.attr.minify_js,
            native_null_assertions = ctx.attr.native_null_assertions,
            frequency_based_minification = ctx.attr.frequency_based_minification,
            enable_experiments = ctx.attr.enable_experiments,
            dump_info = ctx.attr.dump_info,
            source_maps = ctx.attr.source_maps,
            defines = user_defines,
            renderer = "canvaskit",
        )
        compile_outputs = [output_wasm, output_mjs]
        compile_copies = [
            {"src": output_wasm.path, "dst": "main.dart.wasm"},
            {"src": output_mjs.path, "dst": "main.dart.mjs"},
        ]
        if output_wasm_map != None:
            compile_outputs.append(output_wasm_map)
            compile_copies.append({"src": output_wasm_map.path, "dst": "main.dart.wasm.map"})
        dart2js_dirs = [output_js_fallback_dir]
        builds = [_wasm_build(ctx.attr.renderer), _JS_BUILD]
    else:
        # JS-only mode — tree artifact for deferred loading
        output_js_dir = ctx.actions.declare_directory(ctx.label.name + "_dart2js")
        flutter_dart2js_action(
            ctx = ctx,
            dart = flutter_sdk_info.dart,
            flutter_sdk_files = flutter_sdk_info.tool_files,
            web_sdk_files = web_sdk_file_list,
            dart2js_platform_dill = ctx.file._dart2js_platform_dill,
            main_dart = entrypoint,
            srcs = all_srcs,
            package_config = config_file,
            output_dir = output_js_dir,
            mode = mode,
            optimization_level = ctx.attr.optimization_level_js,
            minify = ctx.attr.minify_js,
            native_null_assertions = ctx.attr.native_null_assertions,
            frequency_based_minification = ctx.attr.frequency_based_minification,
            enable_experiments = ctx.attr.enable_experiments,
            dump_info = ctx.attr.dump_info,
            source_maps = ctx.attr.source_maps,
            defines = user_defines,
            renderer = ctx.attr.renderer,
        )
        dart2js_dirs = [output_js_dir]
        builds = [_JS_BUILD]

    # Step 3: Shader compilation + asset bundle.
    compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, "web")

    # Icon tree shaking: compile a kernel .dill for const_finder analysis.
    # Web targets don't otherwise need a kernel (they use dart2wasm/dart2js),
    # so we compile one specifically for const_finder to analyze IconData constants.
    kernel_dill = None
    if (ctx.attr.tree_shake_icons and not is_debug and
        flutter_sdk_info.const_finder != None and flutter_sdk_info.font_subset != None):
        kernel_dill = ctx.actions.declare_file(ctx.label.name + "_icon_tree_shaking.dill")

        # When the app is a Dart package, key the entrypoint by its `package:`
        # URI so the compile reads `main.dart` from the colocated package and
        # its relative imports resolve to the assembled siblings (handwritten
        # + generated). Without this, `main.dart` is read from its source-tree
        # exec path and reaches the source-tree copies of its siblings, which
        # miss any `dart_codegen`-produced `.g.dart` in `bazel-out`.
        flutter_kernel_compile_action(
            ctx = ctx,
            dartaotruntime = flutter_sdk_info.dartaotruntime,
            flutter_sdk_files = flutter_sdk_info.tool_files,
            frontend_server = flutter_sdk_info.frontend_server,
            platform_dill = flutter_sdk_info.platform_kernel_dill_product,
            main = ctx.file.main,
            entrypoint_uri = app_main_package_uri(
                ctx.attr.package_name,
                lib_root,
                ctx.file.main.short_path,
            ),
            srcs = all_srcs,
            package_config = config_file,
            output = kernel_dill,
            aot = True,
            # Mode-derived rather than hardcoded: this branch is reachable in
            # both non-debug modes, and a profile build that shook its icons
            # against `dart.vm.product=true` would be shaking a different
            # program than the one it goes on to compile.
            defines = list(user_defines) + web_mode_defines(mode),
            # The experiments have to reach this compile too: they change how
            # the source *parses*, so a release build of experiment-using code
            # would die here — in an icon-shaking step the user never asked
            # for — while both real compilers accepted it.
            extra_flags = web_experiment_flags(ctx.attr.enable_experiments),
        )

    flutter_assets = declare_flutter_assets_dir(ctx)
    flutter_build_assets(ctx, flutter_sdk_info, flutter_assets, compiled_shaders, kernel_dill = kernel_dill, is_debug = is_debug)

    # Step 4: Pick the index.html and flutter_bootstrap.js *templates*.
    #
    # Both go through the same substitution pass below whether they came from
    # the user or from here, so a `flutter create` index.html works untouched
    # and the built-in default cannot drift from what a user template gets.
    if ctx.file.index_html:
        index_template = ctx.file.index_html
    else:
        title = ctx.attr.title or ctx.label.name

        # Escaped here rather than in the tool: the title is a Starlark attr,
        # and the tool has no business knowing which of its inputs is HTML.
        index_template = ctx.actions.declare_file(ctx.label.name + "_index_template.html")
        ctx.actions.write(index_template, _INDEX_HTML_TEMPLATE.format(
            title = escape_html(title),
        ))

    if ctx.file.bootstrap_js:
        bootstrap_template = ctx.file.bootstrap_js
    else:
        bootstrap_template = ctx.actions.declare_file(ctx.label.name + "_bootstrap_template.js")
        ctx.actions.write(bootstrap_template, _BOOTSTRAP_JS_TEMPLATE % load_args)

    # Use user-provided manifest.json or generate from template.
    if ctx.file.manifest_json:
        manifest_json = ctx.file.manifest_json
    else:
        title = ctx.attr.title or ctx.label.name
        safe_title = escape_html(title)
        manifest_json = ctx.actions.declare_file(ctx.label.name + "_manifest.json")
        ctx.actions.write(manifest_json, _MANIFEST_JSON_TEMPLATE.format(
            name = safe_title,
            short_name = safe_title,
        ))

    # Use user-provided version.json or generate from attrs.
    if ctx.file.version_json:
        version_json = ctx.file.version_json
    else:
        app_name = ctx.attr.package_name or ctx.label.name
        version_json = ctx.actions.declare_file(ctx.label.name + "_version.json")
        ctx.actions.write(version_json, _VERSION_JSON_TEMPLATE.format(
            app_name = app_name,
            version = ctx.attr.app_version or "1.0.0",
            build_number = ctx.attr.app_build_number or "1",
            package_name = app_name,
        ))

    # Step 5: Generate service worker (if enabled).
    #
    # The worker is a fixed string — it caches nothing, so it has nothing to
    # key on the bundle's contents. It exists to unregister the caching worker
    # a visitor may be carrying from an older deploy.
    service_worker_file = None
    if ctx.attr.pwa:
        service_worker_file = ctx.actions.declare_file(ctx.label.name + "_flutter_service_worker.js")
        ctx.actions.write(service_worker_file, SERVICE_WORKER_JS)

    # Step 6: Collect web engine artifacts from the web SDK.
    # flutter.js is the engine bootstrapper loaded by flutter_bootstrap.js.
    # Renderer WASM/JS files are under web-sdk/canvaskit/.
    web_sdk_files = ctx.attr._web_sdk.files.to_list() if ctx.attr._web_sdk else []
    flutter_js_file = None
    renderer_files = []
    for f in web_sdk_files:
        # flutter.js is at web-sdk/flutter_js/flutter.js
        if f.path.endswith("/flutter_js/flutter.js"):
            flutter_js_file = f

        # Renderer files are under web-sdk/canvaskit/.
        # Both canvaskit and skwasm WASM/JS files live in the canvaskit/ directory.
        if "/web-sdk/canvaskit/" in f.path:
            renderer_files.append(f)

    # Step 6b: Substitute both templates in one action.
    #
    # The bootstrap goes first so index.html can inline the *substituted*
    # bootstrap through `{{flutter_bootstrap_js}}` — the same ordering
    # `WebTemplatedFiles.build` uses upstream.
    index_html = ctx.actions.declare_file(ctx.label.name + "_index.html")
    bootstrap_js = ctx.actions.declare_file(ctx.label.name + "_flutter_bootstrap.js")

    # The bootstrap the dev loop serves, from the same template as the bundle's.
    #
    # `flutter_bazel run -d chrome` serves this target's index.html as built but
    # compiles the app with DDC, so the page cannot boot the bundle's bootstrap:
    # that one names this target's dart2wasm/dart2js output. Upstream has the
    # same split and resolves it the same way — `WebAssetServer` substitutes
    # `web/flutter_bootstrap.js` with the dev server's own build config
    # (`isolated/web_asset_server.dart`) rather than generating a bootstrap that
    # ignores the template.
    #
    # Emitted by the build rather than assembled by the dev tool because the
    # template, the `{{...}}` values and the substitution rules all live here.
    # A dev tool generating its own bootstrap silently dropped both the user's
    # template and every `web_defines` entry that referenced it.
    dev_bootstrap_js = None
    if is_debug:
        dev_bootstrap_js = ctx.actions.declare_file(ctx.label.name + "_dev_flutter_bootstrap.js")

    build_config = _build_config_js(
        flutter_sdk_info.engine_revision,
        builds,
        ctx.attr.use_local_canvaskit,
    )

    # Always supplied, in both states: a user bootstrap copied from upstream
    # references the name unconditionally, and `null` is what upstream
    # substitutes when no worker ships.
    worker_version = "\"%s\"" % SERVICE_WORKER_VERSION if ctx.attr.pwa else "null"
    shared_builtins = {
        "flutter_build_config": {"value": build_config},
        "flutter_service_worker_version": {"value": worker_version},
    }
    template_inputs = [index_template, bootstrap_template]
    if flutter_js_file:
        shared_builtins["flutter_js"] = {"file": flutter_js_file.path}
        template_inputs.append(flutter_js_file)

    index_builtins = dict(shared_builtins)
    index_builtins["flutter_bootstrap_js"] = {"from_output": 0}

    # The dev loop's build config names DDC's output, not this target's. It is
    # fixed rather than derived from the target's compiler/renderer attrs
    # because the dev loop always compiles with DDC and always serves the
    # renderer from the bundle it is serving — the attrs describe the bundle,
    # which a `-d chrome` run does not run.
    dev_builtins = dict(shared_builtins)
    dev_builtins["flutter_build_config"] = {"value": _build_config_js(
        flutter_sdk_info.engine_revision,
        [_DDC_BUILD],
        use_local_canvaskit = True,
    )}

    # No service worker in a dev run, matching upstream's run mode. A template
    # that registers one would install it against `localhost` and outlive the
    # run, serving a stale bundle to the next one.
    dev_builtins["flutter_service_worker_version"] = {"value": "null"}

    template_config = {
        "web_defines": ctx.attr.web_defines,
        "keep_placeholders": ctx.attr.keep_placeholders,
        "files": [
            {
                "template": bootstrap_template.path,
                "output": bootstrap_js.path,
                "label": "flutter_bootstrap.js",
                # Upstream substitutes an empty base href into the bootstrap:
                # the page's `<base>` already governs, and a bootstrap that
                # repeated it would resolve URLs against it twice.
                "base_href": "",
                "static_assets_url": None,
                "dev_loop_guard": False,
                "manages_service_worker": ctx.attr.pwa,
                "check_constructs": True,
                "builtins": shared_builtins,
            },
            {
                "template": index_template.path,
                "output": index_html.path,
                "label": "index.html",
                "base_href": ctx.attr.base_href,
                "static_assets_url": ctx.attr.static_assets_url,
                # In debug the dev tool serves this index.html but generates
                # its own flutter_bootstrap.js, so an index that inlines the
                # boot path would run the built bundle and hot reload would do
                # nothing. Refused there, allowed in a release build.
                "dev_loop_guard": is_debug,
                # With pwa = False the rule ships and registers nothing, so a
                # page registering its own worker is the supported way to have
                # one and must not be refused.
                "manages_service_worker": ctx.attr.pwa,
                "check_constructs": True,
                "builtins": index_builtins,
            },
        ] + ([
            {
                "template": bootstrap_template.path,
                "output": dev_bootstrap_js.path,
                "label": "flutter_bootstrap.js (dev loop)",
                "base_href": "",
                "static_assets_url": None,
                "dev_loop_guard": False,
                "manages_service_worker": ctx.attr.pwa,
                # The same bytes the entry above already read: reporting a
                # deprecated construct in them twice names one mistake as two.
                "check_constructs": False,
                "builtins": dev_builtins,
            },
        ] if dev_bootstrap_js else []),
    }
    template_config_file = ctx.actions.declare_file(ctx.label.name + "_web_template_config.json")
    ctx.actions.write(template_config_file, json.encode(template_config))

    ctx.actions.run(
        executable = flutter_sdk_info.dart,
        arguments = [
            ctx.file._web_template_tool.path,
            "--config",
            template_config_file.path,
        ],
        inputs = depset(
            direct = template_inputs + [template_config_file, ctx.file._web_template_tool],
            transitive = [flutter_sdk_info.tool_files],
        ),
        outputs = [index_html, bootstrap_js] + ([dev_bootstrap_js] if dev_bootstrap_js else []),
        mnemonic = "FlutterWebTemplate",
        progress_message = "Substituting web templates for %s" % ctx.label,
    )

    # Step 7: Assemble into output directory using the Dart bundler tool.
    output_dir = ctx.actions.declare_directory(ctx.label.name + "_web")

    # Build bundle config: each compile output has an explicit destination
    # entry (built where the outputs were declared), never a derived name.
    copies = []
    reserved = {}
    for copy in compile_copies:
        _reserve(reserved, copies, copy["src"], copy["dst"])

    # The dart2js entrypoint reaches the bundle root inside a tree artifact, so
    # it is not in `copies` to reserve — but it is produced in both compiler
    # modes (as the primary output, or as the WASM build's fallback), so it can
    # be named. Reserved without a copy entry.
    reserved["main.dart.js"] = "<dart2js output>"

    _reserve(reserved, copies, index_html.path, "index.html")
    _reserve(reserved, copies, bootstrap_js.path, "flutter_bootstrap.js")
    _reserve(reserved, copies, manifest_json.path, "manifest.json")
    _reserve(reserved, copies, version_json.path, "version.json")

    if service_worker_file:
        _reserve(reserved, copies, service_worker_file.path, "flutter_service_worker.js")

    # Copy flutter.js from the web SDK.
    engine_inputs = []
    if flutter_js_file:
        _reserve(reserved, copies, flutter_js_file.path, "flutter.js")
        engine_inputs.append(flutter_js_file)

    # Copy renderer engine files (canvaskit/*.wasm, *.js, etc.).
    for f in renderer_files:
        idx = f.path.find("/web-sdk/canvaskit/")
        if idx >= 0:
            rel = "canvaskit/" + f.path[idx + len("/web-sdk/canvaskit/"):]
            _reserve(reserved, copies, f.path, rel)
            engine_inputs.append(f)

    # Copy user-provided web assets (favicon.png, icons/, etc.) to output root.
    # Strip the leading "web/" prefix if present (matching `flutter build web` behavior).
    web_asset_files = []
    for f in ctx.files.web_assets:
        rel = f.short_path

        # Strip package prefix to get workspace-relative path.
        if rel.startswith(ctx.label.package + "/"):
            rel = rel[len(ctx.label.package) + 1:]

        # Strip leading "web/" directory (convention: files live in web/).
        if rel.startswith("web/"):
            rel = rel[4:]
        _check_web_asset_dst(ctx, reserved, rel, f.short_path)
        copies.append({"src": f.path, "dst": rel})
        web_asset_files.append(f)

    # dart2js outputs are directories (tree artifacts) to support deferred
    # loading — dart2js may produce main.dart.js + *.part.js files.
    # Copy entire directory contents into the output root.
    copy_dirs = [{"src": flutter_assets.path, "dst": "assets"}]
    for d in dart2js_dirs:
        copy_dirs.append({
            "src": d.path,
            "dst": ".",
            # dart2js writes its dependency list beside the output. It is
            # build bookkeeping, not part of the app, and naming it here is
            # what keeps the bundler from having to know which of its callers
            # is the web one. Naming it in the build, rather than filtering by
            # extension in the tool, is what lets an asset legitimately called
            # `*.deps` survive.
            #
            # `dump_info` lands its JSON in the same tree. It describes the
            # whole program and runs to megabytes, and nothing at runtime
            # reads it, so it is lifted out below rather than deployed —
            # which is where this deliberately parts company with
            # `flutter build web`, whose build directory is also its output.
            "exclude": ["*.deps", "*.info.json"],
        })

    # The dump-info JSON, lifted out of the dart2js tree to a name of its own.
    # dart2js writes it at `<-o path>.info.json` with no way to redirect it,
    # and Bazel cannot declare a File inside a declared directory — so the
    # bundler, which already has the tree as an input, extracts it.
    extracts = []
    dump_info_file = None
    if ctx.attr.dump_info:
        dump_info_file = ctx.actions.declare_file(ctx.label.name + "_dart2js_info.json")
        extracts.append({
            "src": dart2js_dirs[0].path + "/main.dart.js.info.json",
            "dst": dump_info_file.path,
        })

    config = {
        "output_dir": output_dir.path,
        "copies": copies,
        "copy_dirs": copy_dirs,
        "extracts": extracts,
    }

    bundle_config_file = ctx.actions.declare_file(ctx.label.name + "_web_bundle_config.json")
    ctx.actions.write(bundle_config_file, json.encode(config))

    all_inputs = compile_outputs + dart2js_dirs + engine_inputs + web_asset_files + [flutter_assets, index_html, bootstrap_js, manifest_json, version_json, bundle_config_file]
    if service_worker_file:
        all_inputs.append(service_worker_file)

    ctx.actions.run(
        executable = flutter_sdk_info.dart,
        arguments = [
            ctx.file._bundle_tool.path,
            "--config",
            bundle_config_file.path,
        ],
        inputs = depset(
            direct = all_inputs + [ctx.file._bundle_tool],
            transitive = [flutter_sdk_info.tool_files],
        ),
        outputs = [output_dir] + ([dump_info_file] if dump_info_file else []),
        mnemonic = "FlutterWebBundle",
        progress_message = "Bundling Flutter web app %s" % ctx.label,
    )

    # The dump-info JSON is an analysis artifact, not something a deployment
    # needs, so it rides an output group rather than the default outputs:
    # `bazel build //your:app --output_groups=dump_info`. Empty when the attr
    # is off, so the group always exists and always says the truth.
    output_groups = OutputGroupInfo(
        dump_info = depset([dump_info_file] if dump_info_file else []),
    )

    # What makes `dart_analyze_test(target = ":some_web_app")` possible. Until
    # this existed the rule handed out no Dart provider at all, so every web
    # example had to declare its sources a second time as a `flutter_library`
    # purely for the analyzer to stage — and anything the bundle reached that
    # the shadow library missed was analyzed by nothing. `dart_web_application`
    # upstream already provides the equivalent; this closes the asymmetry.
    #
    # Deliberately not offered as a `DartInfo`: `deps` requires one, and an
    # application bundle is not a dependency.
    #
    # `dart_analyzable_info_with_package`, not `dart_analyzable_info`: this rule
    # declares a mandatory `package_name` and its `srcs` are that package's
    # `lib/` files, which import each other by `package:<self>/…`. The
    # package-less closure the other constructor nests gives the analyzer no
    # record to resolve those against and reports every one `uri_does_not_exist`.
    #
    # The source split is decided by path, not by attr. A `flutter_test`'s
    # `main` is always a `test/` entrypoint outside any `lib/`, so it is always
    # package-less; a web app's is usually `lib/main.dart` — inside the package,
    # reachable as `package:<self>/main.dart` — and sometimes not, as when it
    # sits at the package root beside `web/`. Which one holds is decidable from
    # the file's own path, so neither case has to be assumed.
    main_in_package = ctx.file.main.short_path.startswith(package_lib_prefix(lib_root))

    # `_sky_engine` joins the analyzer's closure and nothing else. The web
    # compilers get `dart:ui` from the web SDK; the analyzer resolves it only by
    # following the package_config to `package:sky_engine`'s `lib/_embedder.yaml`,
    # so analysis genuinely needs an entry compilation does not.
    analyzable_info = dart_analyzable_info_with_package(
        label = ctx.label,
        package_name = ctx.attr.package_name,
        lib_root = lib_root,
        deps = ctx.attr.deps + [ctx.attr._sky_engine],
        srcs = [] if main_in_package else [ctx.file.main],
        package_srcs = ctx.files.srcs + ([ctx.file.main] if main_in_package else []),
        # As on the compile path above: the analyzer and the compiler have to
        # agree on the version, or the attr closes the divergence in only one.
        language_version = ctx.attr.language_version,
    )

    # In debug mode, output DDC dev files alongside the web directory.
    # The dev tool discovers these in the build output list (same pattern as native).
    if is_debug:
        ddc_files = []

        # DDC outline dill (--platform flag for frontend_server).
        ddc_outline_dill = ctx.actions.declare_file(ctx.label.name + "_ddc_outline.dill")
        ctx.actions.symlink(output = ddc_outline_dill, target_file = ctx.file._ddc_outline_dill)
        ddc_files.append(ddc_outline_dill)

        # DDC libraries spec (--libraries-spec flag).
        ddc_libraries_json = ctx.actions.declare_file(ctx.label.name + "_ddc_libraries.json")
        ctx.actions.symlink(output = ddc_libraries_json, target_file = ctx.file._ddc_libraries_spec)
        ddc_files.append(ddc_libraries_json)

        # DDC-compiled Dart SDK JS.
        ddc_dart_sdk_js = ctx.actions.declare_file(ctx.label.name + "_ddc_dart_sdk.js")
        ctx.actions.symlink(output = ddc_dart_sdk_js, target_file = ctx.file._ddc_dart_sdk_js)
        ddc_files.append(ddc_dart_sdk_js)

        # DDC module loader JS.
        ddc_module_loader_js = ctx.actions.declare_file(ctx.label.name + "_ddc_module_loader.js")
        ctx.actions.symlink(output = ddc_module_loader_js, target_file = ctx.file._ddc_module_loader_js)
        ddc_files.append(ddc_module_loader_js)

        # DDC stack trace mapper JS.
        ddc_stack_trace_mapper_js = ctx.actions.declare_file(ctx.label.name + "_ddc_stack_trace_mapper.js")
        ctx.actions.symlink(output = ddc_stack_trace_mapper_js, target_file = ctx.file._ddc_stack_trace_mapper_js)
        ddc_files.append(ddc_stack_trace_mapper_js)

        # AI-agent service extensions, staged for the dev tool to import from
        # its synthetic entrypoint (see the `agentExtensions` dev-config key).
        #
        # Staged only here, in the DDC branch, rather than compiled into the
        # bundle the way the native rules compile it into their kernel. The
        # bundle is built by dart2wasm/dart2js, where `dart:developer`'s
        # `registerExtension` is a no-op stub — and the runs that serve the
        # bundle (`--wasm`, release) have no VM service to register against
        # either. Only the DDC dev loop can carry these.
        staged_agent = ctx.actions.declare_file(ctx.label.name + ".agent_extensions.dart")
        ctx.actions.symlink(output = staged_agent, target_file = ctx.file._agent_extensions_src)
        ddc_files.append(staged_agent)

        # The dev loop's bootstrap, declared a top-level debug output so it is
        # materialized locally for the dev server to read and serve.
        ddc_files.append(dev_bootstrap_js)

        # Dev config JSON with engine revision, version, and host tool paths.
        # The dart-sdk root is derived from the module loader path:
        # .../dart-sdk/lib/dev_compiler/ddc/ddc_module_loader.js → .../dart-sdk
        dart_sdk_root = ctx.file._ddc_module_loader_js.path.rsplit("/lib/", 1)[0]

        # The synthetic-main entrypoint the dev tool imports, as a `package:`
        # URI backed by the record `synthesize_app_package` wrote above —
        # `app_main_package_uri`, not arithmetic of its own. The arithmetic it
        # replaces got both branches wrong: it stripped `ctx.label.package +
        # "/lib/"`, which is `"/lib/"` for a workspace-rooted app and so never
        # matched, and its `else` then *fabricated* `package:<name>/main.dart`
        # for any main it could not place. That fallback was right only when
        # the entrypoint happened to be the workspace root's `lib/main.dart`;
        # for anything else it named a library belonging to another app, and
        # the dev loop booted that program instead with nothing reporting a
        # mismatch.
        #
        # A `main` outside the package's own `lib/` has no `package:` URI, so
        # the run stops here rather than inventing one. The bundle path can
        # still express that shape (the wrapper falls back to a relative
        # import), but the dev loop's synthetic entrypoint is compiled under
        # `org-dartlang-app:` from a staging directory and can only reach the
        # app by package URI.
        app_entrypoint = app_main_package_uri(
            ctx.attr.package_name,
            lib_root,
            ctx.file.main.short_path,
        )
        if not app_entrypoint:
            fail(
                ("%s: `main` is `%s`, which is outside this package's `%s`, " +
                 "so it has no `package:` URI for the dev loop's synthetic " +
                 "entrypoint to import. Move `main` under `%s` (a debug web " +
                 "build is a `flutter_bazel run` build), or build this " +
                 "target in a non-debug configuration.") % (
                    ctx.label,
                    ctx.file.main.short_path,
                    package_lib_prefix(lib_root),
                    package_lib_prefix(lib_root),
                ),
            )

        dev_config_content = json.encode({
            "engineRevision": flutter_sdk_info.engine_revision,
            "flutterVersion": flutter_sdk_info.version,
            "dartSdkRoot": dart_sdk_root,
            "dartaotruntime": flutter_sdk_info.dartaotruntime.path,
            "frontendServer": flutter_sdk_info.frontend_server.path,
            "patchedSdkRoot": flutter_sdk_info.platform_kernel_dill.path.rsplit("/", 1)[0],
            "appEntrypoint": app_entrypoint,
            # The generated web plugin registrant (`registerPlugins()`). The
            # bundled build reaches it through the wrapper main's relative
            # import; DDC dev mode builds its own synthetic entrypoint, so the
            # dev tool needs the path named explicitly — it stages the file
            # beside that entrypoint and imports it the same way. Empty when
            # the app has no web plugins.
            "webPluginRegistrant": registrant.path if registrant else "",
            # The staged AI-agent service extensions. Same staging contract as
            # `webPluginRegistrant`: the build names the file, the dev tool
            # copies it beside its synthetic entrypoint and imports it. Always
            # present in this branch — a dbg web run is a dev-loop run.
            "agentExtensions": staged_agent.path,
            # The bootstrap the dev server answers `/flutter_bootstrap.js`
            # with: this target's template, substituted with the DDC build
            # config the dev loop runs under. Named here rather than found by
            # suffix because it is one file per target, and a run that served
            # another target's would boot the wrong app.
            "flutterBootstrapJs": dev_bootstrap_js.path,
            # Merged user defines (attr + extra_dart_defines flag). The dev
            # tool replays these as -D on its resident frontend_server so
            # hot reload/restart recompiles keep the same environment.
            "dartDefines": user_defines,
            # Whether the DDC dev loop asserts native nullability, so a run of
            # this app checks what its built bundle checks. The dev loop
            # applies it through the SDK options in its generated bootstrap
            # rather than as a compiler flag, which is why it travels as a
            # value here instead of joining `dartDefines`.
            "nativeNullAssertions": ctx.attr.native_null_assertions,
            # The dev loop's frontend_server parses the same source these
            # experiments change, so without them a `flutter_bazel run` of an
            # experiment-using app fails to parse code its bundle compiles
            # cleanly. The dev tool's side of this is #58-#67.
            "enableExperiments": ctx.attr.enable_experiments,
            # Codegen hot-reload: dev package_config + multi-root layout +
            # generated source paths/URIs (empty for non-codegen apps).
            "devPackageConfig": dev_package_config.path if dev_package_config else "",
            # The BUILD package_config, for the one consumer that needs file
            # paths rather than live sources: DWDS, which reads a `package:`
            # URI's source off disk to show it in the debugger.
            #
            # Named separately from `devPackageConfig` because the two are not
            # interchangeable and only the call site knows which it wants. A
            # source-assembled package's dev `rootUri` is
            # `<filesystemScheme>:///<lib_root>`, which the frontend_server
            # resolves through `--filesystem-root` but `Uri.toFilePath()`
            # cannot: DWDS asked through it gets "Cannot extract a file path
            # from a org-dartlang-app URI" and shows no source at all. This
            # one's rootUris are ordinary relative paths, so they resolve.
            "buildPackageConfig": config_file.path,
            "filesystemRoots": dev_filesystem_roots,
            "filesystemScheme": dev_filesystem_scheme,
            "generatedSourcePaths": dev_generated_source_paths,
            "generatedSourceUris": dev_generated_source_uris,
            # First-party source packages (app + local deps) the dev tool maps
            # live edits back to via its PackageUriResolver. libRoot is
            # workspace-relative.
            "sourcePackages": [
                {"name": sp[0], "libRoot": sp[1]}
                for sp in dev_source_packages
            ],
        })
        dev_config = ctx.actions.declare_file(ctx.label.name + "_dev_config.json")
        ctx.actions.write(dev_config, dev_config_content)
        ddc_files.append(dev_config)
        if dev_package_config:
            ddc_files.append(dev_package_config)

        # Include package_config in debug outputs.
        ddc_files.append(config_file)

        # The web plugin registrant is otherwise only an input to the
        # dart2wasm/dart2js compile actions; declaring it a top-level debug
        # output guarantees it is materialized locally for the dev tool to
        # stage next to its synthetic entrypoint.
        if registrant:
            ddc_files.append(registrant)

        return [DefaultInfo(files = depset([output_dir] + ddc_files)), output_groups, analyzable_info]

    return [DefaultInfo(files = depset([output_dir])), output_groups, analyzable_info]

# The web-only additions to the shared compile bundle. Web builds don't use
# native_deps, obfuscate, split_debug_info, extra_gen_snapshot_options, or
# min_os_version, so those stay unnamed.
#
# `profile` is deliberately NOT lifted from there either, even though the web
# rule has one: the shared attr documents itself in gen_snapshot terms ("AOT
# like release, but unstripped"), and a web build has no AOT step to describe.
# It is redeclared below with the meaning it actually has here.
# The compile inputs arrive as a bundle for the reason `KERNEL_COMPILE_ATTRS`
# documents. This rule does not call `flutter_compile_kernel`, so omitting one
# would not crash it — it would go quiet: the bundle is also what
# `synthesize_app_package` and `dart_analyzable_info_with_package` read, and a
# web build that drops one of those compiles the app against something other
# than what it declared. That is exactly how `language_version` was lost here.
_WEB_RELEVANT_KEYS = (
    "assets",
    "shaders",
    "tree_shake_icons",
    "license_files",
    "track_widget_creation",
    "_asset_bundle_tool",
)
_WEB_APPLICATION_ATTRS = KERNEL_COMPILE_ATTRS | {
    k: v
    for k, v in FLUTTER_APPLICATION_ATTRS.items()
    if k in _WEB_RELEVANT_KEYS
}

# Reaches the analysis closure only — see `analyzable_info` in the impl. No
# BUILD file names it and no compile action's inputs change.
_WEB_APPLICATION_ATTRS["_sky_engine"] = attr.label(
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)

flutter_web_bundle = rule(
    implementation = _flutter_web_bundle_impl,
    attrs = dict(_WEB_APPLICATION_ATTRS, **{
        "compiler": attr.string(
            doc = "Web compiler: 'dart2wasm' (default) or 'dart2js'.",
            default = "dart2wasm",
            values = ["dart2wasm", "dart2js"],
        ),
        "renderer": attr.string(
            doc = "Web renderer: 'skwasm' (default for wasm) or 'canvaskit'.",
            default = "skwasm",
            values = ["skwasm", "canvaskit"],
        ),
        "title": attr.string(
            doc = "HTML page title. Only used when index_html is not provided.",
        ),
        "base_href": attr.string(
            doc = "Base URL path for the app (default: '/'). Substituted for Flutter's " +
                  "`$FLUTTER_BASE_HREF` placeholder in whichever index.html this target " +
                  "ships — the built-in template or your own — matching " +
                  "`flutter build web --base-href`. Must start and end with '/'.",
            default = "/",
        ),
        "static_assets_url": attr.string(
            doc = "Value substituted for Flutter's `$FLUTTER_STATIC_ASSETS_URL` placeholder " +
                  "in index.html, matching `flutter build web --static-assets-url`. Must end " +
                  "with '/'. Defaults to '/', as upstream does; set it to a CDN origin to " +
                  "serve static assets from elsewhere.",
            default = "/",
        ),
        "web_defines": attr.string_dict(
            doc = "Template variables substituted for `{{NAME}}` placeholders in index.html " +
                  "and flutter_bootstrap.js, matching `flutter build web --web-define`. " +
                  "A placeholder with no value is an error rather than a warning, and so is " +
                  "an entry here that no template references — see `keep_placeholders` for " +
                  "the escape hatch. Values are substituted verbatim; escaping them for the " +
                  "surrounding HTML or JavaScript is yours to do.",
        ),
        "keep_placeholders": attr.string_list(
            doc = "`{{NAME}}` placeholders to leave in the shipped file instead of failing " +
                  "on them. For pages that hand `{{...}}` to a client-side template engine. " +
                  "Only the tight `{{name}}` form needs listing: the spaced `{{ name }}` and " +
                  "section `{{#name}}` forms Vue, Angular and Mustache normally use do not " +
                  "match the substitution pattern at all.",
        ),
        "optimization_level_js": attr.string(
            doc = "The `-O` level the dart2js compile runs at, matching " +
                  "`flutter build web --optimization-level`. \"auto\" (default) takes " +
                  "upstream's per-mode default — 1 in debug, 4 in profile and release — and " +
                  "an explicit level holds across every build mode. One attr per compiler " +
                  "because upstream's own defaults disagree: dart2wasm stops at 2 in release " +
                  "while dart2js goes to 4, so a single shared level could not state both. " +
                  "Applies in both `compiler` modes — a dart2wasm target also builds the " +
                  "dart2js fallback. Note upstream's single `--optimization-level` sets " +
                  "BOTH compilers, and its per-compiler default only applies when the flag " +
                  "is absent; here each compiler is asked separately, so setting this one " +
                  "leaves the WASM compile on its own default. " +
                  "\"0\" is accepted but comes with upstream's warning that " +
                  "dart2js level 0 is not well supported, which is why debug defaults to 1. " +
                  "From 2 up the level minifies on its own; `minify_js` is stated to the " +
                  "compiler regardless, so it decides minification here and this does not.",
            default = "auto",
            values = ["auto", "0", "1", "2", "3", "4"],
        ),
        "optimization_level_wasm": attr.string(
            doc = "The `-O` level the dart2wasm compile runs at, matching " +
                  "`flutter build web --optimization-level`. \"auto\" (default) takes " +
                  "upstream's per-mode default — 0 in debug, 2 in profile and release — and " +
                  "an explicit level holds across every build mode. Upstream stops at 2 for " +
                  "release on purpose: it is the highest level using only sound " +
                  "optimizations, and their web benchmarks put the rest at marginal. Debug " +
                  "takes 0 because that is the trade a debug build exists to make — on this " +
                  "repo's own web example it halves the compile at twice the module size. " +
                  "Only the WASM compile takes it, so setting it under " +
                  "`compiler = \"dart2js\"` is refused rather than ignored, and setting it " +
                  "leaves the dart2js fallback on its own default — upstream's single " +
                  "`--optimization-level` reaches both compilers, this attr reaches one.",
            default = "auto",
            values = ["auto", "0", "1", "2", "3", "4"],
        ),
        "minify_js": attr.string(
            doc = "Whether the dart2js output minifies names, matching " +
                  "`flutter build web --minify-js`. \"auto\" (default) minifies in release " +
                  "and not in debug or profile, as upstream does; \"true\" and \"false\" state " +
                  "it outright and hold across every build mode. Applies in both `compiler` " +
                  "modes — a dart2wasm target also builds the dart2js fallback. Always passed " +
                  "to the compiler explicitly rather than left to be inferred from the " +
                  "optimization level, so the two stay independent — `-O2` and above minify " +
                  "on their own, which would otherwise minify a debug build.",
            default = "auto",
            values = ["auto", "true", "false"],
        ),
        "native_null_assertions": attr.bool(
            doc = "Whether the dart2js output checks, at runtime, that values arriving from " +
                  "JS interop and the web libraries actually match the nullability they were " +
                  "declared with. True by default, as `flutter build web` defaults it: a JS " +
                  "value that is null where Dart was promised non-null otherwise surfaces " +
                  "much later, as a failure in code that did nothing wrong. Set False to drop " +
                  "the checks once an interop surface is trusted. Applies to the dart2js " +
                  "compile in both `compiler` modes — a dart2wasm target also builds the JS " +
                  "fallback. The DDC dev loop applies these checks too, and reads this value " +
                  "from the build's dev config, so the two agree.",
            default = True,
        ),
        "dump_info": attr.bool(
            doc = "If True, dart2js writes a JSON description of what ended up in the output " +
                  "and why, for `package:dart2js_info` and the size tooling built on it — " +
                  "matching `flutter build web --dump-info`. Note the flag `flutter build " +
                  "web` passes through today is `--stage=dump-info-all`; the bare " +
                  "`--dump-info` it is named after now writes a binary `.info.data` instead. " +
                  "The file is a build diagnostic, not part of the app, so unlike upstream " +
                  "it is kept OUT of the bundle and produced as a named output instead: " +
                  "`bazel build //your:app --output_groups=dump_info` writes " +
                  "`<name>_dart2js_info.json`. It can be megabytes and describes your whole " +
                  "program, so shipping it to visitors is not something to do by default. " +
                  "Note which compilation it describes: only dart2js produces a report, so " +
                  "under the default `compiler = \"dart2wasm\"` it describes the JS " +
                  "*fallback* — not the WASM build most visitors run.",
            default = False,
        ),
        "enable_experiments": attr.string_list(
            doc = "Dart language experiments to enable, by name and without the flag " +
                  "(e.g. [\"records\"]), matching `flutter build web --enable-experiment`. " +
                  "Reaches both web compilers and the kernel compile the icon tree-shaker " +
                  "reads, since an experiment changes how the source parses and every step " +
                  "that parses it has to agree. The dev loop compiles with DDC instead and " +
                  "reads the list from this build's dev config.",
        ),
        "frequency_based_minification": attr.bool(
            doc = "Whether dart2js's minifier may choose short names by how often an " +
                  "identifier occurs. True (default) produces the smallest output. False " +
                  "passes `--no-frequency-based-minification`, matching " +
                  "`flutter build web --no-frequency-based-minification`: names then depend " +
                  "only on the program, so an unrelated edit stops renaming half the output " +
                  "and two builds can be diffed to see what actually changed. Costs some " +
                  "output size. Named for what it enables, so the default reads as the " +
                  "behaviour rather than as a double negative. Only minified output has " +
                  "names to choose, so this does nothing alongside `minify_js = \"false\"`.",
            default = True,
        ),
        "strip_wasm": attr.bool(
            doc = "Whether a release build strips static symbol names from the WASM output, " +
                  "matching `flutter build web --strip-wasm`. Debug and profile builds never " +
                  "strip whatever this says — upstream gates it on release the same way, and " +
                  "those two modes exist to be read. Set False to keep the names in release " +
                  "for a production stack trace, at a cost in bundle size. Only the WASM " +
                  "compile takes it, so setting it False under `compiler = \"dart2js\"` is " +
                  "refused rather than ignored.",
            default = True,
        ),
        "minify_wasm": attr.string(
            doc = "Whether the dart2wasm output minifies the names kept for runtime use " +
                  "(the ones `runtimeType.toString()` reads), matching " +
                  "`flutter build web --minify-wasm`. \"auto\" (default) minifies in release " +
                  "and not in debug or profile; \"true\" and \"false\" hold across every build " +
                  "mode. Only the WASM compile takes it, so setting it away from \"auto\" " +
                  "under `compiler = \"dart2js\"` is refused rather than ignored.",
            default = "auto",
            values = ["auto", "true", "false"],
        ),
        "source_maps": attr.bool(
            doc = "If True, generate source maps alongside compiled output.",
            default = False,
        ),
        "profile": attr.bool(
            doc = "If True, build in profile mode regardless of the Bazel compilation mode, " +
                  "matching `flutter build web --profile`. A profile build carries " +
                  "`dart.vm.profile=true` instead of `dart.vm.product=true`, runs with asserts " +
                  "off, and drops `toString()` bodies the way release does — so it measures " +
                  "what release does — but is left unminified and unstripped so the profile " +
                  "names a frame reports are readable. It is not a debug build: none of the " +
                  "dev-loop side files are produced, so `flutter_bazel run` cannot serve it.",
            default = False,
        ),
        "web_assets": attr.label_list(
            doc = "Static web files (favicon.png, icons/, etc.) copied to the output root. " +
                  "Paths are preserved relative to the package (e.g. web/favicon.png → favicon.png, web/icons/icon-192.png → icons/icon-192.png). " +
                  "Typically: glob([\"web/**\"]).",
            allow_files = True,
        ),
        "index_html": attr.label(
            doc = "User-provided index.html *template*. Substituted the way " +
                  "`flutter build web` substitutes `web/index.html`: `$FLUTTER_BASE_HREF`, " +
                  "`$FLUTTER_STATIC_ASSETS_URL`, and `{{...}}` variables from `web_defines` " +
                  "plus the build's own `{{flutter_js}}`, `{{flutter_build_config}}`, " +
                  "`{{flutter_service_worker_version}}` and `{{flutter_bootstrap_js}}`. Raw " +
                  "`flutter create` output works unchanged. When set, `title` is ignored — " +
                  "it only feeds the built-in template. If not set, an index.html is " +
                  "generated from that template. Note that only this file is templated: an " +
                  "index.html nested deeper under `web/` ships through `web_assets` " +
                  "verbatim, where `flutter build web` would substitute it too.",
            allow_single_file = [".html"],
        ),
        "bootstrap_js": attr.label(
            doc = "User-provided flutter_bootstrap.js *template*, the customization point " +
                  "`flutter create`'s index.html comment points at. Substituted before " +
                  "index.html, so index.html's `{{flutter_bootstrap_js}}` inlines the " +
                  "finished result. Reference `{{flutter_build_config}}` to get this " +
                  "target's compiler/renderer/engine-revision build config — without it the " +
                  "loader has nothing to boot. If not set, the rule generates one. A debug " +
                  "build substitutes it a second time for `flutter_bazel run -d chrome`, " +
                  "with DDC\'s build config and no service worker in place of this " +
                  "target\'s, so the same template and the same `web_defines` reach both.",
            allow_single_file = [".js"],
        ),
        "manifest_json": attr.label(
            doc = "User-provided manifest.json file for PWA support. If not set, a manifest.json " +
                  "is generated from the built-in template using the title attr.",
            allow_single_file = [".json"],
        ),
        "version_json": attr.label(
            doc = "User-provided version.json file. If not set, a version.json is generated from " +
                  "the package_name + app_version + app_build_number attrs. The web `package_info_plus` " +
                  "plugin (and similar PackageInfo-style web plugins) reads this file to populate " +
                  "appName/version/buildNumber/packageName at runtime.",
            allow_single_file = [".json"],
        ),
        "app_version": attr.string(
            doc = "App version string written to the generated version.json. Defaults to '1.0.0'.",
        ),
        "app_build_number": attr.string(
            doc = "Build number written to the generated version.json. Defaults to '1'.",
        ),
        "pwa": attr.bool(
            doc = "If True (default), ship flutter_service_worker.js and register it " +
                  "from flutter_bootstrap.js. This does not add offline caching: " +
                  "matching `flutter build web`, the worker unregisters itself and " +
                  "reloads its clients, which frees visitors still holding the caching " +
                  "service worker that Flutter shipped before deprecating it " +
                  "(flutter/flutter#156910). Registration is skipped for visitors who " +
                  "have no existing worker, so leaving this on costs a first-time " +
                  "visitor nothing. Set False only if no deployment of this app ever " +
                  "registered a worker. To ship your own service worker, set this " +
                  "False and supply the worker plus a matching index.html carrying " +
                  "its registration; with pwa = True both workers would claim " +
                  "flutter_service_worker.js and the bundle refuses that.",
            default = True,
        ),
        "use_local_canvaskit": attr.bool(
            doc = "If True, load CanvasKit/Skwasm from the app's own server instead of " +
                  "Google's CDN (gstatic.com). Use this for air-gapped deployments or " +
                  "environments that cannot reach external CDNs. The CDN already sends " +
                  "Cross-Origin-Resource-Policy: cross-origin, so COEP does not require " +
                  "this. The canvaskit/ directory is always included in the build output " +
                  "regardless of this setting.\n\n" +
                  "Required to serve under a Content Security Policy: the renderer is a " +
                  "script, so `script-src 'self'` blocks it from the CDN and the app never " +
                  "boots. Note the guarantee stops at `script-src` — the framework still " +
                  "fetches fonts from fonts.gstatic.com, so a `default-src 'self'` policy " +
                  "needs that origin allowed (or the fonts bundled) whatever this is set to.",
            default = False,
        ),
        "_dart2wasm_platform_dill": attr.label(
            default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2wasm_platform.dill"),
            allow_single_file = True,
        ),
        "_dart2js_platform_dill": attr.label(
            default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2js_platform.dill"),
            allow_single_file = True,
        ),
        "_ddc_outline_dill": attr.label(
            default = Label("@flutter_web_sdk//:web-sdk/kernel/ddc_outline.dill"),
            allow_single_file = True,
        ),
        "_ddc_libraries_spec": attr.label(
            default = Label("@flutter_web_sdk//:web-sdk/libraries.json"),
            allow_single_file = True,
        ),
        "_ddc_dart_sdk_js": attr.label(
            default = Label("@flutter_web_sdk//:web-sdk/kernel/ddcLibraryBundle-canvaskit/dart_sdk.js"),
            allow_single_file = True,
        ),
        "_ddc_module_loader_js": attr.label(
            default = Label("@flutter_web_sdk//:dart-sdk/lib/dev_compiler/ddc/ddc_module_loader.js"),
            allow_single_file = True,
        ),
        "_ddc_stack_trace_mapper_js": attr.label(
            default = Label("@flutter_web_sdk//:dart-sdk/lib/dev_compiler/web/dart_stack_trace_mapper.js"),
            allow_single_file = True,
        ),
        "_web_sdk": attr.label(
            default = Label("@flutter_web_sdk//:web_sdk"),
        ),
        "_bundle_tool": attr.label(
            default = Label("//flutter/private/tools:bundle_app.dart"),
            allow_single_file = [".dart"],
        ),
        "_web_template_tool": attr.label(
            default = Label("//flutter/private/tools:web_template.dart"),
            allow_single_file = [".dart"],
        ),
    }) | AGENT_EXTENSIONS_ATTR,
    toolchains = ["@rules_flutter//flutter:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Builds a Flutter web application (WASM or JS) with all deployment artifacts.",
)
