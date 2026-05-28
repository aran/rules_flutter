"""Flutter Windows desktop application bundling and runner compilation.

Two separate rules:
  - _flutter_windows_runner_lib: Compiles a Win32 runner binary from C++ sources.
  - _flutter_windows_bundle: Pure assembler — takes a pre-compiled runner +
    FlutterApplicationInfo and produces the bundle directory.

Output bundle structure:
    my_app/
      my_app.exe             (Win32 runner executable)
      flutter_windows.dll    (Flutter engine)
      app.so                 (AOT-compiled Dart code as ELF)
      *.dll                  (native plugin libraries, if any)
      data/
        flutter_assets/
          AssetManifest.bin
          FontManifest.json
          NOTICES.Z
        icudtl.dat
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterInfo")
load("//flutter/private:cc_runner_compile.bzl", "compile_and_link_runner")
load("//flutter/private:common.bzl", "compute_desktop_bundle_copies")
load("//flutter/private:engine_helpers.bzl", "find_engine_header_dir")

# =============================================================================
# Runner compilation rule
# =============================================================================

def _flutter_windows_runner_lib_impl(ctx):
    # Get engine files from the engine target.
    engine_files = ctx.attr.engine[DefaultInfo].files.to_list()

    # Separate registrant .cc and .h files.
    registrant_srcs = []
    registrant_hdrs = []
    for f in ctx.files.registrant:
        if f.path.endswith(".cc"):
            registrant_srcs.append(f)
        elif f.path.endswith(".h"):
            registrant_hdrs.append(f)

    # Use custom sources if provided, otherwise use built-in flutter create-style runner.
    if ctx.attr.srcs:
        runner_srcs = ctx.files.srcs
        runner_hdrs = ctx.files.hdrs
    else:
        runner_srcs = [f for f in ctx.files._runner_sources if f.path.endswith((".cc", ".cpp", ".c"))]
        runner_hdrs = ctx.files.hdrs + [f for f in ctx.files._runner_sources if f.path.endswith(".h")]
        runner_hdrs = runner_hdrs + [f for f in ctx.files._runner_hdrs if f.path.endswith(".h")]

    # Determine debug vs release for the NDEBUG define.
    # We infer from the application target if available, otherwise from
    # the compilation mode.
    is_debug = ctx.var.get("COMPILATION_MODE", "fastbuild") != "opt"

    # Gather Windows plugin source bundles from the application's
    # transitive FlutterInfo. Same pattern as Linux: compile plugin
    # sources alongside runner sources so the registrant's
    # `<Plugin>RegisterWithRegistrar` symbols resolve at link time.
    plugin_srcs = []
    plugin_hdrs = []
    plugin_include_dirs = []
    if ctx.attr.application:
        for entry in ctx.attr.application[FlutterInfo].windows_plugin_libraries.to_list():
            plugin_srcs.extend(entry.srcs.to_list())
            plugin_hdrs.extend(entry.hdrs.to_list())
            plugin_include_dirs.extend(entry.include_dirs.to_list())

    runner_binary = _compile_windows_runner(
        ctx,
        runner_srcs = runner_srcs,
        runner_hdrs = runner_hdrs,
        engine_files = engine_files,
        is_debug = is_debug,
        registrant_srcs = registrant_srcs,
        registrant_hdrs = registrant_hdrs,
        plugin_srcs = plugin_srcs,
        plugin_hdrs = plugin_hdrs,
        plugin_include_dirs = plugin_include_dirs,
    )

    return [DefaultInfo(
        files = depset([runner_binary]),
        executable = runner_binary,
    )]

def _compile_windows_runner(ctx, runner_srcs, engine_files, is_debug, registrant_srcs = [], registrant_hdrs = [], runner_hdrs = [], plugin_srcs = [], plugin_hdrs = [], plugin_include_dirs = []):
    """Compile the C++ Win32 runner binary.

    Uses cc_common.compile() + cc_common.link() with Bazel's hermetic CC
    toolchain.  Links against flutter_windows.dll via its import library.

    The compilation needs two include paths:
    - The engine header directory (for flutter_windows.h and the raw C headers)
    - The C++ client wrapper include directory (for flutter/plugin_registry.h)

    Args:
        ctx: Rule context.
        runner_srcs: List of C++ source Files for the runner.
        engine_files: Engine library files from toolchain.
        is_debug: Whether this is a debug build.
        registrant_srcs: Generated registrant .cc files.
        registrant_hdrs: Generated registrant .h files.
        runner_hdrs: User-provided header files for the runner.
        plugin_srcs: Windows plugin C++ sources (from
            FlutterInfo.windows_plugin_libraries) compiled into the runner.
        plugin_hdrs: Windows plugin C++ headers; their parent dirs are
            added to the include path.
        plugin_include_dirs: Plugin-relative include directories,
            resolved against each plugin's package root via additional
            `-I` flags.

    Returns:
        The compiled runner executable File.
    """
    header_dir = find_engine_header_dir(engine_files, "flutter_windows.h")

    # Find the engine DLL, import library, headers, and C++ wrapper sources.
    engine_dll = None
    engine_import_lib = None
    header_files = []
    wrapper_srcs = []
    wrapper_include_dir = None
    wrapper_root_dir = None
    for f in engine_files:
        if f.basename == "flutter_windows.dll":
            engine_dll = f
        elif f.basename == "flutter_windows.dll.lib":
            engine_import_lib = f
        elif f.path.endswith(".h"):
            header_files.append(f)

            # Detect the C++ wrapper include directories from the flutter/ headers.
            if not wrapper_include_dir and "/include/flutter/" in f.path:
                idx = f.path.index("/include/flutter/")
                wrapper_include_dir = f.path[:idx + len("/include")]
                wrapper_root_dir = f.path[:idx]
        elif f.path.endswith(".cc"):
            # engine_method_result.cc is deprecated (since Flutter 3.13) and
            # just #includes core_implementations.cc — compiling it would
            # cause duplicate symbols.
            if f.basename != "engine_method_result.cc":
                wrapper_srcs.append(f)

            # All .cc files (including deprecated ones) must be declared
            # inputs since wrapper files #include other .cc files.
            header_files.append(f)

    if not engine_dll:
        fail("flutter_windows.dll not found in engine files — the Flutter " +
             "engine archive may have changed its layout.")
    if not engine_import_lib:
        fail("flutter_windows.dll.lib not found in engine files — the Flutter " +
             "engine archive may have changed its layout.")

    # UNICODE/_UNICODE: use wide-char Win32 APIs (CreateWindowW, RegGetValueW, etc.)
    # Required by the flutter create runner which uses wchar_t throughout.
    defines = ["UNICODE", "_UNICODE"]
    if not is_debug:
        defines.append("NDEBUG")

    additional_srcs = list(wrapper_srcs) + list(registrant_srcs)

    # The wrapper needs two include paths:
    # - wrapper_include_dir: for <flutter/plugin_registry.h> (angle-bracket includes)
    # - wrapper_root_dir: for "include/flutter/..." and "binary_messenger_impl.h"
    #   (quoted includes within wrapper .cc files)
    # The engine header dir is already passed via engine_include_dir for
    # "flutter_windows.h".
    extra_compile_flags = []
    if wrapper_include_dir:
        extra_compile_flags.append("-I" + wrapper_include_dir)
    if wrapper_root_dir:
        extra_compile_flags.append("-I" + wrapper_root_dir)

    # Include registrant, runner, and plugin header directories.
    all_header_files = header_files + registrant_hdrs + runner_hdrs + plugin_hdrs
    seen_dirs = {}
    for h in registrant_hdrs + runner_hdrs + plugin_hdrs:
        d = h.path[:h.path.rfind("/")]
        if d not in seen_dirs:
            seen_dirs[d] = True
            extra_compile_flags.append("-I" + d)

    # For flutter create registrant files at windows/flutter/generated_plugin_registrant.h,
    # also add the grandparent dir so #include "flutter/generated_plugin_registrant.h" resolves.
    for h in registrant_hdrs:
        if "/flutter/" in h.path:
            d = h.path[:h.path.rfind("/")]
            grandparent = d[:d.rfind("/")]
            if grandparent and grandparent not in seen_dirs:
                seen_dirs[grandparent] = True
                extra_compile_flags.append("-I" + grandparent)

    # Plugin-relative include dirs (e.g. "windows/include") resolved
    # against each plugin's package root (deduced from plugin_srcs paths).
    plugin_pkg_roots = {}
    for f in plugin_srcs:
        path = f.path
        idx = path.rfind("/windows/")
        if idx > 0:
            pkg_root = path[:idx]
            if pkg_root not in plugin_pkg_roots:
                plugin_pkg_roots[pkg_root] = True
    for include_dir in plugin_include_dirs:
        for pkg_root in plugin_pkg_roots.keys():
            full = pkg_root + "/" + include_dir
            if full not in seen_dirs:
                seen_dirs[full] = True
                extra_compile_flags.append("-I" + full)

    return compile_and_link_runner(
        ctx = ctx,
        name = ctx.label.name + "_windows_runner",
        srcs = runner_srcs,
        engine_library_file = engine_dll,
        engine_import_library = engine_import_lib,
        engine_header_files = all_header_files,
        engine_include_dir = header_dir,
        extra_compile_flags = extra_compile_flags,
        extra_link_flags = ["/SUBSYSTEM:WINDOWS", "user32.lib", "ole32.lib", "dwmapi.lib", "shell32.lib", "advapi32.lib"],
        extra_defines = defines,
        additional_srcs = additional_srcs + plugin_srcs,
    )

flutter_windows_runner_lib = rule(
    implementation = _flutter_windows_runner_lib_impl,
    attrs = {
        "engine": attr.label(
            doc = "A flutter_windows_engine target providing engine DLL + headers.",
            mandatory = True,
        ),
        "registrant": attr.label(
            doc = "A flutter_windows_registrant_gen target providing the C++ registrant .cc and .h.",
            mandatory = True,
            allow_files = True,
        ),
        "srcs": attr.label_list(
            doc = "Custom runner C++ source files (empty = use built-in template).",
            allow_files = [".cc", ".cpp", ".c"],
        ),
        "hdrs": attr.label_list(
            doc = "Custom runner C++ header files.",
            allow_files = [".h", ".hpp"],
        ),
        "application": attr.label(
            doc = "Optional flutter_application target. When set, the runner " +
                  "compiles every transitive plugin's Windows C++ sources " +
                  "alongside its own (collected from " +
                  "FlutterInfo.windows_plugin_libraries).",
            providers = [FlutterInfo],
        ),
        "_runner_sources": attr.label(
            default = Label("//flutter/private/runners:windows_runner_srcs"),
            allow_files = True,
        ),
        "_runner_hdrs": attr.label(
            default = Label("//flutter/private/runners:windows_runner_hdrs"),
            allow_files = True,
        ),
        "_cc_toolchain": attr.label(
            default = "@bazel_tools//tools/cpp:current_cc_toolchain",
        ),
    },
    fragments = ["cpp"],
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
        "@rules_flutter//flutter:toolchain_type",
    ],
    doc = "Compiles a Win32 runner binary from C++ sources with engine and registrant.",
)

# =============================================================================
# Bundle assembly rule (pure assembler — no compilation)
# =============================================================================

def _flutter_windows_bundle_impl(ctx):
    app_info = ctx.attr.application[FlutterApplicationInfo]
    flutter_assets = app_info.flutter_assets
    icu_data = app_info.icu_data
    native_libs = list(app_info.native_libs)
    native_libs.extend(app_info.bundled_code_assets.to_list())
    is_debug = app_info.is_debug

    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    app_name = ctx.attr.app_name or ctx.label.name

    # Declare the bundle as a tree artifact.
    bundle_dir = ctx.actions.declare_directory(app_name)

    if flutter_sdk_info.engine_library == None:
        fail(
            "No Windows engine library available in the Flutter toolchain. " +
            "To build a Windows bundle from a non-Windows host, use: " +
            "--platforms=@rules_flutter//flutter/platforms:windows_x64",
        )
    engine_files = flutter_sdk_info.engine_library.files.to_list()

    # Filter engine files to only include runtime artifacts (.dll) — not
    # headers, import libraries, or C++ wrapper sources used at compile time.
    engine_runtime_files = [
        f
        for f in engine_files
        if f.basename.endswith(".dll")
    ]

    # Build the bundle config JSON for the Dart bundler tool.
    # Windows: engine DLL at root, AOT at data/app.so (matching flutter build layout).
    # The flutter::DartProject("data") constructor resolves AOT relative to data/.
    # Native FFI / Native Assets DLLs land next to the runner exe (`""`
    # prefix) so the Windows dynamic loader resolves them via the
    # standard search-path rules.
    copies = compute_desktop_bundle_copies(
        is_debug = is_debug,
        kernel_dill_path = app_info.kernel_dill.path if app_info.kernel_dill else None,
        aot_output_path = app_info.aot_output.path if app_info.aot_output else None,
        aot_dst = "data/app.so",
        icu_data_path = icu_data.path,
        engine_basenames = [(f.path, f.basename) for f in engine_runtime_files],
        native_basenames = [(lib.path, lib.basename) for lib in native_libs],
        engine_dst_prefix = "",
        native_dst_prefix = "",
    )
    extra_inputs = []
    if is_debug and app_info.kernel_dill:
        extra_inputs.append(app_info.kernel_dill)
    elif app_info.aot_output:
        extra_inputs.append(app_info.aot_output)

    # Get the runner executable from the runner target.
    runner_files = ctx.attr.runner[DefaultInfo].files.to_list()
    runner_binary = None
    for f in runner_files:
        if f.path.endswith(".exe") or (not f.path.endswith(".h") and not f.path.endswith(".cc")):
            runner_binary = f
            break
    if not runner_binary and runner_files:
        runner_binary = runner_files[0]
    if not runner_binary:
        fail("No runner binary found in runner target.")

    copies.append({"src": runner_binary.path, "dst": app_name + ".exe"})

    config = {
        "output_dir": bundle_dir.path,
        "copies": copies,
        "copy_dirs": [
            {"src": flutter_assets.path, "dst": "data/flutter_assets"},
        ],
    }

    config_file = ctx.actions.declare_file(ctx.label.name + "_bundle_config.json")
    ctx.actions.write(config_file, json.encode(config))

    inputs = [ctx.file._bundle_tool, config_file, flutter_assets, icu_data, runner_binary] + extra_inputs + native_libs + engine_files

    ctx.actions.run(
        executable = flutter_sdk_info.dart,
        arguments = [
            ctx.file._bundle_tool.path,
            "--config",
            config_file.path,
        ],
        inputs = depset(
            direct = inputs,
            transitive = [flutter_sdk_info.tool_files],
        ),
        outputs = [bundle_dir],
        mnemonic = "FlutterWindowsBundle",
        progress_message = "Bundling Windows app %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([bundle_dir]))]

flutter_windows_bundle_rule = rule(
    implementation = _flutter_windows_bundle_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing the compiled artifacts.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "runner": attr.label(
            doc = "A pre-compiled runner executable (from flutter_windows_runner_lib_gen or cc_binary).",
            mandatory = True,
        ),
        "app_name": attr.string(
            doc = "Name of the application binary and bundle directory (defaults to target name).",
        ),
        "_bundle_tool": attr.label(
            default = Label("//flutter/private/tools:bundle_app.dart"),
            allow_single_file = True,
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ],
    doc = "Assembles a Windows application directory from a pre-compiled runner and flutter_application artifacts.",
)
