"""Flutter kernel compilation action using the frontend_server.

Flutter compilation differs from vanilla Dart in that it uses:
- Flutter's patched SDK (platform_strong.dill) instead of the standard Dart SDK
- The frontend_server_aot.dart.snapshot instead of `dart compile kernel`
"""

load("//flutter/private:app_entrypoint.bzl", "APP_SCHEME")
load("//flutter/private:exec_groups.bzl", "PORTABLE")
load("//flutter/private:path_mapping.bzl", "dirname", "output_root", "sdk_action")

# frontend_server stays within about one core. The memory covers a small app;
# a larger program needs more.
def _kernel_compile_resources(_os, _inputs):
    return {"memory": 600}

def flutter_kernel_compile_action(
        ctx,
        dartaotruntime,
        dart,
        kernel_filter_tool,
        flutter_sdk_files,
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
        filesystem_root_files = [],
        recorded_uses = None):
    """Creates a Flutter kernel compilation action.

    Invokes the frontend_server via dartaotruntime to compile Dart sources
    to a kernel .dill file using Flutter's patched platform SDK.

    Args:
        ctx: The rule context.
        dartaotruntime: The dartaotruntime executable File (from FlutterSdkInfo).
        dart: The Dart executable File that runs [kernel_filter_tool].
        kernel_filter_tool: `kernel_filter.dart`, which runs the
            frontend_server and drops its batch-protocol lines from the
            output so a successful compile prints nothing.
        flutter_sdk_files: All Flutter SDK files needed (for action inputs).
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
            library's URI is a sandbox-specific `file://` path, which also
            makes the kernel's bytes depend on the sandbox it was built in.
            Every caller supplies one.
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
        filesystem_root_files: Files whose roots (`output_root`: the exec
            root for a source file, `bazel-out/<config>/bin` for a generated
            one) are mounted under `APP_SCHEME`, for every `APP_SCHEME` URI
            above — the registrant's and, for a `main` with no `package:`
            URI, [entrypoint_uri]'s. Files rather than directory strings, so
            the roots are path-mapped with the rest of the command line.
        recorded_uses: Optional declared File the compiler writes the
            `@RecordUse` uses that survive tree-shaking to (`--recorded-uses`),
            the input of package link hooks. Only an AOT compile records; a
            JIT compile writes an empty file.
    """
    args = ctx.actions.args()
    args.add(kernel_filter_tool)
    args.add("--")
    args.add(dartaotruntime)
    args.add(frontend_server)

    # --sdk-root points to the directory containing the platform dill.
    # --platform-dill specifies the exact filename when it's not the
    # default "platform_strong.dill" (e.g. web's dart2wasm_platform.dill).
    args.add_all("--sdk-root", [platform_dill], map_each = dirname, format_each = "%s/")
    if platform_dill.basename != "platform_strong.dill":
        args.add("--platform", platform_dill)

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

    # Compilation mode flags
    bazel_mode = ctx.var["COMPILATION_MODE"]
    if bazel_mode == "dbg":
        args.add("--enable-asserts")

    for d in defines:
        args.add("-D" + d)

    if filesystem_root_files:
        args.add_all(
            filesystem_root_files,
            map_each = output_root,
            before_each = "--filesystem-root",
            uniquify = True,
        )
        args.add("--filesystem-scheme", APP_SCHEME)

    if dart_plugin_registrant_uri:
        args.add("--source", dart_plugin_registrant_uri)
        args.add("--source", "package:flutter/src/dart_plugin_registrant.dart")
        args.add("-Dflutter.dart_plugin_registrant=" + dart_plugin_registrant_uri)

    args.add_all(extra_flags)

    if native_assets_manifest != None:
        args.add("--native-assets", native_assets_manifest)

    if recorded_uses != None:
        args.add("--recorded-uses", recorded_uses)

    if entrypoint_uri:
        args.add(entrypoint_uri)
    else:
        args.add(main)

    direct_inputs = [main, package_config, frontend_server, platform_dill] + srcs
    if native_assets_manifest != None:
        direct_inputs.append(native_assets_manifest)
    outputs = [output]
    if recorded_uses != None:
        outputs.append(recorded_uses)

    ctx.actions.run(
        executable = dart,
        arguments = [args],
        inputs = depset(
            direct = direct_inputs + [kernel_filter_tool, dartaotruntime],
            transitive = [flutter_sdk_files],
        ),
        outputs = outputs,
        mnemonic = "FlutterKernelCompile",
        exec_group = PORTABLE,
        resource_set = _kernel_compile_resources,
        progress_message = "Compiling Flutter kernel %s" % ctx.label,
        **sdk_action()
    )
