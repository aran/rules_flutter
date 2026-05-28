"""Flutter Linux desktop application bundling and runner compilation.

Two separate rules:
  - _flutter_linux_runner_lib: Compiles a GTK runner binary from C++ sources.
  - _flutter_linux_bundle: Pure assembler — takes a pre-compiled runner +
    FlutterApplicationInfo and produces the bundle directory.

Output bundle structure:
    my_app/
      my_app                     (GTK runner executable)
      lib/
        libapp.so                (AOT-compiled Dart code)
        libflutter_linux_gtk.so  (Flutter engine)
        *.so                     (native plugin libraries, if any)
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
load("//flutter/private:engine_helpers.bzl", "find_engine_header_dir", "linux_multiarch_triple")

# GTK3 include subdirectories within the Chromium sysroot.
_GTK3_INCLUDE_SUBDIRS = [
    "usr/include/gtk-3.0",
    "usr/include/glib-2.0",
    "usr/include/gio-unix-2.0",
    "usr/include/cairo",
    "usr/include/pango-1.0",
    "usr/include/atk-1.0",
    "usr/include/gdk-pixbuf-2.0",
    "usr/include/harfbuzz",
    "usr/include/freetype2",
    "usr/include/fribidi",
    "usr/include/at-spi2-atk/2.0",
    "usr/include/at-spi-2.0",
    "usr/include/dbus-1.0",
    "usr/include/pixman-1",
    "usr/include/uuid",
    "usr/include/libpng16",
    "usr/include/libmount",
    "usr/include/blkid",
]

# GTK3 libraries to link against.
_GTK3_LINK_LIBS = [
    "-lgtk-3",
    "-lgdk-3",
    "-lpangocairo-1.0",
    "-lpango-1.0",
    "-lharfbuzz",
    "-latk-1.0",
    "-lcairo-gobject",
    "-lcairo",
    "-lgdk_pixbuf-2.0",
    "-lgio-2.0",
    "-lgobject-2.0",
    "-lglib-2.0",
]

# =============================================================================
# Runner compilation rule
# =============================================================================

def _flutter_linux_runner_lib_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

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

    runner_srcs = ctx.files.srcs if ctx.attr.srcs else [ctx.file._runner_source]
    runner_hdrs = ctx.files.hdrs

    # Gather Linux plugin source bundles from the application's transitive
    # FlutterInfo. The runner compiles them in the same cc_common.compile()
    # pass as its own sources so the registrant's
    # `<plugin>_register_with_registrar` symbols resolve at link time.
    plugin_srcs = []
    plugin_hdrs = []
    plugin_include_dirs = []
    if ctx.attr.application:
        for entry in ctx.attr.application[FlutterInfo].linux_plugin_libraries.to_list():
            plugin_srcs.extend(entry.srcs.to_list())
            plugin_hdrs.extend(entry.hdrs.to_list())
            plugin_include_dirs.extend(entry.include_dirs.to_list())

    runner_binary = _compile_linux_runner(
        ctx,
        runner_srcs = runner_srcs,
        runner_hdrs = runner_hdrs,
        engine_files = engine_files,
        gtk_app_id = ctx.attr.gtk_app_id,
        registrant_srcs = registrant_srcs,
        registrant_hdrs = registrant_hdrs,
        linux_sysroot = flutter_sdk_info.linux_sysroot,
        target_arch = flutter_sdk_info.target_arch,
        plugin_srcs = plugin_srcs,
        plugin_hdrs = plugin_hdrs,
        plugin_include_dirs = plugin_include_dirs,
    )

    return [DefaultInfo(
        files = depset([runner_binary]),
        executable = runner_binary,
    )]

def _compile_linux_runner(ctx, runner_srcs, engine_files, gtk_app_id, linux_sysroot, registrant_srcs = [], registrant_hdrs = [], runner_hdrs = [], target_arch = "", plugin_srcs = [], plugin_hdrs = [], plugin_include_dirs = []):
    """Compile the C++ GTK Linux runner binary.

    Uses cc_common.compile() + cc_common.link() with Bazel's hermetic CC
    toolchain.  GTK3 headers and libraries come from the Chromium sysroot.

    Args:
        ctx: Rule context.
        runner_srcs: List of C++ source Files for the runner.
        engine_files: Engine library files from toolchain.
        gtk_app_id: GTK application identifier string.
        linux_sysroot: Chromium sysroot target (mandatory for hermetic GTK3 builds).
        registrant_srcs: Generated registrant .cc files.
        registrant_hdrs: Generated registrant .h files.
        runner_hdrs: User-provided header files for the runner.
        target_arch: Target architecture string.
        plugin_srcs: Linux plugin C++ sources (collected from
            FlutterInfo.linux_plugin_libraries) compiled into the runner.
        plugin_hdrs: Linux plugin C++ headers; their parent dirs are
            added to the include path.
        plugin_include_dirs: Plugin-relative include directories
            (resolved against each plugin's package root via
            additional `-I` flags).

    Returns:
        The compiled runner executable File.
    """
    header_dir = find_engine_header_dir(engine_files, "flutter_linux/flutter_linux.h")

    # Find the engine shared library file for the linker.
    engine_so = None
    header_files = []
    for f in engine_files:
        if f.basename == "libflutter_linux_gtk.so":
            engine_so = f
        elif f.path.endswith(".h"):
            header_files.append(f)

    if not engine_so:
        fail("libflutter_linux_gtk.so not found in engine files — the Flutter " +
             "engine archive may have changed its layout.")

    additional_srcs = list(registrant_srcs)

    # Compute GTK3 include/link flags from the hermetic Chromium sysroot.
    # The sysroot is mandatory — we never fall back to system headers.
    if not linux_sysroot:
        fail("linux_sysroot is required for Linux runner compilation. " +
             "The Flutter toolchain must provide a Chromium sysroot for " +
             "hermetic GTK3 builds. Check that the toolchain is configured correctly.")

    system_include_dirs = []
    sysroot_link_flags = []
    sysroot_files = linux_sysroot.files.to_list()

    # Determine sysroot root path from the first file.
    sysroot_root = ""
    if sysroot_files:
        # Files are at paths like <repo>/usr/include/...; find the root.
        first = sysroot_files[0].path
        usr_idx = first.find("/usr/")
        if usr_idx >= 0:
            sysroot_root = first[:usr_idx]

    # Determine multiarch triple from target architecture.
    # For native builds target_arch may be empty; infer from the sysroot paths.
    arch = target_arch
    if not arch:
        # Infer from sysroot file paths: look for a multiarch lib dir.
        for f in sysroot_files:
            if "/x86_64-linux-gnu/" in f.path:
                arch = "x64"
                break
            elif "/aarch64-linux-gnu/" in f.path:
                arch = "arm64"
                break
    triple = linux_multiarch_triple(arch) if arch else "x86_64-linux-gnu"

    for subdir in _GTK3_INCLUDE_SUBDIRS:
        system_include_dirs.append(sysroot_root + "/" + subdir)

    # Arch-specific include dirs (glib and dbus config headers).
    system_include_dirs.append(sysroot_root + "/usr/lib/" + triple + "/glib-2.0/include")
    system_include_dirs.append(sysroot_root + "/usr/lib/" + triple + "/dbus-1.0/include")

    # Link flags: library search path + GTK3 libraries.
    sysroot_link_flags = ["-L" + sysroot_root + "/usr/lib/" + triple] + _GTK3_LINK_LIBS

    # Include registrant headers and runner headers as additional inputs so
    # #include directives resolve.  Also add their directories to the include
    # path so runner code can do #include "flutter/generated_plugin_registrant.h".
    all_header_files = header_files + registrant_hdrs + runner_hdrs + plugin_hdrs
    extra_compile = []
    registrant_include_dirs = {}
    for h in registrant_hdrs:
        d = h.path[:h.path.rfind("/")]
        if d not in registrant_include_dirs:
            registrant_include_dirs[d] = True
            extra_compile.append("-I" + d)

        # For flutter create registrant files at linux/flutter/generated_plugin_registrant.h,
        # also add the grandparent dir so #include "flutter/generated_plugin_registrant.h" resolves.
        if "/flutter/" in h.path:
            grandparent = d[:d.rfind("/")]
            if grandparent and grandparent not in registrant_include_dirs:
                registrant_include_dirs[grandparent] = True
                extra_compile.append("-I" + grandparent)
    for h in runner_hdrs:
        d = h.path[:h.path.rfind("/")]
        if d not in registrant_include_dirs:
            registrant_include_dirs[d] = True
            extra_compile.append("-I" + d)

    # Plugin header parent dirs and plugin-relative include directories.
    # Each plugin's package root is computed from one of its source files;
    # plugin-supplied include_dirs (e.g. "linux/include") are appended to it.
    plugin_pkg_roots = {}
    for h in plugin_hdrs:
        d = h.path[:h.path.rfind("/")]
        if d not in registrant_include_dirs:
            registrant_include_dirs[d] = True
            extra_compile.append("-I" + d)
    for f in plugin_srcs:
        path = f.path

        # The package root is the dirname of the linux/<file> source —
        # walk up until we strip the `/linux/...` suffix.
        idx = path.rfind("/linux/")
        if idx > 0:
            pkg_root = path[:idx]
            if pkg_root not in plugin_pkg_roots:
                plugin_pkg_roots[pkg_root] = True
    for include_dir in plugin_include_dirs:
        for pkg_root in plugin_pkg_roots.keys():
            full = pkg_root + "/" + include_dir
            if full not in registrant_include_dirs:
                registrant_include_dirs[full] = True
                extra_compile.append("-I" + full)

    return compile_and_link_runner(
        ctx = ctx,
        name = ctx.label.name + "_linux_runner",
        srcs = runner_srcs,
        engine_library_file = engine_so,
        engine_header_files = all_header_files,
        engine_include_dir = header_dir,
        extra_compile_flags = extra_compile,
        extra_link_flags = sysroot_link_flags + ["-Wl,-rpath,$ORIGIN/lib"],
        extra_defines = ["GTK_APP_ID=\"" + gtk_app_id + "\""],
        additional_srcs = additional_srcs + plugin_srcs,
        system_include_dirs = system_include_dirs,
        additional_inputs = sysroot_files,
    )

flutter_linux_runner_lib = rule(
    implementation = _flutter_linux_runner_lib_impl,
    attrs = {
        "engine": attr.label(
            doc = "A flutter_linux_engine target providing engine .so + headers.",
            mandatory = True,
        ),
        "registrant": attr.label(
            doc = "A flutter_linux_registrant_gen target providing the C++ registrant .cc and .h.",
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
        "gtk_app_id": attr.string(
            doc = "GTK application identifier (e.g. 'com.example.myapp').",
            default = "com.example.flutter",
        ),
        "application": attr.label(
            doc = "Optional flutter_application target. When set, the runner " +
                  "compiles every transitive plugin's Linux C++ sources " +
                  "alongside its own (collected from " +
                  "FlutterInfo.linux_plugin_libraries).",
            providers = [FlutterInfo],
        ),
        "_runner_source": attr.label(
            default = Label("//flutter/private/runners:linux_runner.cc"),
            allow_single_file = True,
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
    doc = "Compiles a GTK Linux runner binary from C++ sources with engine and registrant.",
)

# =============================================================================
# Bundle assembly rule (pure assembler — no compilation)
# =============================================================================

def _flutter_linux_bundle_impl(ctx):
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
            "No Linux engine library available in the Flutter toolchain. " +
            "To build a Linux bundle from a non-Linux host, use: " +
            "--platforms=@rules_flutter//flutter/platforms:linux_x64",
        )
    engine_files = flutter_sdk_info.engine_library.files.to_list()

    # Build the bundle config JSON for the Dart bundler tool. Both
    # `native_libs` (the legacy FFI cc_library outputs) and
    # `bundled_code_assets` (Native Assets dynamic_loading_bundle dylibs)
    # land at `lib/<basename>` next to `libapp.so`.
    copies = compute_desktop_bundle_copies(
        is_debug = is_debug,
        kernel_dill_path = app_info.kernel_dill.path if app_info.kernel_dill else None,
        aot_output_path = app_info.aot_output.path if app_info.aot_output else None,
        aot_dst = "lib/libapp.so",
        icu_data_path = icu_data.path,
        engine_basenames = [(f.path, f.basename) for f in engine_files],
        native_basenames = [(lib.path, lib.basename) for lib in native_libs],
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
        if not f.path.endswith(".h") and not f.path.endswith(".cc"):
            runner_binary = f
            break
    if not runner_binary and runner_files:
        runner_binary = runner_files[0]
    if not runner_binary:
        fail("No runner binary found in runner target.")

    copies.append({"src": runner_binary.path, "dst": app_name})

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
        mnemonic = "FlutterLinuxBundle",
        progress_message = "Bundling Linux app %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([bundle_dir]))]

flutter_linux_bundle_rule = rule(
    implementation = _flutter_linux_bundle_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing the compiled artifacts.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "runner": attr.label(
            doc = "A pre-compiled runner executable (from flutter_linux_runner_lib_gen or cc_binary).",
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
    doc = "Assembles a Linux application directory from a pre-compiled runner and flutter_application artifacts.",
)
