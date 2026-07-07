"""Flutter web application build.

Produces a deployable web directory containing:
- main.dart.wasm + main.dart.mjs + main.dart.js (WASM mode with JS fallback)
  or main.dart.js (JS-only mode)
- flutter.js (Flutter engine bootstrapper from web SDK)
- canvaskit/ or skwasm/ (renderer engine artifacts)
- flutter_assets/ (AssetManifest.bin.json for web)
- index.html
- flutter_bootstrap.js
- flutter_service_worker.js (optional, for PWA offline support)

When compiler="dart2wasm", both WASM and JS outputs are produced. The
bootstrap JS lists both builds so the Flutter engine tries WASM first and
falls back to JS on browsers without WASM support (matching `flutter build web`).

Both dart2wasm and dart2js take .dart source directly (not kernel .dill),
so we skip the frontend_server kernel compilation step used by desktop/mobile.
"""

load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "collect_packages", "collect_transitive_srcs", "generate_dev_package_config")
load("//flutter:providers.bzl", "FlutterInfo")
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_main_package_uri",
    "compile_package_config",
    "resolve_wrapper_main_import",
    "synthesize_app_package",
)
load(
    "//flutter/private:common.bzl",
    "FLUTTER_APPLICATION_ATTRS",
    "flutter_build_assets",
    "flutter_compile_shaders",
    "make_web_wrapper_main_content",
    "merge_dart_defines",
)
load("//flutter/private:flutter_compile.bzl", "flutter_kernel_compile_action")
load("//flutter/private:flutter_library.bzl", "dedup_plugins")
load("//flutter/private:flutter_web_compile.bzl", "flutter_dart2js_action", "flutter_dart2wasm_action")
load("//flutter/private:plugin_registrant.bzl", "generate_dart_plugin_registrant")
load("//flutter/private:validation.bzl", "escape_html", "validate_web_compiler_renderer")

_INDEX_HTML_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
  <base href="{base_href}">
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
{service_worker_script}</body>
</html>
"""

_SERVICE_WORKER_REGISTRATION = """\
  <script>
    if ("serviceWorker" in navigator) {
      window.addEventListener("load", function() {
        navigator.serviceWorker.register("flutter_service_worker.js");
      });
    }
  </script>
"""

_SERVICE_WORKER_JS_TEMPLATE = """\
'use strict';
const CACHE_NAME = 'flutter-app-cache-{cache_hash}';
const RESOURCES = {{
{resource_entries}
}};

self.addEventListener('install', function(event) {{
  event.waitUntil(
    caches.open(CACHE_NAME).then(function(cache) {{
      return cache.addAll(Object.keys(RESOURCES));
    }})
  );
}});

self.addEventListener('activate', function(event) {{
  event.waitUntil(
    caches.keys().then(function(cacheNames) {{
      return Promise.all(
        cacheNames
          .filter(function(name) {{ return name !== CACHE_NAME; }})
          .map(function(name) {{ return caches.delete(name); }})
      );
    }})
  );
}});

self.addEventListener('fetch', function(event) {{
  event.respondWith(
    caches.match(event.request).then(function(response) {{
      return response || fetch(event.request);
    }})
  );
}});
"""

_BOOTSTRAP_JS_TEMPLATE = """{{
  let buildConfig = {{
    engineRevision: "{engine_revision}",
    builds: [
      {build_entry}
    ]{extra_config}
  }};
  if (!window._flutter) {{ window._flutter = {{}}; }}
  window._flutter.buildConfig = buildConfig;
  let script = document.createElement("script");
  script.src = "flutter.js";
  script.addEventListener("load", function() {{
    _flutter.loader.load();
  }});
  document.head.appendChild(script);
}}
"""

_WASM_BUILD_ENTRY = """{{
        compileTarget: "dart2wasm",
        renderer: "{renderer}",
        mainWasmPath: "main.dart.wasm",
        jsSupportRuntimePath: "main.dart.mjs"
      }}"""

_JS_BUILD_ENTRY = """{
        compileTarget: "dart2js",
        renderer: "canvaskit",
        mainJsPath: "main.dart.js"
      }"""

_DUAL_BUILD_ENTRIES = """{wasm_entry},
      {js_entry}"""

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

def _flutter_web_bundle_impl(ctx):
    validate_web_compiler_renderer(ctx.attr.compiler, ctx.attr.renderer)

    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    # Merged once for all compile actions below (dart2wasm, dart2js, icon
    # tree-shake kernel) and the dev-config emission.
    user_defines = merge_dart_defines(ctx)

    # Step 1: Collect sources, generate package config, handle plugin registrant.
    # dart compile wasm/js take .dart source directly (not kernel .dill).
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list()
    packages = collect_packages(ctx.attr.deps)

    # Register the app's own package (when declared) so `package:<name>/main.dart`
    # is a valid URI for the wrapper to import. Include `main` in the colocate
    # inputs so it ends up inside the same assembled directory as its lib/
    # siblings — that's what lets `main.dart`'s relative imports resolve to
    # the assembled (codegen-co-located) copies of its package siblings.
    packages = synthesize_app_package(packages, ctx.attr.package_name)

    # Hot-reload dev metadata (debug only): a multi-root dev package_config so a
    # source-assembled (codegen) app resolves package: URIs across the live
    # source tree + generated bazel-out roots, instead of the frozen assembled
    # `.pkgsrcs` dir the build config uses. Computed pre-colocation (lib_root +
    # File.is_source intact). See rules_dart generate_dev_package_config.
    web_is_debug = ctx.var["COMPILATION_MODE"] == "dbg"
    dev_package_config = None
    dev_filesystem_roots = []
    dev_filesystem_scheme = ""
    dev_generated_source_paths = []
    dev_generated_source_uris = []
    dev_source_packages = []
    if web_is_debug:
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
        resolve_wrapper_main_import(ctx.attr.package_name, ctx.file.main.path, wrapper_depth),
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
    compile_outputs = []  # Files (wasm, mjs)
    dart2js_dirs = []  # Tree artifacts from dart2js
    extra_config = ",\n    useLocalCanvasKit: true" if ctx.attr.use_local_canvaskit else ""
    if ctx.attr.compiler == "dart2wasm":
        # Primary: dart2wasm
        output_wasm = ctx.actions.declare_file(ctx.label.name + ".wasm")
        output_mjs = ctx.actions.declare_file(ctx.label.name + ".mjs")
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
            optimization_level = ctx.attr.optimization_level,
            source_maps = ctx.attr.source_maps,
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
            optimization_level = ctx.attr.optimization_level,
            source_maps = ctx.attr.source_maps,
            defines = user_defines,
            renderer = "canvaskit",
        )
        compile_outputs = [output_wasm, output_mjs]
        dart2js_dirs = [output_js_fallback_dir]
        bootstrap_content = _BOOTSTRAP_JS_TEMPLATE.format(
            engine_revision = flutter_sdk_info.engine_revision,
            build_entry = _DUAL_BUILD_ENTRIES.format(
                wasm_entry = _WASM_BUILD_ENTRY.format(renderer = ctx.attr.renderer),
                js_entry = _JS_BUILD_ENTRY,
            ),
            extra_config = extra_config,
        )
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
            optimization_level = ctx.attr.optimization_level,
            source_maps = ctx.attr.source_maps,
            defines = user_defines,
            renderer = ctx.attr.renderer,
        )
        dart2js_dirs = [output_js_dir]
        bootstrap_content = _BOOTSTRAP_JS_TEMPLATE.format(
            engine_revision = flutter_sdk_info.engine_revision,
            build_entry = _JS_BUILD_ENTRY,
            extra_config = extra_config,
        )

    # Step 3: Shader compilation + asset bundle.
    compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, "web")

    # Icon tree shaking: compile a kernel .dill for const_finder analysis.
    # Web targets don't otherwise need a kernel (they use dart2wasm/dart2js),
    # so we compile one specifically for const_finder to analyze IconData constants.
    is_debug = ctx.var["COMPILATION_MODE"] == "dbg"
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
            entrypoint_uri = app_main_package_uri(ctx.attr.package_name, ctx.file.main.path),
            srcs = all_srcs,
            package_config = config_file,
            output = kernel_dill,
            aot = True,
            defines = list(user_defines) + ["dart.vm.product=true"],
        )

    flutter_assets = flutter_build_assets(ctx, flutter_sdk_info, compiled_shaders, kernel_dill = kernel_dill, is_debug = is_debug)

    # Step 4: Generate index.html and bootstrap JS.
    # If a user-provided index.html is given, use it directly.
    # Otherwise, generate from the embedded template.
    if ctx.file.index_html:
        index_html = ctx.file.index_html
    else:
        title = ctx.attr.title or ctx.label.name
        safe_title = escape_html(title)

        # Determine service worker registration snippet for index.html.
        if ctx.attr.pwa:
            service_worker_script = _SERVICE_WORKER_REGISTRATION
        else:
            service_worker_script = ""

        index_html = ctx.actions.declare_file(ctx.label.name + "_index.html")
        ctx.actions.write(index_html, _INDEX_HTML_TEMPLATE.format(
            title = safe_title,
            base_href = ctx.attr.base_href,
            service_worker_script = service_worker_script,
        ))

    bootstrap_js = ctx.actions.declare_file(ctx.label.name + "_flutter_bootstrap.js")
    ctx.actions.write(bootstrap_js, bootstrap_content)

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
    service_worker_file = None
    if ctx.attr.pwa:
        # Build resource list: compile outputs + index.html + bootstrap JS.
        # Note: dart2js deferred .part.js files are loaded dynamically and
        # should be cached by the service worker, but we can't enumerate them
        # statically. The main.dart.js is always present; part files are
        # loaded on demand and will be fetched normally (cache miss → network).
        resource_names = ["/"]
        for f in compile_outputs:
            ext = f.path.split(".")[-1]
            resource_names.append("main.dart.%s" % ext)
        resource_names.append("main.dart.js")  # Always present in dart2js output dir
        resource_names.append("index.html")
        resource_names.append("flutter_bootstrap.js")
        resource_names.append("flutter.js")
        resource_names.append("assets/AssetManifest.bin.json")

        resource_entries = ",\n".join([
            '  "%s": true' % name
            for name in resource_names
        ])

        # Compute a hash of resource names so the cache name changes on each build.
        cache_hash = str(hash(",".join(sorted(resource_names))))

        service_worker_file = ctx.actions.declare_file(ctx.label.name + "_flutter_service_worker.js")
        ctx.actions.write(service_worker_file, _SERVICE_WORKER_JS_TEMPLATE.format(
            resource_entries = resource_entries,
            cache_hash = cache_hash,
        ))

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

    # Step 7: Assemble into output directory using the Dart bundler tool.
    output_dir = ctx.actions.declare_directory(ctx.label.name + "_web")

    # Build bundle config: copy compile outputs renamed to main.dart.{ext}.
    copies = []
    for f in compile_outputs:
        ext = f.path.split(".")[-1]
        copies.append({"src": f.path, "dst": "main.dart.%s" % ext})

    copies.append({"src": index_html.path, "dst": "index.html"})
    copies.append({"src": bootstrap_js.path, "dst": "flutter_bootstrap.js"})
    copies.append({"src": manifest_json.path, "dst": "manifest.json"})
    copies.append({"src": version_json.path, "dst": "version.json"})

    if service_worker_file:
        copies.append({"src": service_worker_file.path, "dst": "flutter_service_worker.js"})

    # Copy flutter.js from the web SDK.
    engine_inputs = []
    if flutter_js_file:
        copies.append({"src": flutter_js_file.path, "dst": "flutter.js"})
        engine_inputs.append(flutter_js_file)

    # Copy renderer engine files (canvaskit/*.wasm, *.js, etc.).
    for f in renderer_files:
        idx = f.path.find("/web-sdk/canvaskit/")
        if idx >= 0:
            rel = "canvaskit/" + f.path[idx + len("/web-sdk/canvaskit/"):]
            copies.append({"src": f.path, "dst": rel})
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
        copies.append({"src": f.path, "dst": rel})
        web_asset_files.append(f)

    # dart2js outputs are directories (tree artifacts) to support deferred
    # loading — dart2js may produce main.dart.js + *.part.js files.
    # Copy entire directory contents into the output root.
    copy_dirs = [{"src": flutter_assets.path, "dst": "assets"}]
    for d in dart2js_dirs:
        copy_dirs.append({"src": d.path, "dst": "."})

    config = {
        "output_dir": output_dir.path,
        "copies": copies,
        "copy_dirs": copy_dirs,
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
        outputs = [output_dir],
        mnemonic = "FlutterWebBundle",
        progress_message = "Bundling Flutter web app %s" % ctx.label,
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
        dart_sdk_root = ctx.file._ddc_module_loader_js.path.rsplit("/lib/", 1)[0]

        # Compute the synthetic-main entrypoint as a `package:` URI: main
        # at <pkg>/lib/main.dart → package:<name>/main.dart.
        main_rel = ctx.file.main.short_path
        pkg_prefix = ctx.label.package + "/lib/"
        if main_rel.startswith(pkg_prefix):
            app_entrypoint = "package:%s/%s" % (
                ctx.attr.package_name,
                main_rel[len(pkg_prefix):],
            )
        else:
            app_entrypoint = "package:%s/main.dart" % ctx.attr.package_name

        dev_config_content = json.encode({
            "engineRevision": flutter_sdk_info.engine_revision,
            "flutterVersion": flutter_sdk_info.version,
            "dartSdkRoot": dart_sdk_root,
            "dartaotruntime": flutter_sdk_info.dartaotruntime.path,
            "frontendServer": flutter_sdk_info.frontend_server.path,
            "patchedSdkRoot": flutter_sdk_info.platform_kernel_dill.path.rsplit("/", 1)[0],
            "appEntrypoint": app_entrypoint,
            # Merged user defines (attr + extra_dart_defines flag). The dev
            # tool replays these as -D on its resident frontend_server so
            # hot reload/restart recompiles keep the same environment.
            "dartDefines": user_defines,
            # Codegen hot-reload: dev package_config + multi-root layout +
            # generated source paths/URIs (empty for non-codegen apps).
            "devPackageConfig": dev_package_config.path if dev_package_config else "",
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

        return [DefaultInfo(files = depset([output_dir] + ddc_files))]

    return [DefaultInfo(files = depset([output_dir]))]

# Cherry-pick only web-relevant attrs from FLUTTER_APPLICATION_ATTRS.
# Web builds don't use native_deps, obfuscate, split_debug_info,
# extra_gen_snapshot_options, profile, or min_os_version.
_WEB_RELEVANT_KEYS = (
    "main",
    "package_name",
    "srcs",
    "deps",
    "assets",
    "defines",
    "_extra_dart_defines",
    "shaders",
    "tree_shake_icons",
    "license_files",
    "track_widget_creation",
    "_asset_bundle_tool",
)
_WEB_APPLICATION_ATTRS = {k: v for k, v in FLUTTER_APPLICATION_ATTRS.items() if k in _WEB_RELEVANT_KEYS}

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
            doc = "Base URL path for the app (default: '/'). Used in <base href> tag. " +
                  "Only used when index_html is not provided.",
            default = "/",
        ),
        "optimization_level": attr.int(
            doc = "Optimization level for dart2wasm/dart2js (-O flag). Range: 0-4.",
            default = 2,
            values = [0, 1, 2, 3, 4],
        ),
        "source_maps": attr.bool(
            doc = "If True, generate source maps alongside compiled output.",
            default = False,
        ),
        "web_assets": attr.label_list(
            doc = "Static web files (favicon.png, icons/, etc.) copied to the output root. " +
                  "Paths are preserved relative to the package (e.g. web/favicon.png → favicon.png, web/icons/icon-192.png → icons/icon-192.png). " +
                  "Typically: glob([\"web/**\"]).",
            allow_files = True,
        ),
        "index_html": attr.label(
            doc = "User-provided index.html file, copied verbatim into the bundle. When set, " +
                  "title and base_href are ignored (they only affect the generated template). " +
                  "If your template uses Flutter `$`-style placeholders such as " +
                  "`$FLUTTER_BASE_HREF`, run it through `flutter_web_index_html_subst` first; " +
                  "this rule does not perform any substitution on its own. If not set, an " +
                  "index.html is generated from the built-in template.",
            allow_single_file = [".html"],
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
            doc = "If True (default), generate a built-in caching service worker " +
                  "(flutter_service_worker.js) and include registration in generated HTML. " +
                  "For custom PWA support, provide your own index.html and service worker JS " +
                  "via web_assets instead.",
            default = True,
        ),
        "use_local_canvaskit": attr.bool(
            doc = "If True, load CanvasKit/Skwasm from the app's own server instead of " +
                  "Google's CDN (gstatic.com). Use this for air-gapped deployments or " +
                  "environments that cannot reach external CDNs. The CDN already sends " +
                  "Cross-Origin-Resource-Policy: cross-origin, so COEP does not require " +
                  "this. The canvaskit/ directory is always included in the build output " +
                  "regardless of this setting.",
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
    }),
    toolchains = ["@rules_flutter//flutter:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Builds a Flutter web application (WASM or JS) with all deployment artifacts.",
)
