"""Tests for the Android bundle, built for each Android platform.

`android_binary` builds its dependencies once for each of `--@rules_android//flags:android_platforms`
and packages what each build brings. The bundle takes its ABI from the
platform it is built for, so an APK for several ABIs carries the `libapp.so`
and native libraries of each, every one the ABI of its own `lib/` directory.
Over `//flutter/tests/shared_code_asset_fixture:app_android_bundle`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_android//providers:providers.bzl", "AndroidNativeLibsInfo")

_BUNDLE = "//flutter/tests/shared_code_asset_fixture:app_android_bundle"

_RELEASE = {"//command_line_option:compilation_mode": "opt"}

def _platform(label):
    return {"//command_line_option:platforms": str(Label(label))}

def _libraries_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    # One zip of the APK's libraries, which android_binary takes as an
    # aar_import's: the same file as the `native_libs` group.
    packaged = target[AndroidNativeLibsInfo].native_libs.to_list()
    asserts.equals(env, 1, len(packaged), "one zip of native libraries: %s" % packaged)
    asserts.equals(env, packaged, target[OutputGroupInfo].native_libs.to_list())

    # The AOT code is `libapp.so` whatever gen_snapshot called its output, next
    # to the application's native libraries and its code assets, which the
    # action reads with their libraries and without the data assets.
    packaging = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterAndroidNativeLibs"]
    asserts.equals(env, 1, len(packaging), "one packaging action")
    if packaging:
        argv = packaging[0].argv
        names = []
        for i, arg in enumerate(argv):
            if arg == "--library-as":
                names.append(argv[i + 1])
            elif arg == "--library":
                names.append(argv[i + 1].rsplit("/", 1)[-1])
            elif arg in ("--code-asset", "--candidate") and argv[i + 2] == "dynamic_loading_bundle":
                names.append(argv[i + 3].rsplit("/", 1)[-1])
        asserts.equals(env, sorted(ctx.attr.libraries), sorted({n: None for n in names}.keys()), "each library once")
        asserts.equals(env, "code", argv[argv.index("--holds") + 1], "the libraries view, no data assets")
        asserts.equals(env, ctx.attr.abi, argv[argv.index("--abi") + 1])

        # What the APK takes is the packaged zip with every library stripped,
        # as a Gradle build strips what it packages.
        strips = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterStripNativeLibs"]
        asserts.equals(env, 1, len(strips), "one strip of the libraries")
        if strips:
            asserts.equals(env, packaging[0].outputs.to_list(), [f for f in strips[0].inputs.to_list() if f in packaging[0].outputs.to_list()])
            asserts.equals(env, packaged, strips[0].outputs.to_list())

    # Every library is checked against the ABI of the platform it was built
    # for: that ABI's name and ELF machine, not another's.
    validations = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterValidateNativeLibs"
    ]
    asserts.equals(env, 1, len(validations), "one validation of the libraries")
    if validations:
        argv = validations[0].argv
        asserts.true(
            env,
            ctx.attr.abi in argv and str(ctx.attr.elf_machine) in argv,
            "validates for %s (machine %d): %s" % (ctx.attr.abi, ctx.attr.elf_machine, argv),
        )

        # A 64-bit ABI's devices can have 16 KB pages, and refuse a library
        # aligned for 4 KB ones.
        asserts.equals(
            env,
            ctx.attr.sixteen_kb,
            "--min-load-align" in argv and "16384" in argv,
            "checks 16 KB alignment: %s" % argv,
        )

        # The validation is a requirement of the build, not an output nobody
        # asks for.
        stamps = getattr(target[OutputGroupInfo], "_validation").to_list()
        asserts.true(
            env,
            validations[0].outputs.to_list()[0] in stamps,
            "the validation is a requirement of the target: %s" % stamps,
        )

    # Nothing in the bundle needs a POSIX shell: its actions run on whatever
    # host the exec-tools toolchain resolves, a Windows one included.
    shells = [
        a.mnemonic
        for a in analysistest.target_actions(env)
        if a.argv and a.argv[0].split("/")[-1] in ("bash", "sh", "cmd.exe")
    ]
    asserts.equals(env, [], shells, "actions that run a shell")
    return analysistest.end(env)

_ATTRS = {
    "abi": attr.string(mandatory = True),
    "elf_machine": attr.int(mandatory = True),
    "libraries": attr.string_list(mandatory = True),
    "sixteen_kb": attr.bool(mandatory = True),
}

_arm64_test = analysistest.make(
    _libraries_impl,
    attrs = _ATTRS,
    config_settings = _platform("@rules_android//:arm64-v8a") | _RELEASE,
)

# An app that runs only on 4 KB devices, or in Android 16's page size
# compatibility mode, need not be 16 KB-aligned.
_arm64_4kb_allowed_test = analysistest.make(
    _libraries_impl,
    attrs = _ATTRS,
    config_settings = _platform("@rules_android//:arm64-v8a") | _RELEASE | {
        str(Label("//flutter:allow_4kb_aligned_native_libraries")): True,
    },
)

_armv7_test = analysistest.make(
    _libraries_impl,
    attrs = _ATTRS,
    config_settings = _platform("@rules_android//:armeabi-v7a") | _RELEASE,
)

_x86_64_test = analysistest.make(
    _libraries_impl,
    attrs = _ATTRS,
    config_settings = _platform("@rules_android//:x86_64") | _RELEASE,
)

def _not_android_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "which is not Android arm, arm64 or x86_64")
    asserts.expect_failure(env, "--@rules_android//flags:android_platforms")
    return analysistest.end(env)

_not_android_test = analysistest.make(
    _not_android_impl,
    expect_failure = True,
    config_settings = _platform("//flutter/platforms:linux_x64") | {"//command_line_option:compilation_mode": "dbg"},
)

def android_bundle_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    _arm64_test(
        name = name + "_arm64",
        target_under_test = _BUNDLE,
        abi = "arm64-v8a",
        elf_machine = 183,
        libraries = ["libapp.so", "libcombined.so"],
        sixteen_kb = True,
        target_compatible_with = ["@platforms//os:macos"],
    )
    _arm64_4kb_allowed_test(
        name = name + "_arm64_4kb_allowed",
        target_under_test = _BUNDLE,
        abi = "arm64-v8a",
        elf_machine = 183,
        libraries = ["libapp.so", "libcombined.so"],
        sixteen_kb = False,
        target_compatible_with = ["@platforms//os:macos"],
    )
    _armv7_test(
        name = name + "_armv7",
        target_under_test = _BUNDLE,
        abi = "armeabi-v7a",
        elf_machine = 40,
        libraries = ["libapp.so", "libcombined.so"],
        sixteen_kb = False,
        target_compatible_with = ["@platforms//os:macos"],
    )
    _x86_64_test(
        name = name + "_x86_64",
        target_under_test = _BUNDLE,
        abi = "x86_64",
        elf_machine = 62,
        libraries = ["libapp.so", "libcombined.so"],
        sixteen_kb = True,
        target_compatible_with = ["@platforms//os:macos"],
    )
    _not_android_test(
        name = name + "_not_android",
        target_under_test = _BUNDLE + "_any_platform",
        target_compatible_with = ["@platforms//os:macos"],
    )
    native.test_suite(
        name = name,
        tests = [name + "_arm64", name + "_arm64_4kb_allowed", name + "_armv7", name + "_x86_64", name + "_not_android"],
    )
