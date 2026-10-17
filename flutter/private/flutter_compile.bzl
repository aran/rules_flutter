"""Flutter kernel compilation action using the frontend_server.

Flutter compilation differs from vanilla Dart in that it uses:
- Flutter's patched SDK (platform_strong.dill) instead of the standard Dart SDK
- The frontend_server_aot.dart.snapshot instead of `dart compile kernel`
"""

load("//flutter:providers.bzl", "resolve_exec_dart_vm")
load("//flutter/private:app_entrypoint.bzl", "APP_SCHEME")

def flutter_kernel_compile_action(
        ctx,
        dartaotruntime,
        kernel_filter_tool,
        frontend_server,
        platform_dill,
        main,
        srcs,
        package_config,
        output,
        entrypoint_uri = None,
        aot = False,
        defines = [],
        extra_flags = [],
        target = "flutter",
        native_assets_manifest = None,
        dart_plugin_registrant_uri = None,
        filesystem_roots = [],
        recorded_uses = None,
        from_dill = None):
    """Creates a Flutter kernel compilation action.

    Invokes the frontend_server via dartaotruntime to compile Dart sources
    to a kernel .dill file using Flutter's patched platform SDK.

    Args:
        ctx: The rule context.
        dartaotruntime: The dartaotruntime executable File (from FlutterSdkInfo).
        kernel_filter_tool: The compiled `kernel_filter` executable File.
        frontend_server: The frontend_server_aot.dart.snapshot File.
        platform_dill: The platform_strong.dill File (debug or product).
        main: The entrypoint .dart source File. Always an action input and
            used for the progress message; it is *not* automatically the
            string handed to frontend_server — see [entrypoint_uri].
        srcs: List of all source Files (direct + transitive).
        package_config: The package_config.json File.
        output: The output .dill File to produce.
        entrypoint_uri: The string frontend_server compiles as the root
            library, which fixes that library's `importUri` in the kernel.
            Pass a `package:` URI (resolved via [package_config]) so the
            URI is identical regardless of where the kernel was built —
            this is required for hot reload, because `reloadSources` only
            applies a delta when the dev tool's incremental dill keys the
            library by the *same* URI as the running program. When None,
            frontend_server is given [main]'s exec path, so the root
            library's URI is a sandbox-specific `file://` path — acceptable
            only for entrypoints that are never hot-reloaded and belong to
            no package (e.g. a generated test bootstrap). The
            app_entrypoint resolver always supplies a concrete value for
            application builds.
        aot: If True, compile for AOT (adds --aot --tfa flags).
        defines: Environment declarations; each entry becomes a -D flag.
        extra_flags: Additional frontend_server flags.
        target: Frontend server target model ("flutter" or "dartdevc" for web).
        native_assets_manifest: Optional `native_assets.json` File. Passed
            to the frontend_server via `--native-assets`. The frontend
            server embeds the manifest into the resulting kernel so the
            engine can resolve `package:` Native Assets at runtime.
        dart_plugin_registrant_uri: Optional `APP_SCHEME` URI of the
            generated plugin registrant (`app_scheme_location`). When set, the
            registrant is compiled into the kernel as an extra source and
            advertised via `-Dflutter.dart_plugin_registrant=` so the
            engine invokes `_PluginRegistrant.register()` before main() on
            every root-isolate launch (including hot restart). The
            multi-root scheme keeps the library's importUri identical to
            the define regardless of sandbox location — the engine matches
            them by exact string equality.
        filesystem_roots: Exec-root-relative directories (`""` for the exec
            root) mounted under `APP_SCHEME`, for every `APP_SCHEME` URI
            above — the registrant's and, for a `main` with no `package:`
            URI, [entrypoint_uri]'s.
        recorded_uses: Optional declared File the compiler writes the
            `@RecordUse` uses that survive tree-shaking to (`--recorded-uses`),
            the input of package link hooks. Only an AOT compile records; a
            JIT compile writes an empty file.
        from_dill: Optional pre-linked modular `.dill` File passed via
            `--from-dill` to initialize `frontend_server` without re-parsing
            transitive sources.
    """
    args = ctx.actions.args()
    args.add("--")
    args.add(dartaotruntime)
    args.add(frontend_server)

    # --sdk-root points to the directory containing the platform dill.
    # --platform-dill specifies the exact filename when it's not the
    # default "platform_strong.dill" (e.g. web's dart2wasm_platform.dill).
    args.add("--sdk-root", platform_dill.dirname + "/")
    if platform_dill.basename != "platform_strong.dill":
        args.add("--platform", platform_dill.path)

    args.add("--target", target)
    args.add("--packages", package_config)
    args.add("--output-dill", output)

    # Suppress frontend_server's `+file://...` dependency lines and info-level
    # messages. Bazel surfaces all action stdout on success; without these, a
    # successful compile produces dozens of `INFO: From Compiling Flutter
    # kernel` lines. The boundary-key framing has no flag; kernel_filter.dart
    # drops it.
    args.add("--no-print-incremental-dependencies")
    args.add("--verbosity=error")

    if aot:
        args.add("--aot")
        args.add("--tfa")
        args.add("--no-embed-source-text")

    # Compilation mode flags
    bazel_mode = ctx.var["COMPILATION_MODE"]
    if bazel_mode == "dbg":
        args.add("--enable-asserts")

    for d in defines:
        args.add("-D" + d)

    # Always mount the output bin_dir first and the exec root (`.`) second under
    # APP_SCHEME so multi-root package_config.json entries (`org-dartlang-app:///...`)
    # resolve both generated files in bazel-out and hand-written files in the source tree.
    mounted_roots = [ctx.bin_dir.path, ""]
    for r in filesystem_roots:
        if r != None and r not in mounted_roots:
            mounted_roots.append(r)
    for root in mounted_roots:
        args.add("--filesystem-root", root or ".")
    args.add("--filesystem-scheme", APP_SCHEME)

    if dart_plugin_registrant_uri:
        args.add("--source", dart_plugin_registrant_uri)
        args.add("--source", "package:flutter/src/dart_plugin_registrant.dart")
        args.add("-Dflutter.dart_plugin_registrant=" + dart_plugin_registrant_uri)

    args.add_all(extra_flags)

    if native_assets_manifest != None:
        args.add("--native-assets", native_assets_manifest.path)

    if recorded_uses != None:
        args.add("--recorded-uses", recorded_uses)

    if from_dill != None:
        args.add("--from-dill", from_dill.path)

    if entrypoint_uri:
        args.add(entrypoint_uri)
    else:
        args.add(main)

    # Suppress Dart/Flutter analytics (avoids writes to $HOME/.dart/ in sandbox).
    # Provide a writable HOME scoped to this action's output directory.
    env = {"CI": "true", "FLUTTER_SUPPRESS_ANALYTICS": "true"}
    if dartaotruntime.basename.endswith(".exe"):
        env["USERPROFILE"] = output.dirname
        env["LOCALAPPDATA"] = output.dirname
    else:
        env["HOME"] = output.dirname

    if from_dill != None:
        direct_inputs = [main, package_config, frontend_server, platform_dill, from_dill]
    else:
        direct_inputs = [main, package_config, frontend_server, platform_dill] + srcs
    if native_assets_manifest != None:
        direct_inputs.append(native_assets_manifest)
    outputs = [output]
    if recorded_uses != None:
        outputs.append(recorded_uses)

    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    ctx.actions.run(
        executable = dart_exe,
        arguments = [kernel_filter_tool.path, args],
        inputs = depset(
            direct = direct_inputs + [dartaotruntime, kernel_filter_tool],
            transitive = [dart_vm_files],
        ),
        outputs = outputs,
        mnemonic = "FlutterKernelCompile",
        progress_message = "Compiling Flutter kernel %s" % ctx.label,
        env = env,
    )
