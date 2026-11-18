"""Compiles a Windows runner's resource script (`Runner.rc`) into the `.res` the linker embeds.

The script carries the executable's icon and version information. It is compiled
with the resource compiler registered for Bazel's own toolchain type
(`@bazel_tools//tools/res:toolchain_type`), the one `windows_resources` from
`@bazel_tools//tools/res:win_res.bzl` uses: on a Windows host with Visual Studio,
Bazel registers the Windows SDK's `rc.exe` itself. That rule passes no
preprocessor defines, and `flutter create`'s `Runner.rc` takes the app's version
from them, so this rule invokes the same toolchain with `/d`, defining them
from `build_name` and `build_number` (checked by `app_version.bzl`).
"""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE", "find_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter/private:app_version.bzl", "windows_version")
load("//flutter/private:application_version.bzl", "APPLICATION_VERSION_ATTR", "application_version", "version_names")

visibility("//flutter/...")

WINDOWS_RESOURCE_COMPILER_TOOLCHAIN_TYPE = "@bazel_tools//tools/res:toolchain_type"

def windows_version_defines(ctx):
    """The `FLUTTER_VERSION*` defines `flutter create`'s `Runner.rc` reads.

    From the rule's `build_name` and `build_number`, or its application's, as `flutter build
    windows` defines them for its CMake build.

    Args:
        ctx: The context of a rule with `build_name` and `build_number`, and
            an `application` attribute (`APPLICATION_VERSION_ATTR`) that may be unset.

    Returns:
        A list of `NAME=value` defines.
    """
    given = application_version(ctx.label, ctx.attr.application, ctx.attr.build_name, ctx.attr.build_number)
    version = windows_version(given.build_name, given.build_number, version_names(given.settings))
    if version.error:
        fail("%s: %s" % (ctx.label, version.error))
    return [
        "FLUTTER_VERSION=\"%s\"" % version.version,
        "FLUTTER_VERSION_MAJOR=%d" % version.major,
        "FLUTTER_VERSION_MINOR=%d" % version.minor,
        "FLUTTER_VERSION_PATCH=%d" % version.patch,
        "FLUTTER_VERSION_BUILD=%d" % version.build,
    ]

# `build_name` and `build_number`, for a rule that defines the version, and the
# `application` it takes them from when it sets none.
WINDOWS_VERSION_ATTRS = APPLICATION_VERSION_ATTR | {
    "build_name": attr.string(
        doc = "The version, `MAJOR.MINOR.PATCH`, as `flutter build --build-name` " +
              "takes it. Empty is `flutter create`'s `1.0.0`.",
    ),
    "build_number": attr.string(
        doc = "The build number, as `flutter build --build-number` takes it. " +
              "Empty is `flutter create`'s `1`.",
    ),
}

def _include_environment(ctx):
    """The C++ compiler's environment, for the header search path (`INCLUDE`).

    `Runner.rc` includes `winres.h` from the Windows SDK. The resource compiler
    finds it through `INCLUDE`, which the C++ toolchain sets for its compiler,
    as CMake runs both in one developer environment. Without a C++ toolchain
    for the target there is no runner to link either, so that error is left to
    the runner.
    """
    cc_toolchain = find_cc_toolchain(ctx, mandatory = False)
    if not cc_toolchain:
        return {}
    feature_configuration = cc_common.configure_features(ctx = ctx, cc_toolchain = cc_toolchain)
    return cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_compile,
        variables = cc_common.create_compile_variables(
            feature_configuration = feature_configuration,
            cc_toolchain = cc_toolchain,
        ),
    )

def _flutter_windows_resources_impl(ctx):
    rc_exe = ctx.toolchains[WINDOWS_RESOURCE_COMPILER_TOOLCHAIN_TYPE].win_rc_info.rc_exe
    if not rc_exe:
        fail((
            "%s: no Windows resource compiler is registered for this build, so " +
            "%s cannot be compiled into the runner (its icon, version information).\n" +
            "On a Windows host with Visual Studio Build Tools, Bazel registers the " +
            "Windows SDK's rc.exe itself. Building for Windows from another host " +
            "needs one registered in your MODULE.bazel: wrap a resource compiler " +
            "such as llvm-rc in `windows_resource_compiler_toolchain` from " +
            "@bazel_tools//tools/res:winsdk_toolchain.bzl and register a " +
            "`toolchain` of type @bazel_tools//tools/res:toolchain_type for it."
        ) % (ctx.label, ctx.file.rc.short_path))

    rc = ctx.file.rc
    res = ctx.actions.declare_file(ctx.label.name + ".res")
    args = ctx.actions.args()
    args.add("/nologo")
    args.add(rc.dirname, format = "/i%s")
    args.add_all(windows_version_defines(ctx) + ctx.attr.defines, format_each = "/d%s")

    # rc.exe's output option.
    args.add(res, format = "/fo%s")  # typos:ignore-line
    args.add(rc)
    ctx.actions.run(
        executable = rc_exe,
        arguments = [args],
        inputs = [rc] + ctx.files.srcs,
        outputs = [res],
        env = _include_environment(ctx),
        mnemonic = "WindowsRc",
        toolchain = WINDOWS_RESOURCE_COMPILER_TOOLCHAIN_TYPE,
        progress_message = "Compiling Windows resources %{input}",
    )

    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        additional_inputs = depset([res]),
        user_link_flags = depset([res.path]),
    )
    return [
        DefaultInfo(files = depset([res])),
        CcInfo(linking_context = cc_common.create_linking_context(
            linker_inputs = depset([linker_input]),
        )),
    ]

flutter_windows_resources = rule(
    implementation = _flutter_windows_resources_impl,
    attrs = WINDOWS_VERSION_ATTRS | {
        "rc": attr.label(
            doc = "The resource script, `windows/runner/Runner.rc` in a `flutter create` tree.",
            mandatory = True,
            allow_single_file = [".rc"],
        ),
        "srcs": attr.label_list(
            doc = "The files the script reads: headers it includes and the icon it names.",
            allow_files = True,
        ),
        "defines": attr.string_list(
            doc = "Further preprocessor defines, `NAME=value`, beside the " +
                  "`FLUTTER_VERSION*` ones `build_name` and `build_number` give.",
        ),
    },
    fragments = ["cpp"],
    toolchains = [
        WINDOWS_RESOURCE_COMPILER_TOOLCHAIN_TYPE,
        config_common.toolchain_type(CC_TOOLCHAIN_TYPE, mandatory = False),
    ],
    doc = """Compiles a Windows resource script (`.rc`) for a runner to link.

Provides `CcInfo` whose linking context carries the compiled `.res`, so it goes in
`flutter_windows_runner_lib_gen`'s `resources` or a `cc_binary`'s `deps`. Uses the
resource compiler registered for `@bazel_tools//tools/res:toolchain_type` and fails
when none is.""",
)
