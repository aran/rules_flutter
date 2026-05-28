"""Flutter shader compilation via impellerc.

Compiles .frag/.glsl shader files to .iplr (Impeller IR) format using the
impellerc offline shader processor. Platform-specific runtime stages are
selected based on the target platform.
"""

# Platform-specific impellerc flags. Flutter's shader compiler targets:
# - iOS: Metal only
# - macOS: SKSL + Metal
# - Android/Linux/Windows: SKSL + GLES + GLES3 + Vulkan
# - Web: SKSL only (with --json)
SHADER_PLATFORM_FLAGS = {
    "ios": ["--runtime-stage-metal"],
    "macos": ["--sksl", "--runtime-stage-metal"],
    "android": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "linux": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "windows": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "web": ["--sksl"],
}

def get_shader_platform_flags(target_platform):
    """Get the impellerc flags for a target platform.

    Args:
        target_platform: One of "ios", "macos", "android", "linux", "windows", "web".

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
        shader,
        output,
        target_platform,
        is_web = False):
    """Compile a single shader file to .iplr format using impellerc.

    Args:
        ctx: Rule context.
        impellerc: The impellerc executable File.
        shader_lib: List of shader_lib include Files.
        shader: The input .frag/.glsl shader File.
        output: The output .iplr File.
        target_platform: Target platform string ("ios", "macos", "android", "linux", "windows", "web").
        is_web: If True, emit JSON format (for web targets).
    """
    platform_flags = get_shader_platform_flags(target_platform)

    # Find the shader_lib root directory from any file in the filegroup.
    shader_lib_dir = None
    for f in shader_lib:
        if "/shader_lib/" in f.path:
            idx = f.path.find("/shader_lib/")
            shader_lib_dir = f.path[:idx + len("/shader_lib")]
            break

    # impellerc requires a --spirv intermediate output alongside --sl when
    # using runtime stages (not platform flags). Declare it as a secondary output.
    spirv_output = ctx.actions.declare_file(output.path + ".spirv")

    args = ctx.actions.args()
    for flag in platform_flags:
        args.add(flag)
    args.add("--iplr")
    if is_web:
        args.add("--json")
    args.add("--sl=" + output.path)
    args.add("--spirv=" + spirv_output.path)
    args.add("--input=" + shader.path)
    args.add("--input-type=frag")
    args.add("--include=" + shader.dirname)
    if shader_lib_dir:
        args.add("--include=" + shader_lib_dir)

    ctx.actions.run(
        executable = impellerc,
        arguments = [args],
        inputs = [shader] + shader_lib,
        outputs = [output, spirv_output],
        mnemonic = "FlutterShaderCompile",
        progress_message = "Compiling shader %s for %s" % (shader.short_path, target_platform),
    )
