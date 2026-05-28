"""Shared helper for compiling C++ desktop runners using cc_common."""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

def compile_and_link_runner(
        ctx,
        name,
        srcs,
        engine_library_file,
        engine_import_library = None,
        engine_header_files = [],
        engine_include_dir = None,
        extra_compile_flags = [],
        extra_link_flags = [],
        extra_defines = [],
        additional_srcs = [],
        system_include_dirs = [],
        additional_inputs = []):
    """Compile C++ sources and link into an executable using cc_common.

    Uses Bazel's hermetic CC toolchain for both compilation and linking.

    Args:
        ctx: Rule context (must have _cc_toolchain attr and cpp fragment).
        name: Base name for intermediate artifacts and the output binary.
        srcs: List of C++ source Files.
        engine_library_file: The engine .so or .dll File.
        engine_import_library: Windows-only: the .dll.lib import library File.
        engine_header_files: Header Files from the engine (for inputs).
        engine_include_dir: Directory string for engine headers (-I path).
        extra_compile_flags: Additional compiler flags.
        extra_link_flags: Additional linker flags (e.g., -Wl,-rpath).
        extra_defines: Local defines (e.g., GTK_APP_ID, NDEBUG).
        additional_srcs: Additional source files to compile (e.g., native registrant).
        system_include_dirs: System include directories passed to cc_common.compile(system_includes=...).
        additional_inputs: Additional input files (e.g., sysroot files).

    Returns:
        The executable File produced by cc_common.link().
    """
    cc_toolchain = ctx.attr._cc_toolchain[cc_common.CcToolchainInfo]
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
    )

    all_srcs = srcs + additional_srcs

    includes = []
    if engine_include_dir:
        includes.append(engine_include_dir)

    # Separate -I flags into includes (relative) for cc_common.
    include_dirs = []
    other_flags = []
    for flag in extra_compile_flags:
        if flag.startswith("-I"):
            include_dirs.append(flag[2:])
        else:
            other_flags.append(flag)

    all_additional_inputs = list(engine_header_files) + list(additional_inputs)

    (_compilation_context, compilation_outputs) = cc_common.compile(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        name = name,
        srcs = all_srcs,
        includes = includes + include_dirs,
        system_includes = system_include_dirs,
        local_defines = extra_defines,
        user_compile_flags = other_flags,
        additional_inputs = all_additional_inputs,
    )

    # Build a linking context for the engine shared library so the
    # toolchain's linker knows how to find and link against it.
    engine_lib_to_link = cc_common.create_library_to_link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        dynamic_library = engine_library_file,
        interface_library = engine_import_library,
    )
    engine_linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset([engine_lib_to_link]),
    )
    engine_linking_context = cc_common.create_linking_context(
        linker_inputs = depset([engine_linker_input]),
    )

    # Link step: produces the executable using the hermetic CC toolchain.
    linking_outputs = cc_common.link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        name = name,
        compilation_outputs = compilation_outputs,
        linking_contexts = [engine_linking_context],
        user_link_flags = extra_link_flags,
        output_type = "executable",
        additional_inputs = depset(additional_inputs),
    )

    return linking_outputs.executable
