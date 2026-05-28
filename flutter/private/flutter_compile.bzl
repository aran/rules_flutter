"""Flutter kernel compilation action using the frontend_server.

Flutter compilation differs from vanilla Dart in that it uses:
- Flutter's patched SDK (platform_strong.dill) instead of the standard Dart SDK
- The frontend_server_aot.dart.snapshot instead of `dart compile kernel`
"""

def flutter_kernel_compile_action(
        ctx,
        dartaotruntime,
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
        native_assets_manifest = None):
    """Creates a Flutter kernel compilation action.

    Invokes the frontend_server via dartaotruntime to compile Dart sources
    to a kernel .dill file using Flutter's patched platform SDK.

    Args:
        ctx: The rule context.
        dartaotruntime: The dartaotruntime executable File (from FlutterSdkInfo).
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
    """
    args = ctx.actions.args()
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

    # Suppress frontend_server's interactive-protocol chatter (boundary-key
    # framing, `+file://...` lines) and info-level messages. Bazel surfaces
    # all action stdout on success; without these, a successful compile
    # produces dozens of `INFO: From Compiling Flutter kernel` lines.
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

    args.add_all(extra_flags)

    if native_assets_manifest != None:
        args.add("--native-assets", native_assets_manifest.path)

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

    direct_inputs = [main, package_config, frontend_server, platform_dill] + srcs
    if native_assets_manifest != None:
        direct_inputs.append(native_assets_manifest)

    ctx.actions.run(
        executable = dartaotruntime,
        arguments = [args],
        inputs = depset(
            direct = direct_inputs,
            transitive = [flutter_sdk_files],
        ),
        outputs = [output],
        mnemonic = "FlutterKernelCompile",
        progress_message = "Compiling Flutter kernel %s" % ctx.label,
        env = env,
    )
