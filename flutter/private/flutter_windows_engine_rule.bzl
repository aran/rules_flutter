"""Windows Flutter engine rule.

Re-exports the Flutter Windows engine from the toolchain as both DefaultInfo
and CcInfo, making the engine usable as a cc_binary dep for Approach 3 users.

DefaultInfo provides the engine DLL, import library, headers, and C++ wrapper.
CcInfo provides proper linking/compilation context so cc_binary can depend on
this target.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter/private:engine_helpers.bzl", "find_engine_header_dir")

def _flutter_windows_engine_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    if flutter_sdk_info.engine_library == None:
        fail(
            "No Windows engine library in the Flutter toolchain: it targets a " +
            "non-Windows platform. Build for Windows with a Windows-targeting " +
            "--platforms (rules_flutter provides " +
            "@rules_flutter//flutter/platforms:windows_x64 as a convenience).",
        )

    engine_files = flutter_sdk_info.engine_library.files.to_list()

    # Separate engine files into DLL, import lib, headers, and wrapper sources.
    engine_dll = None
    engine_import_lib = None
    header_files = []
    wrapper_include_dir = None
    for f in engine_files:
        if f.basename == "flutter_windows.dll":
            engine_dll = f
        elif f.basename == "flutter_windows.dll.lib":
            engine_import_lib = f
        elif f.path.endswith(".h"):
            header_files.append(f)
            if not wrapper_include_dir and "/include/flutter/" in f.path:
                idx = f.path.index("/include/flutter/")
                wrapper_include_dir = f.path[:idx + len("/include")]
        elif f.path.endswith(".cc"):
            # Wrapper .cc files are needed as inputs (they #include each other).
            header_files.append(f)

    if not engine_dll or not engine_import_lib:
        fail(
            "No flutter_windows.dll/.lib in the resolved Flutter engine: it " +
            "targets a non-Windows platform. Build for Windows with a " +
            "Windows-targeting --platforms (rules_flutter provides " +
            "@rules_flutter//flutter/platforms:windows_x64 as a convenience).",
        )

    # Build CcInfo for cc_binary compatibility.
    cc_toolchain = ctx.attr._cc_toolchain[cc_common.CcToolchainInfo]
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
    )

    # Create library_to_link with import library for Windows.
    lib_to_link = cc_common.create_library_to_link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        dynamic_library = engine_dll,
        interface_library = engine_import_lib,
    )
    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset([lib_to_link]),
    )
    linking_context = cc_common.create_linking_context(
        linker_inputs = depset([linker_input]),
    )

    # Create compilation context with engine header include paths.
    header_dir = find_engine_header_dir(engine_files, "flutter_windows.h")
    includes = []
    if header_dir:
        includes.append(header_dir)
    if wrapper_include_dir:
        includes.append(wrapper_include_dir)

    compilation_context = cc_common.create_compilation_context(
        headers = depset(header_files),
        includes = depset(includes),
    )

    cc_info = CcInfo(
        compilation_context = compilation_context,
        linking_context = linking_context,
    )

    return [
        DefaultInfo(files = flutter_sdk_info.engine_library.files),
        cc_info,
    ]

flutter_windows_engine_rule = rule(
    implementation = _flutter_windows_engine_impl,
    attrs = {
        "_cc_toolchain": attr.label(
            default = "@bazel_tools//tools/cpp:current_cc_toolchain",
        ),
    },
    fragments = ["cpp"],
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
        "@rules_flutter//flutter:toolchain_type",
    ],
    doc = "Exposes the Flutter Windows engine (flutter_windows.dll + headers + C++ wrapper) from the toolchain, with CcInfo for cc_binary compatibility.",
)
