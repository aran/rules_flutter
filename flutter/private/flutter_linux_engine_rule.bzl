"""Linux Flutter engine rule.

Re-exports the Flutter Linux engine from the toolchain as both DefaultInfo
and CcInfo, making the engine usable as a cc_binary dep for Approach 3 users.

DefaultInfo provides the engine .so + headers.
CcInfo provides proper linking context so cc_binary can depend on this target.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter/private:engine_helpers.bzl", "find_engine_header_dir")

def _flutter_linux_engine_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    if flutter_sdk_info.engine_library == None:
        fail(
            "No Linux engine library in the Flutter toolchain: it targets a " +
            "non-Linux platform. Build for Linux with a Linux-targeting " +
            "--platforms (rules_flutter provides " +
            "@rules_flutter//flutter/platforms:linux_x64 as a convenience).",
        )

    engine_files = flutter_sdk_info.engine_library.files.to_list()

    # Separate engine files into .so, headers, etc.
    engine_so = None
    header_files = []
    for f in engine_files:
        if f.basename == "libflutter_linux_gtk.so":
            engine_so = f
        elif f.path.endswith(".h"):
            header_files.append(f)

    if not engine_so:
        fail(
            "No libflutter_linux_gtk.so in the resolved Flutter engine: it " +
            "targets a non-Linux platform. Build for Linux with a " +
            "Linux-targeting --platforms (rules_flutter provides " +
            "@rules_flutter//flutter/platforms:linux_x64 as a convenience).",
        )

    # Build CcInfo for cc_binary compatibility.
    cc_toolchain = ctx.attr._cc_toolchain[cc_common.CcToolchainInfo]
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
    )

    # Create library_to_link for the engine .so.
    lib_to_link = cc_common.create_library_to_link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        dynamic_library = engine_so,
    )
    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset([lib_to_link]),
        user_link_flags = depset(["-Wl,-rpath,$ORIGIN/lib"]),
    )
    linking_context = cc_common.create_linking_context(
        linker_inputs = depset([linker_input]),
    )

    # Create compilation context with engine header include path.
    header_dir = find_engine_header_dir(engine_files, "flutter_linux/flutter_linux.h")
    includes = []
    if header_dir:
        includes.append(header_dir)

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

flutter_linux_engine_rule = rule(
    implementation = _flutter_linux_engine_impl,
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
    doc = "Exposes the Flutter Linux engine (libflutter_linux_gtk.so + headers) from the toolchain, with CcInfo for cc_binary compatibility.",
)
