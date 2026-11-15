"""The engine contract: providers and the rules that build them.

An engine source is a repository. Each piece of an engine (a *slice*: one
piece, for one platform, mode and architecture) is a target at a fixed label in
it that returns one of the providers below; README.md, "Writing an engine
source", lists the labels. A slice target can be anything that returns the
provider: these rules over downloaded files, over symlinks into an out dir, an
`alias` into another repository, or a target that builds the files.

Every provider carries `provenance`, a `dict[str, str]` the source fills in
(where the files came from). It is recorded in the app only when the source is
not the stock release.
"""

load("@rules_dart//dart:toolchain.bzl", "DartSdkFilesInfo")

FlutterHostToolsInfo = provider(
    doc = "The tools that run on one host and whose output does not depend on the target: the Dart SDK, " +
          "frontend_server, flutter_tester, impellerc and font-subset.",
    fields = {
        "host_os": "str: The OS the tools run on (`macos`, `linux`, `windows`).",
        "host_arch": "str: The CPU the tools run on (`arm64`, `x64`).",
        "dart_sdk": "DartSdkFilesInfo: The Dart SDK's files by the use that reads them.",
        "dart": "File: The `dart` executable.",
        "dartaotruntime": "File: The `dartaotruntime` executable.",
        "frontend_server": "File: `frontend_server_aot.dart.snapshot`.",
        "kernel_worker": "File: `kernel_worker_aot.dart.snapshot`.",
        "dart_libraries_json": "File: The Dart SDK's `lib/libraries.json`.",
        "dart_platform_dill": "File: The Dart SDK's `vm_platform_strong.dill`, which a kernel compile carries the format of.",
        "flutter_tester": "File: The `flutter_tester` headless engine.",
        "icu_data": "File: `icudtl.dat`.",
        "vm_isolate_snapshot": "File: `vm_isolate_snapshot.bin`.",
        "isolate_snapshot": "File: `isolate_snapshot.bin`.",
        "impellerc": "File: The `impellerc` shader compiler.",
        "shader_lib": "list[File]: The files impellerc includes from.",
        "shader_include_dir": "str: The execution path of the directory holding `shader_lib`.",
        "font_subset": "File: The `font-subset` binary.",
        "provenance": "dict[str, str]: Where the files came from.",
    },
)

FlutterPlatformKernelInfo = provider(
    doc = "The engine's platform kernel for one mode.",
    fields = {
        "platform_dill": "File: `platform_strong.dill`.",
        "outline_dill": "File or None: `vm_outline_strong.dill`.",
        "files": "depset[File]: Every file of the patched SDK.",
        "provenance": "dict[str, str]: Where the files came from.",
    },
)

FlutterEngineInfo = provider(
    doc = "The Flutter engine of one platform and mode.",
    fields = {
        "os": "str: The OS it is for.",
        "mode": "str: `debug`, `profile` or `release`.",
        "cpus": "list[str]: The CPUs the binary contains (`arm64`, `x86_64`).",
        "files": "depset[File]: The framework, library and headers.",
        "binary": "File: The one file whose snapshot hash is read.",
        "binary_entry": "str: When `binary` is an archive (Android's `flutter.jar`), the entry of it that holds the engine library; otherwise empty.",
        "xcframework_slices": "list[str]: iOS only: the xcframework slices present.",
        "cpp_client_wrapper": "depset[File] or None: Windows only.",
        "provenance": "dict[str, str]: Where the files came from.",
    },
)

FlutterGenSnapshotInfo = provider(
    doc = "A gen_snapshot for one target and mode, runnable on one host.",
    fields = {
        "binary": "File: The gen_snapshot executable.",
        "target_cpu": "str: The CPU it compiles for.",
        "mode": "str: `profile` or `release`.",
        "provenance": "dict[str, str]: Where the file came from.",
    },
)

FlutterMissingSliceInfo = provider(
    doc = "A slice an engine source does not provide. Nothing reads it: a rule that needs the slice fails first.",
    fields = {"message": "str: Why the slice is missing."},
)

def _flutter_missing_slice_impl(ctx):
    fail("%s: %s" % (ctx.label, ctx.attr.message))

flutter_missing_slice = rule(
    implementation = _flutter_missing_slice_impl,
    attrs = {
        "message": attr.string(
            doc = "Says what is missing and how to get it.",
            mandatory = True,
        ),
    },
    doc = "A slice the engine source does not provide. A build that needs it fails at analysis with `message`; " +
          "one that does not is unaffected.",
)

def _shader_include_dir(ctx):
    """The execution path of `shader_include_dir`, checked to hold every `shader_lib` file.

    A source path: path mapping rewrites only output paths, so actions pass
    it as a string.
    """
    if not ctx.files.shader_lib:
        fail("%s: `shader_lib` has no files" % ctx.label)
    anchor = ctx.files.shader_lib[0]
    if not anchor.is_source:
        fail("%s: `shader_lib` must be source files, not %s" % (ctx.label, anchor.path))

    # The anchor's path less its package-relative name is its package's
    # directory, wherever the repository layout puts external repositories.
    in_package = anchor.owner.name
    package_dir = anchor.path[:-len(in_package)].rstrip("/")
    include_dir = "/".join([d for d in [package_dir, ctx.attr.shader_include_dir] if d])
    for f in ctx.files.shader_lib:
        if not f.path.startswith(include_dir + "/"):
            fail("%s: %s is not under `shader_include_dir` (%s)" % (ctx.label, f.path, include_dir))
    return include_dir

def _flutter_host_tools_impl(ctx):
    info = FlutterHostToolsInfo(
        host_os = ctx.attr.host_os,
        host_arch = ctx.attr.host_arch,
        dart_sdk = ctx.attr.dart_sdk[DartSdkFilesInfo],
        dart = ctx.file.dart,
        dartaotruntime = ctx.file.dartaotruntime,
        frontend_server = ctx.file.frontend_server,
        kernel_worker = ctx.file.kernel_worker,
        dart_libraries_json = ctx.file.dart_libraries_json,
        dart_platform_dill = ctx.file.dart_platform_dill,
        flutter_tester = ctx.file.flutter_tester,
        icu_data = ctx.file.icu_data,
        vm_isolate_snapshot = ctx.file.vm_isolate_snapshot,
        isolate_snapshot = ctx.file.isolate_snapshot,
        impellerc = ctx.file.impellerc,
        shader_lib = ctx.files.shader_lib,
        shader_include_dir = _shader_include_dir(ctx),
        font_subset = ctx.file.font_subset,
        provenance = ctx.attr.provenance,
    )
    return [info, DefaultInfo(files = depset(
        [ctx.file.dart, ctx.file.dartaotruntime, ctx.file.frontend_server],
    ))]

def _file(doc):
    return attr.label(doc = doc, mandatory = True, allow_single_file = True)

flutter_host_tools = rule(
    implementation = _flutter_host_tools_impl,
    attrs = {
        "host_os": attr.string(mandatory = True, values = ["macos", "linux", "windows"], doc = "The OS the tools run on."),
        "host_arch": attr.string(mandatory = True, values = ["arm64", "x64"], doc = "The CPU the tools run on."),
        "dart_sdk": attr.label(
            doc = "The Dart SDK's files: a `dart_sdk_files` target.",
            mandatory = True,
            providers = [DartSdkFilesInfo],
        ),
        "dart": _file("The `dart` executable."),
        "dartaotruntime": _file("The `dartaotruntime` executable."),
        "frontend_server": _file("`frontend_server_aot.dart.snapshot`."),
        "kernel_worker": _file("`kernel_worker_aot.dart.snapshot`."),
        "dart_libraries_json": _file("The Dart SDK's `lib/libraries.json`."),
        "dart_platform_dill": _file("The Dart SDK's `lib/_internal/vm_platform_strong.dill`."),
        "flutter_tester": _file("The `flutter_tester` binary."),
        "icu_data": _file("`icudtl.dat`."),
        "vm_isolate_snapshot": _file("`vm_isolate_snapshot.bin`."),
        "isolate_snapshot": _file("`isolate_snapshot.bin`."),
        "impellerc": _file("The `impellerc` binary."),
        "shader_lib": attr.label(doc = "The impellerc include files.", mandatory = True),
        "shader_include_dir": attr.string(
            doc = "The directory impellerc searches for `shader_lib`'s files, relative to " +
                  "the package of the `shader_lib` files.",
            mandatory = True,
        ),
        "font_subset": _file("The `font-subset` binary."),
        "provenance": attr.string_dict(doc = "Where the files came from."),
    },
    doc = "The host tools of an engine source, for one host.",
)

def _flutter_platform_kernel_impl(ctx):
    info = FlutterPlatformKernelInfo(
        platform_dill = ctx.file.platform_dill,
        outline_dill = ctx.file.outline_dill,
        files = depset(ctx.files.files),
        provenance = ctx.attr.provenance,
    )
    return [info, DefaultInfo(files = depset(ctx.files.files))]

flutter_platform_kernel = rule(
    implementation = _flutter_platform_kernel_impl,
    attrs = {
        "platform_dill": _file("`platform_strong.dill`."),
        "outline_dill": attr.label(doc = "`vm_outline_strong.dill`.", allow_single_file = True),
        "files": attr.label(doc = "Every file of the patched SDK.", mandatory = True, allow_files = True),
        "provenance": attr.string_dict(doc = "Where the files came from."),
    },
    doc = "The engine's platform kernel for one mode.",
)

def _engine_impl(ctx):
    files = depset(ctx.files.files)
    info = FlutterEngineInfo(
        os = ctx.attr.os,
        mode = ctx.attr.mode,
        cpus = ctx.attr.cpus,
        files = files,
        binary = ctx.file.binary,
        binary_entry = ctx.attr.binary_entry,
        xcframework_slices = ctx.attr.xcframework_slices,
        cpp_client_wrapper = None,
        provenance = ctx.attr.provenance,
    )
    return [info, DefaultInfo(files = files)]

_ENGINE_ATTRS = {
    "mode": attr.string(mandatory = True, values = ["debug", "profile", "release"], doc = "The build mode the engine is for."),
    "cpus": attr.string_list(mandatory = True, doc = "The CPUs the binary contains."),
    "files": attr.label(
        doc = "The framework, library and headers, as a filegroup or other target.",
        mandatory = True,
        allow_files = True,
    ),
    "binary": attr.label(
        doc = "The one file whose snapshot hash is read.",
        mandatory = True,
        allow_single_file = True,
    ),
    "binary_entry": attr.string(doc = "When `binary` is an archive, the entry of it that holds the engine library. Android only: `lib/<abi>/libflutter.so` of `flutter.jar`."),
    "xcframework_slices": attr.string_list(doc = "iOS only: the xcframework's platform directories (`ios-arm64`, `ios-arm64-simulator`, `ios-arm64_x86_64-simulator`, ...)."),
    "provenance": attr.string_dict(doc = "Where the files came from."),
}

def _engine_rule(os):
    return rule(
        implementation = _engine_impl,
        attrs = _ENGINE_ATTRS | {"os": attr.string(default = os)},
        doc = "The %s engine of one build mode." % os,
    )

flutter_macos_engine_slice = _engine_rule("macos")
flutter_ios_engine_slice = _engine_rule("ios")
flutter_android_engine_slice = _engine_rule("android")
flutter_linux_engine_slice = _engine_rule("linux")
flutter_windows_engine_slice = _engine_rule("windows")

def _flutter_gen_snapshot_impl(ctx):
    info = FlutterGenSnapshotInfo(
        binary = ctx.file.binary,
        target_cpu = ctx.attr.target_cpu,
        mode = ctx.attr.mode,
        provenance = ctx.attr.provenance,
    )
    return [info, DefaultInfo(files = depset([ctx.file.binary]))]

flutter_gen_snapshot = rule(
    implementation = _flutter_gen_snapshot_impl,
    attrs = {
        "binary": _file("The gen_snapshot executable."),
        "target_cpu": attr.string(mandatory = True, doc = "The CPU it compiles for."),
        "mode": attr.string(mandatory = True, values = ["profile", "release"], doc = "The AOT mode it is for."),
        "provenance": attr.string_dict(doc = "Where the file came from."),
    },
    doc = "A gen_snapshot for one target and mode.",
)

FlutterWebSdkInfo = provider(
    doc = "The Flutter web SDK of an engine: the platform kernels the web compilers read, the renderer " +
          "artifacts and the bootstrap script.",
    fields = {
        "files": "depset[File]: The `flutter_web_sdk` tree (`kernel/`, `canvaskit/`, `flutter_js/`, `libraries.json`) and " +
                 "the Dart SDK's `lib` its `libraries.json` includes.",
        "dart2js_platform_dill": "File: `kernel/dart2js_platform.dill`.",
        "dart2wasm_platform_dill": "File: `kernel/dart2wasm_platform.dill`.",
        "ddc_outline_dill": "File: `kernel/ddc_outline.dill`.",
        "has_canvaskit": "bool: Whether the SDK holds the renderers (`canvaskit/`), which a web app of an engine " +
                         "that is not the release's loads from itself rather than from the CDN.",
        "provenance": "dict[str, str]: Where the files came from.",
    },
)

def _flutter_web_sdk_impl(ctx):
    files = depset(ctx.files.files)
    info = FlutterWebSdkInfo(
        files = files,
        dart2js_platform_dill = ctx.file.dart2js_platform_dill,
        dart2wasm_platform_dill = ctx.file.dart2wasm_platform_dill,
        ddc_outline_dill = ctx.file.ddc_outline_dill,
        has_canvaskit = ctx.attr.has_canvaskit,
        provenance = ctx.attr.provenance,
    )
    return [info, DefaultInfo(files = files)]

flutter_web_sdk = rule(
    implementation = _flutter_web_sdk_impl,
    attrs = {
        "files": attr.label(doc = "The web SDK tree, as a filegroup.", mandatory = True, allow_files = True),
        "dart2js_platform_dill": _file("`kernel/dart2js_platform.dill`."),
        "dart2wasm_platform_dill": _file("`kernel/dart2wasm_platform.dill`."),
        "ddc_outline_dill": _file("`kernel/ddc_outline.dill`."),
        "has_canvaskit": attr.bool(doc = "Whether `canvaskit/` holds the renderers.", default = True),
        "provenance": attr.string_dict(doc = "Where the files came from."),
    },
    doc = "The web SDK of an engine source.",
)
