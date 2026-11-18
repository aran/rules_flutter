"""A Flutter program's kernel: rules_dart's whole-program compile, given Flutter's platform."""

load("@rules_dart//dart:utils.bzl", "dart_whole_program_kernel_action")
load("//flutter/private:app_entrypoint.bzl", "APP_SCHEME")
load("//flutter/private:flutter_module.bzl", "flutter_kernel_sdk_info")

visibility("//flutter/...")

def flutter_kernel_resources(_os, inputs_size):
    """What a Flutter kernel compile uses, for Bazel's local scheduler.

    The front end holds the whole program in memory and stays within about
    one core. Its peak grows with the program: measured from about 0.7 GB for
    an app of 2,000 inputs to 1.6 GB for one of 4,100, under half a megabyte
    per input, which this declares with headroom for programs that reach more
    code per file.

    Args:
        _os: The execution OS.
        inputs_size: The number of the action's inputs.

    Returns:
        The resource set: one core, and half a megabyte per input but at
        least 800 MB.
    """
    return {"cpu": 1, "memory": max(800, inputs_size // 2)}

def flutter_kernel_compile(
        ctx,
        tools,
        runtime,
        main,
        srcs,
        packages,
        output,
        entrypoint_uri,
        aot = False,
        target_os = None,
        defines = [],
        track_widget_creation = False,
        native_assets_manifest = None,
        dart_plugin_registrant_uri = None,
        recorded_uses = None):
    """Compiles a Flutter program from source into one kernel `.dill`.

    The compile is rules_dart's `dart_whole_program_kernel_action`, given the
    selected SDK's platform (`flutter_kernel_sdk_info`). It reads every source
    under `APP_SCHEME`, rooted at the exec root and the output directories the
    sources are in, so each library outside a package is named by its path in
    the workspace, as the dev loop's compiler names it, and the kernel holds
    no path of the machine or the sandbox.

    Args:
        ctx: The rule context; the rule declares `PORTABLE_EXEC_GROUPS` and
            merges rules_dart's `KERNEL_TOOL_ATTR`.
        tools: The `FlutterExecToolsInfo` of the `PORTABLE` group
            (`portable_tools`), whose SDK the program compiles with.
        runtime: The build mode the kernel is for (`debug`, `profile`,
            `release`), which fixes the platform dill and `dart.vm.*`.
        main: The entrypoint `.dart` File.
        srcs: Depset of every other source File the program reads, the
            registrant's among them.
        packages: The `DartPackageInfo` records the program compiles against,
            the app's own included.
        output: The `.dill` File to produce.
        entrypoint_uri: The URI the front end compiles as the root library:
            the app's `package:` URI, or its `APP_SCHEME` one. The running
            program keys the library by it, and a hot reload's delta applies
            only when the dev tool's compiler keys it the same.
        aot: Whether to compile for AOT (`--aot --tfa`).
        target_os: The OS an AOT kernel runs on (`android`, `ios`, `linux`,
            `macos`, `windows`), which `flutter build` passes as
            `--target-os` so the front end folds what `dart:io`'s `Platform`
            says about it; None for a kernel that runs on any (a test's).
        defines: Environment declarations beyond the runtime's.
        track_widget_creation: Whether to apply the widget-creation transform.
        native_assets_manifest: Optional `native_assets.json` File, embedded
            in the kernel so the engine resolves `@Native(assetId:)` bindings.
        dart_plugin_registrant_uri: Optional `APP_SCHEME` URI of the generated
            plugin registrant (`app_scheme_location`). It is compiled into the
            kernel beside the program and named by
            `-Dflutter.dart_plugin_registrant=`, which the engine looks up by
            exact string to call `_PluginRegistrant.register()` before `main()`
            on every root-isolate launch, hot restart included.
        recorded_uses: Optional File the compiler writes the `@RecordUse` uses
            that survive tree-shaking to, the input of package link hooks. Only
            an AOT compile records any.
    """
    flags = []
    if aot:
        flags += ["--aot", "--tfa"]
        if target_os:
            flags += ["--target-os", target_os]
    if ctx.var["COMPILATION_MODE"] == "dbg":
        flags.append("--enable-asserts")
    sources = []
    if dart_plugin_registrant_uri:
        sources = [dart_plugin_registrant_uri, "package:flutter/src/dart_plugin_registrant.dart"]
        defines = defines + ["flutter.dart_plugin_registrant=" + dart_plugin_registrant_uri]
    dart_whole_program_kernel_action(
        ctx,
        kernel_sdk = flutter_kernel_sdk_info(tools),
        runtime = runtime,
        main = main,
        srcs = srcs,
        packages = packages,
        output_dill = output,
        entrypoint_uri = entrypoint_uri,
        sources = sources,
        filesystem_scheme = APP_SCHEME,
        defines = defines,
        flags = flags,
        native_assets = native_assets_manifest,
        track_creation_locations = track_widget_creation,
        outputs = {"--recorded-uses": recorded_uses} if recorded_uses != None else {},
        resource_set = flutter_kernel_resources,
    )
