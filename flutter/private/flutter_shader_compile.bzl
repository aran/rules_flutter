"""Flutter shader compilation via impellerc.

Compiles .frag/.glsl shader files to .iplr (Impeller IR) format using the
impellerc offline shader processor. Platform-specific runtime stages are
selected based on the target platform.
"""

load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter/private:exec_groups.bzl", "PORTABLE")
load("//flutter/private:path_mapping.bzl", "dirname")

# Platform-specific impellerc flags. Flutter's shader compiler targets:
# - iOS: Metal only
# - macOS: SKSL + Metal
# - Android/Linux/Windows: SKSL + GLES + GLES3 + Vulkan
# - Web: SKSL only (with --json)
# - flutter_tester (`flutter test`): SKSL + Vulkan, Impeller's backend there
SHADER_PLATFORM_FLAGS = {
    "ios": ["--runtime-stage-metal"],
    "macos": ["--sksl", "--runtime-stage-metal"],
    "android": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "linux": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "windows": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "web": ["--sksl"],
    "tester": ["--sksl", "--runtime-stage-vulkan"],
}

def get_shader_platform_flags(target_platform):
    """Get the impellerc flags for a target platform.

    Args:
        target_platform: One of "ios", "macos", "android", "linux", "windows", "web",
            "tester".

    Returns:
        List of impellerc flag strings.
    """
    if target_platform not in SHADER_PLATFORM_FLAGS:
        fail("Unknown target platform '%s' for shader compilation. " % target_platform +
             "Supported platforms: %s" % ", ".join(SHADER_PLATFORM_FLAGS.keys()))
    return SHADER_PLATFORM_FLAGS[target_platform]

def flutter_shader_compile_action(
        ctx,
        impellerc,
        shader_lib,
        shader_include_dir,
        shader,
        output,
        target_platform,
        is_web = False,
        includes = [],
        dart = None,
        dart_files = None,
        compile_tool = None,
        require_sksl = False):
    """Compile a single shader file to .iplr format using impellerc.

    Args:
        ctx: Rule context.
        impellerc: The impellerc executable File.
        shader_lib: List of shader_lib include Files.
        shader_include_dir: The directory holding `shader_lib`, impellerc's
            include root (`FlutterExecToolsInfo.shader_include_dir`).
        shader: The input .frag/.glsl shader File.
        output: The output .iplr File.
        target_platform: Target platform string ("ios", "macos", "android", "linux", "windows", "web").
        is_web: If True, emit JSON format (for web targets).
        includes: Files the shader may `#include` — inputs the sandbox
            needs, found relative to the shader's own directory.
        dart: The Dart executable that runs `compile_tool`.
        dart_files: depset of the files `dart` needs.
        compile_tool: `compile_shader.dart`, which retries a shader whose
            SkSL stage fails without it, as `flutter build` does. Used only
            where the flags include SkSL beside other stages.
        require_sksl: Make an SkSL failure an error instead of a warning.
    """
    platform_flags = get_shader_platform_flags(target_platform)

    # impellerc requires a --spirv intermediate output alongside --sl when
    # using runtime stages (not platform flags). Declare it as a secondary output.
    spirv_output = ctx.actions.declare_file(output.basename + ".spirv", sibling = output)

    args = ctx.actions.args()
    for flag in platform_flags:
        args.add(flag)
    args.add("--iplr")
    if is_web:
        args.add("--json")
    args.add(output, format = "--sl=%s")
    args.add(spirv_output, format = "--spirv=%s")
    args.add(shader, format = "--input=%s")
    args.add("--input-type=frag")
    args.add_all([shader], map_each = dirname, format_each = "--include=%s")
    args.add(shader_include_dir, format = "--include=%s")

    inputs = [shader] + shader_lib + list(includes)
    retry_possible = "--sksl" in platform_flags and len(platform_flags) > 1
    if retry_possible:
        wrapper_args = ctx.actions.args()
        wrapper_args.add(compile_tool)
        wrapper_args.add("--impellerc", impellerc)
        wrapper_args.add("--shader", shader.short_path)
        if require_sksl:
            wrapper_args.add("--require-sksl")
        wrapper_args.add("--")
        ctx.actions.run(
            executable = dart,
            arguments = [wrapper_args, args],
            inputs = depset(inputs + [impellerc, compile_tool], transitive = [dart_files]),
            outputs = [output, spirv_output],
            mnemonic = "FlutterShaderCompile",
            exec_group = PORTABLE,
            execution_requirements = PATH_MAPPING,
            progress_message = "Compiling shader %s for %s" % (shader.short_path, target_platform),
        )
    else:
        ctx.actions.run(
            executable = impellerc,
            arguments = [args],
            inputs = inputs,
            outputs = [output, spirv_output],
            mnemonic = "FlutterShaderCompile",
            exec_group = PORTABLE,
            execution_requirements = PATH_MAPPING,
            progress_message = "Compiling shader %s for %s" % (shader.short_path, target_platform),
        )
