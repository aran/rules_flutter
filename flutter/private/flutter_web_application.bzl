"""Flutter web application build.

Produces a deployable web directory containing:
- main.dart.wasm + main.dart.mjs (compiler="dart2wasm"), plus main.dart.js
  unless `js_fallback = False` leaves the JavaScript build out
  or main.dart.js alone (compiler="dart2js")
- flutter.js (Flutter engine bootstrapper from web SDK)
- canvaskit/ (renderer engine artifacts; only with use_local_canvaskit, or in a
  debug build for the dev loop)
- flutter_assets/ (AssetManifest.bin.json for web)
- index.html
- flutter_bootstrap.js
- flutter_service_worker.js (optional; tears down a previously installed
  caching service worker — see flutter/private/web_service_worker.bzl)

When compiler="dart2wasm", both WASM and JS outputs are produced by default,
as `flutter build web --wasm` does. The bootstrap lists both builds so the
Flutter engine tries WASM first and falls back to JS (CanvasKit) on browsers
that cannot run the WASM build. `js_fallback = False` makes the output
WebAssembly only: no dart2js action runs, the bootstrap lists the WASM build
alone, and nothing the rule generates refers to main.dart.js. A browser that
cannot run it then gets no app (flutter.js logs that no compatible build was
found and throws; the generated bootstrap shows a message instead).

Both dart2wasm and dart2js take .dart source directly (not kernel .dill),
so we skip the frontend_server kernel compilation step used by desktop/mobile.

The program is the bundle's `flutter_application`'s, built once for each
compiler the bundle ships, so a dependency may differ between dart2wasm and
dart2js (see `flutter_web_branch.bzl`). The macro in `web.bzl` declares the
staging target each compiler's inputs come from, over the application.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING", "PROGRAM_ASSETS_TOOLCHAINS", "generate_dev_package_config", "import_check_output_groups", "program_assets_attrs")
load("//flutter:providers.bzl", "FlutterInfo", "FlutterNativeLibraryInfo", "FlutterSdkRecordInfo")
load(
    "//flutter/private:app_entrypoint.bzl",
    "APP_SCHEME",
    "app_main_location",
    "app_scheme_sources",
    "compute_same_root_main_import",
    "resolve_wrapper_main_import",
    "with_root",
)
load("//flutter/private:app_version.bzl", "web_version")
load("//flutter/private:application_version.bzl", "shown_label")
load(
    "//flutter/private:common.bzl",
    "FLUTTER_APPLICATION_TOOL_ATTRS",
    "asset_roots",
    "declare_flutter_assets_dir",
    "flavor_dart_defines",
    "flutter_build_assets",
    "flutter_compile_shaders",
    "make_web_wrapper_main_content",
    "merge_dart_defines",
    "resolve_dev_generated_sources",
    "shader_sources",
    "shakes_icons",
)
load("//flutter/private:dev_config.bzl", "dev_config_file", "dev_search_roots", "dev_source_dir", "write_dev_config")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_info.bzl", "plugins_in_registration_order")
load(
    "//flutter/private:flutter_web_branch.bzl",
    "BRANCH_COMPILER",
    "FlutterWebBranchInfo",
    "WEB_PLATFORM_ATTRS",
    "web_branches",
    "web_compile_branches",
)
load(
    "//flutter/private:flutter_web_compile.bzl",
    "flutter_dart2js_action",
    "flutter_dart2wasm_action",
    "web_build_mode",
)
load("//flutter/private:link_hooks.bzl", "link_hooks_plan", "program_assets")
load("//flutter/private:path_mapping.bzl", "file_ref", "json_config_args")
load("//flutter/private:plugin_registrant.bzl", "generate_dart_plugin_registrant")
load("//flutter/private:program_analysis.bzl", "program_analyzable_info")
load("//flutter/private:sdk_defines.bzl", "program_version_dart_defines")
load(
    "//flutter/private:validation.bzl",
    "escape_html",
    "renderer_file_needed",
    "validate_base_href",
    "validate_static_assets_url",
    "validate_wasm_browsers",
    "validate_web_compiler_renderer",
    "validate_web_js_fallback",
    "validate_web_js_only_attrs",
    "validate_web_wasm_only_attrs",
    "wasm_allow_list_property",
    "web_renderer",
)
load(
    "//flutter/private:web_service_worker.bzl",
    "SERVICE_WORKER_JS",
    "SERVICE_WORKER_VERSION",
    "service_worker_load_args",
)

# The glyph the engine measures an icon font's height with.
_SPACE_CODE_POINT = 32

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
# around it. The first `%s` is the load argument, which is empty when neither
# a worker nor an allow-list is set; the second is the JS string literal shown
# when the loader cannot start the app.
#
# `load` returns a promise that rejects when it cannot start the app, notably
# when none of the builds is one the browser can run ("no compatible build
# found"). Without the `catch` the visitor gets the page `index.html` left: no
# app and no word why. The loader's own error stays in the console.
_BOOTSTRAP_JS_TEMPLATE = """\
{{flutter_build_config}}
{
  let script = document.createElement("script");
  script.src = "flutter.js";
  script.addEventListener("load", function() {
    _flutter.loader.load(%s).catch(function(error) {
      console.error(error);
      let message = document.createElement("p");
      message.setAttribute("role", "alert");
      message.textContent = %s;
      message.style.cssText = "font: 16px/1.5 system-ui, sans-serif; max-width: 32em; margin: 4em auto; padding: 0 1em;";
      document.body.appendChild(message);
    });
  });
  document.head.appendChild(script);
}
"""

_NO_APP_MESSAGE = "This app could not start. Reload the page, or try a different browser."

# A bundle with no JavaScript build runs only where the browser can run WASM.
_WASM_ONLY_NO_APP_MESSAGE = (
    "This app could not start. It is built for WebAssembly only, so it needs a " +
    "browser that can run it."
)

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
    "flutter.js.map": "this is the engine loader's source map, taken from the Flutter web SDK " +
                      "beside flutter.js. It cannot be replaced.",
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

def _reserve(reserved, copies, refs, src, dst):
    """Append a rule-generated copy and reserve its destination.

    Args:
        reserved: Destination-to-source dict, mutated.
        copies: The bundler's copy list, mutated.
        refs: The bundler config's `file_ref` list, mutated.
        src: Source File.
        dst: Bundle-relative destination.
    """
    reserved[dst] = src
    copies.append({"src": file_ref(refs, src), "dst": dst})

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

def _extract_from_tree(ctx, tools, tree, name, output):
    """Copies the file `name` out of the tree artifact `tree` to `output`.

    For a file a compiler writes beside its output with no way to put it
    elsewhere, which Bazel cannot declare inside the declared directory.

    Args:
        ctx: Rule context carrying `_bundle_tool` and `_bundle_tool_imports`.
        tools: `portable_tools(ctx)`.
        tree: The tree artifact.
        name: The file's path inside `tree`.
        output: The declared File to copy it to.
    """
    refs = []
    config = {"extracts": [{
        "src": file_ref(refs, tree) + "/" + name,
        "dst": file_ref(refs, output),
    }]}
    args = ctx.actions.args()
    args.add(ctx.file._bundle_tool)
    args.add("--config")
    ctx.actions.run(
        executable = tools.dart,
        arguments = [args, json_config_args(ctx, config, refs)],
        inputs = depset([tree, ctx.file._bundle_tool] + ctx.files._bundle_tool_imports, transitive = [tools.sdk_files.run]),
        outputs = [output],
        mnemonic = "FlutterWebExtract",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Extracting %s of %s" % (name, ctx.label),
    )

def _check_version_json(ctx, tools, program, version):
    """Registers the check that the app's own version.json gives `version`.

    Args:
        ctx: Rule context carrying `version_json` and `_check_version_json_tool`.
        tools: `portable_tools(ctx)`.
        program: The application's program.
        version: `web_version` of the application.

    Returns:
        The stamp the check writes, for the `_validation` output group.
    """
    stamp = ctx.actions.declare_file(ctx.label.name + "_version_json.checked")
    args = ctx.actions.args()
    args.add(ctx.file._check_version_json_tool)
    args.add("--version-json", ctx.file.version_json)
    args.add("--name", ctx.file.version_json.short_path)
    args.add("--bundle", shown_label(ctx.label))
    args.add("--application", shown_label(program.label))
    args.add("--version", version.version)
    args.add("--version-default", "false" if program.build_name else "true")
    args.add("--build-number", version.build_number)
    args.add("--build-number-default", "false" if program.build_number else "true")
    for attribute, option in [("build_name", "--version-setting"), ("build_number", "--build-number-setting")]:
        if attribute in program.version_settings:
            args.add(option, program.version_settings[attribute])
    args.add("--stamp", stamp)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(
            [ctx.file._check_version_json_tool, ctx.file.version_json],
            transitive = [tools.sdk_files.run],
        ),
        outputs = [stamp],
        mnemonic = "FlutterCheckWebVersion",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Checking the version.json of %s" % ctx.label,
    )
    return stamp

def _flutter_web_bundle_impl(ctx):
    renderer = web_renderer(ctx.attr.compiler, ctx.attr.renderer)
    validate_web_compiler_renderer(ctx.attr.compiler, renderer)
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
    validate_wasm_browsers(
        ctx.attr.wasm_browsers,
        ctx.attr.compiler,
        renderer,
        ctx.file.bootstrap_js != None,
        ctx.label,
    )
    validate_web_js_fallback(ctx.attr.compiler, ctx.attr.js_fallback, ctx.label)
    validate_web_js_only_attrs(
        ctx.attr.compiler,
        ctx.attr.js_fallback,
        [
            n
            for n, set_away in [
                ("dump_info", ctx.attr.dump_info),
                ("frequency_based_minification", not ctx.attr.frequency_based_minification),
                ("minify_js", ctx.attr.minify_js != "auto"),
                ("optimization_level_js", ctx.attr.optimization_level_js != "auto"),
            ]
            if set_away
        ],
        ctx.label,
    )
    validate_base_href(ctx.attr.base_href, ctx.label)
    validate_static_assets_url(ctx.attr.static_assets_url, ctx.label)
    web_dir = ctx.attr.web_dir
    if "\\" in web_dir or [p for p in web_dir.split("/") if p in ("", ".", "..")]:
        fail("%s: web_dir must be a directory relative to the package, with no leading " % ctx.label +
             "or trailing '/' and no '.' or '..' parts (e.g. \"web\" or \"web_apps/reminders\"); " +
             "got %r" % web_dir)

    # Every compile and bundle here is the same whatever the host, so it runs
    # `portable`. The target's toolchain is the host's (a web build targets
    # the host platform), and names the tools `_dev_config.json` points the
    # dev tool at: it runs them on this machine.
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    tools = portable_tools(ctx)
    sdk_record = ctx.attr._sdk_record[FlutterSdkRecordInfo]

    # A web app of an engine that is not the release's loads its renderer from the web SDK it was
    # checked against: the CDN has none for it.
    use_local_canvaskit = ctx.attr.use_local_canvaskit or sdk_record.record != None

    # The build mode drives the mode defines of every compile action below,
    # the same way the native kernel path switches on COMPILATION_MODE.
    mode = web_build_mode(ctx)
    is_debug = mode == "debug"

    # Step 1: Collect sources, generate package config, handle plugin registrant.
    # dart compile wasm/js take .dart source directly (not kernel .dill).
    #
    # Every reader of `deps` reads a named branch. Each compile takes its own
    # compiler's; everything the bundle holds once — the plugin registrant
    # every compile imports, the assets, the icon tree-shaker's kernel, the
    # import check and the analysis closure — takes the primary's, the build
    # the bundle describes. A branch is the program built with its compiler's
    # web platform (`js_platform` or `wasm_platform`): `deps` and the staging
    # target beside the bundle are split on it, and DDC reads dart2js's.
    branches = web_compile_branches(ctx.attr.compiler, ctx.attr.js_fallback, is_debug)
    branch_inputs = {}
    for branch in branches:
        setting = BRANCH_COMPILER[branch]
        staged = ctx.split_attr.branches.get(setting)
        if staged == None:
            fail("%s: the %s branch builds for the %s platform, which its dependencies were not split for" % (ctx.label, branch, setting))
        info = staged[FlutterWebBranchInfo]
        if info.runtime != setting:
            platform = getattr(ctx.attr, setting + "_platform")
            fail("%s: `%s_platform` is %s, which must carry @rules_dart//dart/constraints:%s; its web compiler is %s" % (ctx.label, setting, platform.label, setting, info.runtime))
        branch_inputs[branch] = struct(
            program = info.program,
            deps = info.program.deps,
            srcs = info.srcs,
            packages = info.packages,
            config_file = info.config_file,
            compile_srcs = info.compile_srcs,
        )
    primary = branch_inputs[branches[0]]

    # The application's program. Only its `deps` differ between branches, and
    # each compile reads its own branch's; everything else is the same files
    # and values in every branch.
    program = primary.program

    # The app's own package root, the application's: the single answer to
    # "what is `package:<self>/…` rooted at" for this target. Everything
    # downstream that asks the question (package synthesis, the wrapper's
    # import, the dev-config entrypoint, the analyzer's source split) takes it
    # from here rather than deriving its own, so the compile path and the
    # analysis path cannot disagree on a nested app's `package:` URIs.
    package_root = program.package_root
    main = program.main

    # A release or profile build runs the packages' link hooks over the uses
    # the primary compile records, as `flutter build web` does: its link step
    # reads dart2wasm's uses, and dart2js's when there is no WebAssembly
    # build. The hooks' assets are the bundle's, shared by both builds. A
    # debug build links nothing and ships every declared data asset. Icon
    # tree shaking reads the `IconData` uses of every compile, as `flutter
    # build web` has it, so with it the fallback dart2js records its uses too.
    link_hooks = link_hooks_plan(program, primary.deps, links = not is_debug)
    shakes = shakes_icons(program, tools, is_debug)
    recorded_uses = ctx.actions.declare_file(ctx.label.name + ".recorded_uses.json") if link_hooks.runs or shakes else None
    icon_uses = [recorded_uses] if shakes else []

    # Merged once for all compile actions below (dart2wasm, dart2js) and the
    # dev-config emission: the application's defines and the flavor's, the
    # app's version and the SDK's. There is no `build_info` on web to keep the
    # flavor out of.
    user_defines = merge_dart_defines(ctx, program.defines) + flavor_dart_defines(program.flavor) + program_version_dart_defines(
        tools.sdk_defines,
        program.build_name,
        program.build_number,
    )

    # Hot-reload dev metadata (debug only): a multi-root dev package_config so a
    # source-assembled (codegen) app resolves package: URIs across the live
    # source tree + generated bazel-out roots, instead of the frozen assembled
    # `.pkgsrcs` dir the build config uses. Computed pre-colocation (package_root +
    # File.is_source intact). See rules_dart generate_dev_package_config.
    dev_package_config = None
    dev_filesystem_roots = []
    dev_filesystem_scheme = ""
    dev_package_config_names = []
    dev_generated_sources = []
    dev_generated_source_uris = []
    dev_source_packages = []
    ddc = branch_inputs.get("ddc")
    if ddc:
        dev_package_config = ctx.actions.declare_file(ctx.label.name + ".dev_package_config.json")
        dev_pc = generate_dev_package_config(ddc.packages, ddc.srcs + [main], dev_package_config, scheme = APP_SCHEME)
        ctx.actions.write(dev_package_config, dev_pc.content)

        # A `main` with no `package:` URI is imported by the dev loop's
        # synthetic entrypoint under the app scheme, from this root.
        dev_filesystem_roots = with_root(
            dev_pc.filesystem_roots,
            app_main_location(program.package_name, package_root, main).root,
        )
        dev_filesystem_scheme = dev_pc.scheme
        dev_generated_source_uris = dev_pc.generated_source_uris
        dev_source_packages = dev_pc.source_packages
        dev_generated_sources = resolve_dev_generated_sources(
            dev_pc.generated_source_paths,
            ddc.srcs + [main],
        )

        # The dev package_config's roots and the filesystem roots reach every
        # file the dev compiler may read.
        dev_package_config_names = ddc.srcs + [main]

    # Generate web wrapper main with ui_web.bootstrapEngine().
    # Flutter web ALWAYS needs this wrapper to properly initialize the engine
    # (create the implicit view, set up the platform dispatcher, etc.)
    # before calling the user's main(). This matches `flutter build web`.
    all_dep_plugins = []
    for dep in primary.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
    plugins = plugins_in_registration_order(all_dep_plugins)
    registrant = generate_dart_plugin_registrant(ctx, plugins, target_platform = "web")

    wrapper = ctx.actions.declare_file(ctx.label.name + "_wrapper_main.dart")
    wrapper_depth = len(wrapper.dirname.split("/"))

    # The dev-tool support's service extensions. In debug they are compiled
    # into the bundle, as the native rules compile them into their kernel,
    # whatever `--@rules_flutter//flutter:dev_tool_support` says: the dev loop
    # a web debug bundle is for serves them through the page. They are served
    # by the bridge: dart2wasm and dart2js leave `registerExtension` with no VM
    # service behind it, so the bridge publishes the handlers on the page for
    # the dev tool to call over the browser's DevTools protocol. The DDC dev
    # loop imports the same staged file from its own synthetic entrypoint (see
    # the `agentExtensions` dev-config key) and reaches it through DWDS.
    staged_agent = None
    staged_agent_bridge = None
    if is_debug:
        staged_agent = ctx.actions.declare_file(ctx.label.name + ".agent_extensions.dart")
        ctx.actions.symlink(output = staged_agent, target_file = ctx.file._dev_tool_support_src)
        staged_agent_bridge = ctx.actions.declare_file(ctx.label.name + ".agent_web_bridge.dart")
        ctx.actions.symlink(output = staged_agent_bridge, target_file = ctx.file._agent_web_bridge_src)

    # Import the user's main via its `package:` URI when available. That URI
    # resolves through `package_config.json` to the colocated package's
    # `rootUri`, so the user's `main.dart` is read from the assembled
    # directory and its relative imports find their colocated siblings.
    main_import = resolve_wrapper_main_import(
        program.package_name,
        package_root,
        main.short_path,
        main.path,
        wrapper_depth,
    )
    if not main.is_source and main.root.path == wrapper.root.path:
        # A `main` a rule wrote, in the directory the wrapper is in. Named from
        # that directory's root: its own path has the configuration in it, which
        # a path-mapped compile reads under another name.
        root = wrapper.root.path
        wrapper_path = wrapper.path[len(root) + 1:]
        main_import = compute_same_root_main_import(
            wrapper_path.rpartition("/")[0],
            main.path[len(root) + 1:],
        )
    wrapper_content = make_web_wrapper_main_content(
        main_import,
        registrant.basename if registrant else None,
        agent_imports = (staged_agent.basename, staged_agent_bridge.basename) if is_debug else None,
    )
    ctx.actions.write(wrapper, wrapper_content)
    entrypoint = wrapper
    extra_wrapper_srcs = [main, wrapper]
    if registrant:
        extra_wrapper_srcs.append(registrant)
    if is_debug:
        extra_wrapper_srcs.extend([staged_agent, staged_agent_bridge])

    # `synthesize_app_package` appends the app's own package last. What a rule
    # wrote for the program (`unchecked_srcs`, the wrapper `main`, the plugin
    # registrant, the debug agent files) is compiled with it, so its imports
    # are uses of `deps`; they are that rule's to get right, so the check
    # judges only the user's.
    unchecked = program.unchecked_srcs
    import_checks = import_check_output_groups(
        ctx,
        ctx.executable._kernel_tool,
        [f for f in [main] + program.srcs if f not in unchecked],
        primary.packages[-1],
        primary.deps,
        # The user's `main`, not the wrapper: the wrapper, among `generated`,
        # starts the program too, and `main` is the file `srcs` must hang from.
        main = main,
        # A variant's application's sources start the program for the reach
        # check too, as `flutter_compile_kernel` passes them.
        generated = [f for f in unchecked + program.entry_srcs if f.extension == "dart"] + [f for f in extra_wrapper_srcs if f != main],
    )

    # What a compile of each branch reads: the branch's co-located sources and
    # the files every compile shares.
    compile_srcs = {
        branch: inputs.compile_srcs + extra_wrapper_srcs
        for branch, inputs in branch_inputs.items()
    }

    # Step 2: Compile to WASM (with a JS build beside it unless `js_fallback = False`) or JS only.
    # dart2js outputs to a tree artifact (directory) to support deferred loading:
    # dart2js may produce main.dart.js + *.part.js files for deferred imports.
    compile_outputs = []  # Files (wasm, mjs, wasm.map)
    output_support_js = None  # dart2wasm's check of the browser
    compile_copies = []  # Bundle copy entries for compile_outputs
    dart2js_dirs = []  # Tree artifacts from dart2js

    # flutter.js does the registering: it waits for the new worker to activate
    # (with a timeout) before booting the app, and — given only a version — it
    # registers nothing unless the visitor already has a worker to replace.
    load_args = service_worker_load_args(
        ctx.attr.pwa,
        extra_properties = [wasm_allow_list_property(ctx.attr.wasm_browsers)],
    )
    if ctx.attr.compiler == "dart2wasm":
        # Primary: dart2wasm. Outputs are declared under a subdirectory with
        # their canonical bundle names: dart2wasm embeds a sourceMappingURL
        # referencing `<output>.map` by name, so the compiled name and the
        # shipped name must be the same for the browser to find the map.
        output_wasm = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm")
        output_mjs = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.mjs")
        output_support_js = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.support.js")
        output_wasm_map = None
        if ctx.attr.source_maps:
            output_wasm_map = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm.map")
        flutter_dart2wasm_action(
            ctx = ctx,
            dart = tools.dart,
            sdk_files = tools.sdk_files,
            dart2wasm_platform_dill = ctx.file._dart2wasm_platform_dill,
            main_dart = entrypoint,
            srcs = compile_srcs["dart2wasm"],
            package_config = branch_inputs["dart2wasm"].config_file,
            output_wasm = output_wasm,
            output_mjs = output_mjs,
            mode = mode,
            output_source_map = output_wasm_map,
            optimization_level = ctx.attr.optimization_level_wasm,
            strip_wasm = ctx.attr.strip_wasm,
            minify = ctx.attr.minify_wasm,
            enable_experiments = ctx.attr.enable_experiments,
            defines = user_defines,
            renderer = renderer,
            optimizing_cpus = ctx.attr._wasm_opt_cpus[BuildSettingInfo].value,
            recorded_uses = recorded_uses,
            output_support_js = output_support_js,
        )

        builds = [_wasm_build(renderer)]
        if ctx.attr.js_fallback:
            # Opt-in fallback: dart2js (always canvaskit renderer) — tree artifact for deferred loading
            output_js_fallback_dir = ctx.actions.declare_directory(ctx.label.name + "_dart2js_fallback")
            flutter_dart2js_action(
                ctx = ctx,
                dart = tools.dart,
                sdk_files = tools.sdk_files,
                dart2js_platform_dill = ctx.file._dart2js_platform_dill,
                main_dart = entrypoint,
                srcs = compile_srcs["dart2js"],
                package_config = branch_inputs["dart2js"].config_file,
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
                write_resources = shakes,
            )
            if shakes:
                fallback_uses = ctx.actions.declare_file(ctx.label.name + "_dart2js_fallback.recorded_uses.json")
                _extract_from_tree(
                    ctx,
                    tools,
                    output_js_fallback_dir,
                    "main.dart.js.resources.json",
                    fallback_uses,
                )
                icon_uses.append(fallback_uses)
            dart2js_dirs = [output_js_fallback_dir]
            builds.append(_JS_BUILD)
        compile_outputs = [output_wasm, output_mjs]
        compile_copies = [
            {"src": output_wasm, "dst": "main.dart.wasm"},
            {"src": output_mjs, "dst": "main.dart.mjs"},
        ]
        if output_wasm_map != None:
            compile_outputs.append(output_wasm_map)
            compile_copies.append({"src": output_wasm_map, "dst": "main.dart.wasm.map"})
    else:
        # JS-only mode — tree artifact for deferred loading
        output_js_dir = ctx.actions.declare_directory(ctx.label.name + "_dart2js")
        flutter_dart2js_action(
            ctx = ctx,
            dart = tools.dart,
            sdk_files = tools.sdk_files,
            dart2js_platform_dill = ctx.file._dart2js_platform_dill,
            main_dart = entrypoint,
            srcs = compile_srcs["dart2js"],
            package_config = branch_inputs["dart2js"].config_file,
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
            renderer = renderer,
            write_resources = recorded_uses != None,
        )
        dart2js_dirs = [output_js_dir]
        builds = [_JS_BUILD]
        if recorded_uses != None:
            _extract_from_tree(
                ctx,
                tools,
                output_js_dir,
                "main.dart.js.resources.json",
                recorded_uses,
            )

    # Step 3: Shader compilation + asset bundle.
    compiled_shaders = flutter_compile_shaders(ctx, tools, "web", primary.deps, program)

    linked = program_assets(
        ctx,
        program,
        primary.deps,
        link_hooks,
        recorded_uses,
        name = ctx.label.name + "_program_assets",
    )
    flutter_assets = declare_flutter_assets_dir(ctx)
    flutter_build_assets(
        ctx,
        tools,
        flutter_assets,
        primary.deps,
        "web",
        compiled_shaders,
        recorded_uses = icon_uses,
        is_debug = is_debug,
        # The engine measures an icon font's height with the space glyph, so
        # every subset keeps it, as flutter_tools' web icon shaking does.
        optional_code_points = [_SPACE_CODE_POINT],
        program_assets = linked.info,
        inputs = program,
    )

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
        wasm_only = [b for b in builds if b["compileTarget"] == "dart2wasm"] == builds
        no_app_message = _WASM_ONLY_NO_APP_MESSAGE if wasm_only else _NO_APP_MESSAGE
        ctx.actions.write(
            bootstrap_template,
            _BOOTSTRAP_JS_TEMPLATE % (load_args, json.encode(no_app_message)),
        )

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

    # The app's own version.json, or one written from the application. The
    # program reports the application's version, the defaults when it sets
    # none, so an own file must give the same: checked when it is built,
    # since only then is it known.
    version = web_version(program.build_name, program.build_number)
    version_checks = []
    if ctx.file.version_json:
        version_json = ctx.file.version_json
        version_checks.append(_check_version_json(ctx, tools, program, version))
    else:
        app_name = program.package_name
        version_json = ctx.actions.declare_file(ctx.label.name + "_version.json")
        ctx.actions.write(version_json, json.encode({
            "app_name": app_name,
            "version": version.version,
            "build_number": version.build_number,
            "package_name": app_name,
        }))

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
    web_sdk_files = ctx.attr._web_sdk[DefaultInfo].files.to_list() if ctx.attr._web_sdk else []
    flutter_js_file = None
    flutter_js_map = None
    renderer_files = []
    for f in web_sdk_files:
        # flutter.js is at web-sdk/flutter_js/flutter.js, and the source map
        # its last line names beside it.
        if f.path.endswith("/flutter_js/flutter.js"):
            flutter_js_file = f
        if f.path.endswith("/flutter_js/flutter.js.map"):
            flutter_js_map = f

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
        use_local_canvaskit,
    )

    # Always supplied, in both states: a user bootstrap copied from upstream
    # references the name unconditionally, and `null` is what upstream
    # substitutes when no worker ships.
    worker_version = "\"%s\"" % SERVICE_WORKER_VERSION if ctx.attr.pwa else "null"
    shared_builtins = {
        "flutter_build_config": {"value": build_config},
        "flutter_service_worker_version": {"value": worker_version},
    }

    # Every path in the template config is a `file_ref`, which Bazel fills in
    # when it writes the config, path-mapped where the action is.
    template_refs = []
    template_inputs = [index_template, bootstrap_template]

    # A WebAssembly build's config also carries dart2wasm's own check of the
    # browser, as `_flutter.supportsDart2Wasm`, which flutter.js prefers to
    # its built-in one, as `flutter build web --wasm` writes it.
    if output_support_js:
        shared_builtins["flutter_build_config"] = {
            "value": build_config,
            "assign": {
                "target": "_flutter.supportsDart2Wasm",
                "file": file_ref(template_refs, output_support_js),
            },
        }
        template_inputs.append(output_support_js)
    if flutter_js_file:
        shared_builtins["flutter_js"] = {"file": file_ref(template_refs, flutter_js_file)}
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
                "template": file_ref(template_refs, bootstrap_template),
                "output": file_ref(template_refs, bootstrap_js),
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
                "template": file_ref(template_refs, index_template),
                "output": file_ref(template_refs, index_html),
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
                "template": file_ref(template_refs, bootstrap_template),
                "output": file_ref(template_refs, dev_bootstrap_js),
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
    template_args = ctx.actions.args()
    template_args.add(ctx.file._web_template_tool)
    template_args.add("--config")

    ctx.actions.run(
        executable = tools.dart,
        arguments = [template_args, json_config_args(ctx, template_config, template_refs)],
        inputs = depset(
            direct = template_inputs + [ctx.file._web_template_tool],
            transitive = [tools.sdk_files.run],
        ),
        outputs = [index_html, bootstrap_js] + ([dev_bootstrap_js] if dev_bootstrap_js else []),
        mnemonic = "FlutterWebTemplate",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Substituting web templates for %s" % ctx.label,
    )

    # Step 7: Assemble into output directory using the Dart bundler tool.
    output_dir = ctx.actions.declare_directory(ctx.label.name + "_web")

    # How the bundle is to be served, beside it rather than in it so it is not
    # deployed as a page asset. The dev tool's servers read it from the
    # directory they serve: `<bundle>.serving.json`.
    serving = ctx.actions.declare_file(output_dir.basename + ".serving.json")
    ctx.actions.write(serving, json.encode({
        "crossOriginEmbedderPolicy": ctx.attr.cross_origin_embedder_policy,
    }))

    # Build bundle config: each compile output has an explicit destination
    # entry (built where the outputs were declared), never a derived name.
    copies = []
    reserved = {}
    refs = []
    for copy in compile_copies:
        _reserve(reserved, copies, refs, copy["src"], copy["dst"])

    # The dart2js entrypoint reaches the bundle root inside a tree artifact, so
    # it is not in `copies` to reserve — but it is produced whenever dart2js
    # runs (as the primary output, or as the WASM build's fallback), so it can
    # be named. Reserved without a copy entry. A WASM-only bundle has no such
    # file, so a web asset of that name is the user's to ship.
    if dart2js_dirs:
        reserved["main.dart.js"] = "<dart2js output>"

    _reserve(reserved, copies, refs, index_html, "index.html")
    _reserve(reserved, copies, refs, bootstrap_js, "flutter_bootstrap.js")
    _reserve(reserved, copies, refs, manifest_json, "manifest.json")
    _reserve(reserved, copies, refs, version_json, "version.json")

    if service_worker_file:
        _reserve(reserved, copies, refs, service_worker_file, "flutter_service_worker.js")

    # Copy flutter.js from the web SDK.
    engine_inputs = []

    # An app of a custom SDK keeps the record of the checked pieces it was
    # built from, beside its assets.
    if sdk_record.record:
        _reserve(reserved, copies, refs, sdk_record.record, "assets/flutter_sdk.json")
        engine_inputs.append(sdk_record.record)
    if flutter_js_file:
        _reserve(reserved, copies, refs, flutter_js_file, "flutter.js")
        engine_inputs.append(flutter_js_file)

        # A browser's developer tools and error reporters ask for the source
        # map flutter.js names, which `flutter build web` ships beside it.
        if not flutter_js_map:
            fail("%s: the web SDK has flutter_js/flutter.js but not the flutter_js/flutter.js.map it names." % ctx.label)
        _reserve(reserved, copies, refs, flutter_js_map, "flutter.js.map")
        engine_inputs.append(flutter_js_map)

    # Copy the renderer engine files (canvaskit/*.wasm, *.js, etc.) something
    # loads. Two things can: the default loader fetches the renderer from
    # gstatic.com and never touches this directory, so a bundle carries its own
    # copy only when it is told to load it (`use_local_canvaskit`, which also
    # sets `useLocalCanvasKit` in the build config), and in a debug build,
    # whose dev loop renders with CanvasKit served from this directory.
    #
    # And only the renderers a build uses: the loader never falls from skwasm
    # to CanvasKit or back, so the other renderer's files are asked for by
    # nothing.
    #
    # The `.symbols` files are emscripten's function-name maps. flutter.js and
    # the renderers never fetch them, so they stay out of the deployable and
    # ride the `symbols` output group, linked into this target's own output
    # tree where a crash symbolizer can find them.
    ships_renderer = use_local_canvaskit or is_debug
    renderers = [b["renderer"] for b in builds]
    if is_debug:
        renderers.append("canvaskit")
    symbol_files = []
    for f in renderer_files:
        idx = f.path.find("/web-sdk/canvaskit/")
        if idx >= 0:
            sdk_rel = f.path[idx + len("/web-sdk/canvaskit/"):]
            if not renderer_file_needed(sdk_rel, renderers):
                continue
            if sdk_rel.endswith(".symbols"):
                symbol_file = ctx.actions.declare_file("%s_symbols/canvaskit/%s" % (ctx.label.name, sdk_rel))
                ctx.actions.symlink(output = symbol_file, target_file = f)
                symbol_files.append(symbol_file)
                continue
            if not ships_renderer:
                continue
            rel = "canvaskit/" + sdk_rel
            _reserve(reserved, copies, refs, f, rel)
            engine_inputs.append(f)

    # Copy user-provided web assets (favicon.png, icons/, etc.) to output root.
    # Strip the leading `web_dir` prefix if present (by default `web/`, matching
    # `flutter build web` behavior).
    #
    # Declared native modules ride the same list, so the served path of a module
    # is derived by the one piece of code that owns that mapping rather than
    # restated anywhere. That is also what keeps the declaration to a single
    # spelling: a module named in `native_modules` is served *because* it was
    # declared, and naming it in `web_assets` as well would reserve the same
    # destination twice.
    web_asset_files = []
    native_module_files = [
        f
        for dep in ctx.attr.native_modules
        for f in dep[FlutterNativeLibraryInfo].libraries.to_list()
    ]
    for f in ctx.files.web_assets + native_module_files:
        rel = f.short_path

        # Strip package prefix to get workspace-relative path.
        if rel.startswith(ctx.label.package + "/"):
            rel = rel[len(ctx.label.package) + 1:]

        # Strip the leading web directory (convention: files live in web/).
        if rel.startswith(web_dir + "/"):
            rel = rel[len(web_dir) + 1:]
        _check_web_asset_dst(ctx, reserved, rel, f.short_path)
        copies.append({"src": file_ref(refs, f), "dst": rel})
        web_asset_files.append(f)

    # What each declared module's bindings were generated from. Keyed by File so
    # the dev config can key by the same path the module list carries.
    native_module_contracts = {}
    for dep in ctx.attr.native_modules:
        info = dep[FlutterNativeLibraryInfo]
        contracts = info.binding_contract.to_list()
        for f in info.libraries.to_list():
            native_module_contracts[f] = contracts

    # dart2js outputs are directories (tree artifacts) to support deferred
    # loading — dart2js may produce main.dart.js + *.part.js files.
    # Copy entire directory contents into the output root.
    copy_dirs = [{"src": file_ref(refs, flutter_assets), "dst": "assets"}]
    for d in dart2js_dirs:
        copy_dirs.append({
            "src": file_ref(refs, d),
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
            #
            # The recorded uses are the link hooks' input, lifted out of the
            # tree before them; `flutter build web` keeps them out of its
            # output too.
            "exclude": ["*.deps", "*.info.json", "main.dart.js.resources.json"],
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
            "src": file_ref(refs, dart2js_dirs[0]) + "/main.dart.js.info.json",
            "dst": file_ref(refs, dump_info_file),
        })

    config = {
        "output_dir": file_ref(refs, output_dir),
        "copies": copies,
        "copy_dirs": copy_dirs,
        "extracts": extracts,
    }

    all_inputs = compile_outputs + dart2js_dirs + engine_inputs + web_asset_files + [flutter_assets, index_html, bootstrap_js, manifest_json, version_json]
    if service_worker_file:
        all_inputs.append(service_worker_file)

    bundle_args = ctx.actions.args()
    bundle_args.add(ctx.file._bundle_tool)
    bundle_args.add("--config")

    ctx.actions.run(
        executable = tools.dart,
        arguments = [bundle_args, json_config_args(ctx, config, refs)],
        inputs = depset(
            direct = all_inputs + [ctx.file._bundle_tool] + ctx.files._bundle_tool_imports,
            transitive = [tools.sdk_files.run],
        ),
        outputs = [output_dir] + ([dump_info_file] if dump_info_file else []),
        mnemonic = "FlutterWebBundle",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Bundling Flutter web app %s" % ctx.label,
    )

    # The dump-info JSON is an analysis artifact, not something a deployment
    # needs, so it rides an output group rather than the default outputs:
    # `bazel build //your:app --output_groups=dump_info`. Empty when the attr
    # is off, so the group always exists and always says the truth.
    output_groups = OutputGroupInfo(**(import_checks | dict(
        dump_info = depset([dump_info_file] if dump_info_file else []),
        # The renderers' symbol maps, for the engine this bundle runs.
        symbols = depset(symbol_files),
        _validation = depset(linked.validation_outputs + version_checks, transitive = [import_checks["_validation"]]),
    )))

    # What lets rules_dart's analysis check a web app: its `main` and `srcs`,
    # and the sources of what `unchecked_srcs` staged copies of (an
    # integration test's support library). Deliberately not offered as a
    # `DartInfo`: `deps` requires one, and an application bundle is not a
    # dependency.
    analyzable_info = program_analyzable_info(
        ctx,
        program.package,
        package_root,
        primary.deps,
        [main] + program.srcs + program.staged_sources,
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

        # Dev config JSON with engine revision, version, and host tool paths.
        # The dart-sdk root is derived from the module loader path:
        # .../dart-sdk/lib/dev_compiler/ddc/ddc_module_loader.js → .../dart-sdk
        module_loader = ctx.file._ddc_module_loader_js
        dart_sdk_root = dev_source_dir(module_loader, module_loader.path.rsplit("/lib/", 1)[0])
        platform_dill = flutter_sdk_info.platform_kernel_dill

        # The synthetic-main entrypoint the dev tool imports: the `main`'s
        # `package:` URI, backed by the record `synthesize_app_package` wrote
        # above, or — for a `main` outside the package's `lib/`, which
        # `flutter run -t` allows — its app-scheme URI, which the dev loop
        # resolves through the root `dev_filesystem_roots` carries for it.
        #
        # Never a URI derived any other way. An earlier version fabricated
        # `package:<name>/main.dart` for a `main` it could not place, which
        # named some other app's entrypoint whenever the workspace root held
        # one, and the dev loop booted that program with nothing reporting a
        # mismatch.
        app_entrypoint = app_main_location(program.package_name, package_root, main).uri

        # Declares every build output the config names; see `dev_config.bzl`.
        ddc_files.extend(write_dev_config(ctx, ctx.actions.declare_file(ctx.label.name + "_dev_config.json"), {
            "engineRevision": flutter_sdk_info.engine_revision,
            "flutterVersion": flutter_sdk_info.version,
            "dartSdkRoot": dart_sdk_root,
            "dartaotruntime": flutter_sdk_info.dartaotruntime,
            "frontendServer": flutter_sdk_info.frontend_server,
            "patchedSdkRoot": dev_source_dir(platform_dill, platform_dill.dirname),
            "appEntrypoint": app_entrypoint,
            # The generated web plugin registrant (`registerPlugins()`). The
            # bundled build reaches it through the wrapper main's relative
            # import; DDC dev mode builds its own synthetic entrypoint, so the
            # dev tool needs the path named explicitly — it stages the file
            # beside that entrypoint and imports it the same way. Empty when
            # the app has no web plugins.
            "webPluginRegistrant": registrant or "",
            # The staged AI-agent service extensions. Same staging contract as
            # `webPluginRegistrant`: the build names the file, the dev tool
            # copies it beside its synthetic entrypoint and imports it. Always
            # present in this branch — a dbg web run is a dev-loop run.
            "agentExtensions": staged_agent,
            # The bootstrap the dev server answers `/flutter_bootstrap.js`
            # with: this target's template, substituted with the DDC build
            # config the dev loop runs under. Named here rather than found by
            # suffix because it is one file per target, and a run that served
            # another target's would boot the wrong app.
            "flutterBootstrapJs": dev_bootstrap_js,
            # Merged user defines (attr + extra_dart_defines flag) and the
            # flavor's. The dev tool replays these as -D on its resident
            # frontend_server so
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
            "devPackageConfig": dev_config_file(dev_package_config, dev_package_config_names),
            # The BUILD package_config, for the one consumer that needs file
            # paths rather than live sources: DWDS, which reads a `package:`
            # URI's source off disk to show it in the debugger.
            #
            # Named separately from `devPackageConfig` because the two are not
            # interchangeable and only the call site knows which it wants. A
            # source-assembled package's dev `rootUri` is
            # `<filesystemScheme>:///<package_root>`, which the frontend_server
            # resolves through `--filesystem-root` but `Uri.toFilePath()`
            # cannot: DWDS asked through it gets "Cannot extract a file path
            # from a org-dartlang-app URI" and shows no source at all. This
            # one's rootUris are ordinary relative paths, so they resolve.
            "buildPackageConfig": dev_config_file(ddc.config_file, ddc.compile_srcs),
            "filesystemRoots": dev_search_roots(dev_filesystem_roots),
            "filesystemScheme": dev_filesystem_scheme,
            "generatedSourcePaths": dev_generated_sources,
            "generatedSourceUris": dev_generated_source_uris,
            # See flutter_application's dev config.
            "shaders": shader_sources(ctx, primary.deps, "web", program),
            "assetRoots": asset_roots(ctx, primary.deps, program),
            # The native modules the page instantiates, and per module the files
            # its bindings were generated from. A reload cannot replace an
            # instantiated module any more than a process can replace a `dlopen`ed
            # image, so the dev tool compares these the same way — see
            # `NativeLibsWatch`. The built file rather than its served copy: the
            # copy derives from it, and this is the path the rebuild rewrites.
            #
            # Declared, never inferred. This directory also holds Flutter's own
            # `main.dart.wasm`, which changes on every Dart edit, so a watch that
            # recognised a module by extension would flag every reload.
            "nativeLibs": native_module_files,
            "nativeLibContracts": {
                f.path: contracts
                for f, contracts in native_module_contracts.items()
            },
            # First-party source packages (app + local deps) the dev tool maps
            # live edits back to via its SourceUriResolver. packageRoot is
            # workspace-relative.
            "sourcePackages": [
                {"name": sp[0], "packageRoot": sp[1]}
                for sp in dev_source_packages
            ],
            # The sources outside every package the app compiles under the app
            # scheme — a `main` outside its package's `lib/` and the `srcs`
            # beside it — with the URI the compiler keys each by. Empty for a
            # `main` with a `package:` URI.
            "appSources": app_scheme_sources(
                program.package_name,
                package_root,
                main,
                program.srcs,
            ),
        }))

        return [DefaultInfo(files = depset([output_dir, serving] + ddc_files)), output_groups, analyzable_info]

    return [DefaultInfo(files = depset([output_dir, serving])), output_groups, analyzable_info]

# The tools and build settings an application carries, which the bundle
# needs for itself to compile and bundle the application's program: what the
# program is (its `main`, `deps`, assets, defines and the rest) is the
# application's, read off `branches`.
#
# The program once per compiler: `branches` is the staging target the bundle
# macro declares beside the bundle with its `application`, split on each
# compiler's web platform, so each branch is one configuration of the program
# and of the staging (package config, co-located sources) it compiles from.
_WEB_APPLICATION_ATTRS = FLUTTER_APPLICATION_TOOL_ATTRS | {
    "branches": attr.label(
        doc = "The staging target `flutter_web_bundle` declares beside the bundle. Set by that macro; not for BUILD files.",
        cfg = web_branches,
        providers = [FlutterWebBranchInfo],
        mandatory = True,
    ),
}

flutter_web_bundle = rule(
    implementation = _flutter_web_bundle_impl,
    attrs = dict(_WEB_APPLICATION_ATTRS | WEB_PLATFORM_ATTRS | program_assets_attrs(), **{
        "compiler": attr.string(
            doc = "Web compiler: 'dart2wasm' (default) or 'dart2js'. 'dart2wasm' " +
                  "builds WebAssembly, and by default a dart2js build beside it " +
                  "(`js_fallback`) for browsers that cannot run it. JavaScript is " +
                  "otherwise for the dev loop only, which compiles with DDC whatever " +
                  "this says, unless `js_fallback = False` ships no JavaScript: " +
                  "`flutter_bazel run` then develops the app under dart2wasm.",
            default = "dart2wasm",
            values = ["dart2wasm", "dart2js"],
        ),
        "js_fallback": attr.bool(
            doc = "Whether `compiler = \"dart2wasm\"` also compiles with dart2js and " +
                  "ships `main.dart.js` beside the WASM build. True (default), as " +
                  "`flutter build web --wasm` does: the bootstrap lists both builds and " +
                  "Flutter's loader picks the first the browser can run, WASM where the " +
                  "browser has WasmGC (and, for skwasm, is allowed to use it: Chromium " +
                  "by default, see `wasm_browsers`), the CanvasKit JavaScript build " +
                  "elsewhere. False makes the bundle WebAssembly only: no dart2js " +
                  "compile runs, so code only WebAssembly supports (an `Int64List`, the " +
                  "largest 64-bit integer literal) builds, and the compile work is " +
                  "halved, but a browser that cannot run the WASM build gets a message " +
                  "instead of the app (the loader logs `no compatible build found` and " +
                  "throws). With True the app must compile under dart2js too, which " +
                  "code that differs by compiler can: a library in `deps` picks its " +
                  "dependency with a `select()` on `@rules_dart//dart/constraints:js` " +
                  "or `:wasm`, " +
                  "so dart2js can take a variant without the 64-bit type and keep the " +
                  "fallback. False " +
                  "is what makes `optimization_level_js`, `minify_js`, " +
                  "`frequency_based_minification` and `dump_info` refused, since " +
                  "nothing would run them. `flutter_bazel run -d chrome` runs such a " +
                  "bundle under dart2wasm, with no hot reload, rather than under DDC " +
                  "(JavaScript), unless told `--no-wasm`. Setting it False with `compiler = " +
                  "\"dart2js\"` is refused: that is JavaScript alone already.",
            default = True,
        ),
        "renderer": attr.string(
            doc = "Web renderer: 'skwasm' or 'canvaskit'. Unset, it follows " +
                  "`compiler`: skwasm for dart2wasm, canvaskit for dart2js.",
            default = "",
            values = ["", "skwasm", "canvaskit"],
        ),
        "wasm_browsers": attr.string_list(
            doc = "The browser engines allowed to run the WASM build with the skwasm " +
                  "renderer, set as flutter.js's `wasmAllowList` in the generated " +
                  "`flutter_bootstrap.js`. Engines are `blink` (Chrome, Edge), `gecko` " +
                  "(Firefox), `webkit` (Safari) and `unknown`; exactly those named are " +
                  "allowed and the rest are refused. Unset (default) is Flutter's own " +
                  "default, which today allows `blink` only. The browser must also " +
                  "support WasmGC. CONSEQUENCE: an engine the loader refuses, or a " +
                  "browser without WasmGC, runs the `js_fallback` build (the default); " +
                  "with `js_fallback = False` there is nothing else to run, and the " +
                  "generated bootstrap shows a message instead of the app (the loader " +
                  "also logs `no compatible build found` and throws). So naming `gecko` " +
                  "and `webkit` serves Firefox and Safari WebAssembly instead of the " +
                  "JS build or a message, on your judgement of their skwasm support; " +
                  "leaving them out serves them the JS build, or the message. It " +
                  "applies only to a skwasm build, so it is refused with `compiler = " +
                  "\"dart2js\"` or `renderer = \"canvaskit\"`, and with a `bootstrap_js` " +
                  "of your own: that file calls `_flutter.loader.load` itself, so pass " +
                  "`config: {wasmAllowList: {...}}` there.",
            default = [],
        ),
        "title": attr.string(
            doc = "HTML page title. Only used when index_html is not provided.",
        ),
        "cross_origin_embedder_policy": attr.string(
            doc = "The `Cross-Origin-Embedder-Policy` `flutter_bazel run` " +
                  "serves the app with when it cross-origin-isolates the page " +
                  "(a WASM run, by default), so skwasm can use threads. " +
                  "`require-corp` (default) isolates the page in every " +
                  "browser, Safari included, and blocks a cross-origin " +
                  "subresource that sends no CORP or CORS headers. " +
                  "`credentialless` loads such subresources without " +
                  "credentials instead, but Safari does not isolate a page " +
                  "under it, so skwasm runs single-threaded there. Serve the " +
                  "deployed app with the same value.",
            default = "require-corp",
            values = ["require-corp", "credentialless"],
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
                  "Applies to a `compiler = \"dart2js\"` target, and to a dart2wasm one with " +
                  "`js_fallback` on; with `js_fallback = False` it is refused rather " +
                  "than ignored. Note upstream's single `--optimization-level` sets " +
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
                  "leaves the dart2js fallback, if any, on its own default — upstream's single " +
                  "`--optimization-level` reaches both compilers, this attr reaches one.",
            default = "auto",
            values = ["auto", "0", "1", "2", "3", "4"],
        ),
        "minify_js": attr.string(
            doc = "Whether the dart2js output minifies names, matching " +
                  "`flutter build web --minify-js`. \"auto\" (default) minifies in release " +
                  "and not in debug or profile, as upstream does; \"true\" and \"false\" state " +
                  "it outright and hold across every build mode. Applies to a " +
                  "`compiler = \"dart2js\"` target, and to a dart2wasm one with " +
                  "`js_fallback` on; with `js_fallback = False` it is refused. Always passed " +
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
                  "compile of a `compiler = \"dart2js\"` target, or of a dart2wasm one with " +
                  "`js_fallback` on; a WASM-only bundle has no such compile, so there it " +
                  "reaches the dev loop alone. The DDC dev loop applies these checks too, and " +
                  "reads this value from the build's dev config, so the two agree.",
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
                  "under `compiler = \"dart2wasm\"` it describes the `js_fallback` build — " +
                  "not the WASM build most visitors run — and with `js_fallback = False` " +
                  "there is nothing to describe, so it is refused.",
            default = False,
        ),
        "enable_experiments": attr.string_list(
            doc = "Dart language experiments to enable, by name and without the flag " +
                  "(e.g. [\"records\"]), matching `flutter build web --enable-experiment`. " +
                  "Reaches every web compiler the target runs and the kernel compile the " +
                  "icon tree-shaker reads, since an experiment changes how the source parses and every step " +
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
                  "names to choose, so this does nothing alongside `minify_js = \"false\"`. " +
                  "Refused under `compiler = \"dart2wasm\"` with `js_fallback = False`, " +
                  "which runs no dart2js.",
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
        "native_modules": attr.label_list(
            doc = """Native modules the page instantiates, each declaring what its bindings were generated from.

Each entry is a `flutter_native_library` wrapping a `.wasm` module. The module is
served from the bundle exactly as a `web_assets` entry is — same destination
derivation, so do not list it in both — and its contract is what lets a hot
reload tell an edit the instantiated module can still serve from one it cannot.

Declared rather than detected, and that is the point: the bundle also holds
Flutter's own `main.dart.wasm`, which changes on every Dart edit. Nothing but the
build knows which served file is a native module.
""",
            providers = [FlutterNativeLibraryInfo],
        ),
        "web_assets": attr.label_list(
            doc = "Static web files (favicon.png, icons/, etc.) copied to the output root. " +
                  "Paths are preserved relative to the package, with a leading `web_dir` " +
                  "stripped (e.g. web/favicon.png → favicon.png, web/icons/icon-192.png → icons/icon-192.png). " +
                  "Typically: glob([\"web/**\"]).",
            allow_files = True,
        ),
        "web_dir": attr.string(
            doc = "The package directory whose contents are served at the bundle root: a " +
                  "`web_assets` entry under it loses this prefix, and any other keeps its " +
                  "package-relative path. Defaults to `web`, as `flutter build web` uses. Set " +
                  "it to build several web apps from one package, each with its own page, " +
                  "manifest and icons (e.g. `web_apps/reminders`).",
            default = "web",
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
                  "the application's package name, `build_name` and `build_number`. If set, its " +
                  "`version` and `build_number` must be the application's (`1.0.0` and `1` when it " +
                  "sets none), which the program reports, or the build fails. The web `package_info_plus` " +
                  "plugin (and similar PackageInfo-style web plugins) reads this file to populate " +
                  "appName/version/buildNumber/packageName at runtime.",
            allow_single_file = [".json"],
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
                  "this.\n\n" +
                  "This is what puts the renderer in the bundle: the default loader " +
                  "fetches it from gstatic.com and nothing reads the local copy, so " +
                  "without this the bundle has no `canvaskit/` directory (a debug " +
                  "build excepted: the dev loop renders with CanvasKit served from " +
                  "it). With it, `canvaskit/` holds only the files this bundle's " +
                  "renderers load, `skwasm*` and `wimp*` for skwasm and `canvaskit.*`, " +
                  "`chromium/` and `webparagraph/` for CanvasKit, because flutter.js " +
                  "never falls back from one renderer to the other. The `.symbols` " +
                  "files beside them are never fetched, so they are not shipped; " +
                  "`bazel build //your:app --output_groups=symbols` links them under " +
                  "`<name>_symbols/canvaskit/` for crash symbolization.\n\n" +
                  "It is also how a `bootstrap_js` of your own asks for the local " +
                  "renderer. A bootstrap that sets `canvasKitBaseUrl` to the bundle's " +
                  "`canvaskit/` must set this too, or the directory is not there to " +
                  "load. One attribute rather than two: \"this bundle serves its own " +
                  "renderer\" is a single fact, it already puts `useLocalCanvasKit` in " +
                  "the build config the bootstrap reads, and a second attribute could " +
                  "disagree with the files it is meant to ship.\n\n" +
                  "Required to serve under a Content Security Policy: the renderer is a " +
                  "script, so `script-src 'self'` blocks it from the CDN and the app never " +
                  "boots. Note the guarantee stops at `script-src` — the framework still " +
                  "fetches fonts from fonts.gstatic.com, so a `default-src 'self'` policy " +
                  "needs that origin allowed (or the fonts bundled) whatever this is set to.",
            default = False,
        ),
        "_wasm_opt_cpus": attr.label(default = Label("//flutter:wasm_opt_cpus")),
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
            default = Label("@flutter_web_sdk//:web-sdk/kernel/ddc/canary/dart_sdk.js"),
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
        "_sdk_record": attr.label(
            default = Label("//flutter/private:web_sdk_record"),
            providers = [FlutterSdkRecordInfo],
        ),
        "_bundle_tool": attr.label(
            default = Label("//flutter/private/tools:bundle_app.dart"),
            allow_single_file = [".dart"],
        ),
        "_bundle_tool_imports": attr.label(
            default = Label("//flutter/private/tools:bundle_app_imports"),
        ),
        "_web_template_tool": attr.label(
            default = Label("//flutter/private/tools:web_template.dart"),
            allow_single_file = [".dart"],
        ),
        "_check_version_json_tool": attr.label(
            default = Label("//flutter/private/tools:check_web_version_json.dart"),
            allow_single_file = [".dart"],
        ),
        "_agent_web_bridge_src": attr.label(
            doc = "Serves the agent extensions from a debug bundle, which has no VM service: the wrapper main publishes them for the dev tool to call over the browser's DevTools protocol.",
            default = Label("//flutter/private/dev_tool_support:web_bridge.dart"),
            allow_single_file = [".dart"],
        ),
    }),
    toolchains = ["@rules_flutter//flutter:toolchain_type"] + PROGRAM_ASSETS_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = ["cpp"],
    doc = "Builds a Flutter web application (WASM or JS) with all deployment artifacts. Declared through the `flutter_web_bundle` macro in `web.bzl`, which adds the staging target `branches` names.",
)
