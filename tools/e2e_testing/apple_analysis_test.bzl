"""Analysis tests of how the Apple app macros and their wrappers sit in a build.

Both are about `bazel build //...` and `bazel test //...` with flags or a
target platform the iOS rules must still cope with.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo")
load("//flutter:dev_files.bzl", "DEV_FILES_GROUP", "flutter_dev_files_aspect")
load("//flutter:providers.bzl", "FlutterApplicationInfo")

def _analyses_impl(ctx):
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    asserts.true(env, len(files) > 0, "the target analyses and forwards files")
    return analysistest.end(env)

def _skipped_impl(ctx):
    env = analysistest.begin(ctx)

    # Bazel does not analyse a target that is incompatible with the platform,
    # nor a test of it: it reports the test SKIPPED. Getting here means the
    # target was analysed for a platform it declares it is not for.
    asserts.true(
        env,
        False,
        ("%s was analysed, so Bazel found it compatible with the platform; it " +
         "should be skipped.") % analysistest.target_under_test(env).label,
    )
    return analysistest.end(env)

def _program_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, DartAnalyzableInfo in target, "the app passes on its program's DartAnalyzableInfo")
    if DartAnalyzableInfo in target:
        info = target[DartAnalyzableInfo]
        paths = [f.short_path for f in info.entry_srcs.to_list() + info.dart_info.srcs]
        asserts.true(
            env,
            ctx.attr.main in paths,
            "the program's files include its main, %s: %s" % (ctx.attr.main, paths),
        )
    return analysistest.end(env)

_program_dbg_test = analysistest.make(
    _program_impl,
    attrs = {"main": attr.string(mandatory = True)},
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
)

# The `-c` and `--@rules_flutter//flutter:profile` pairs a command line can
# carry. The simulator wrappers build debug mode whatever the pair, so each one
# must analyse; the app they wrap refuses profile outside `-c opt` and
# refuses release mode for the simulator, which is what they exist to avoid.
def _analyses_under(mode, profile):
    return analysistest.make(
        _analyses_impl,
        config_settings = {
            "//command_line_option:compilation_mode": mode,
            str(Label("//flutter:profile")): profile,
        },
    )

# Rules are exported by a global name each.
_dbg_test = _analyses_under("dbg", False)
_dbg_profile_test = _analyses_under("dbg", True)
_fastbuild_test = _analyses_under("fastbuild", False)
_fastbuild_profile_test = _analyses_under("fastbuild", True)
_opt_test = _analyses_under("opt", False)
_opt_profile_test = _analyses_under("opt", True)

# Each `flutter_application` below a target, with the output directory of the
# configuration it is analysed in.
_ApplicationConfigurationsInfo = provider(
    doc = "The `flutter_application`s below a target, each as `<label> in <bin dir>`.",
    fields = {"applications": "depset of strings"},
)

def _application_configurations_aspect_impl(target, ctx):
    direct = []
    if FlutterApplicationInfo in target:
        direct.append("%s in %s" % (target.label, ctx.bin_dir.path))
    transitive = []
    for attr_name in dir(ctx.rule.attr):
        attr = getattr(ctx.rule.attr, attr_name)
        for dep in attr if type(attr) == "list" else [attr]:
            if type(dep) == "Target" and _ApplicationConfigurationsInfo in dep:
                transitive.append(dep[_ApplicationConfigurationsInfo].applications)
    return [_ApplicationConfigurationsInfo(applications = depset(direct, transitive = transitive))]

_application_configurations_aspect = aspect(
    implementation = _application_configurations_aspect_impl,
    attr_aspects = ["*"],
)

def _one_application_configuration_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    applications = target[_ApplicationConfigurationsInfo].applications.to_list()

    # Counted by configuration: what forwards the application (iOS's
    # intermediates) is another label in the same one.
    configurations = {a.rpartition(" in ")[2]: None for a in applications}
    asserts.equals(
        env,
        1,
        len(configurations),
        ("%s should reach its flutter_application in the one configuration " +
         "its bundle is built in; a second configuration analyses and builds " +
         "the application and its native code again: %s") % (target.label, applications),
    )
    return analysistest.end(env)

_one_application_configuration_dbg_test = analysistest.make(
    _one_application_configuration_impl,
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
    extra_target_under_test_aspects = [_application_configurations_aspect],
)

_COMMAND_LINES = {
    "dbg": _dbg_test,
    "dbg_profile": _dbg_profile_test,
    "fastbuild": _fastbuild_test,
    "fastbuild_profile": _fastbuild_profile_test,
    "opt": _opt_test,
    "opt_profile": _opt_profile_test,
}

# `dbg` because the iOS simulator refuses every other mode, and that refusal
# would fail analysis before compatibility was in question.
_analyses_dbg_test = analysistest.make(
    _analyses_impl,
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
)
_skipped_dbg_test = analysistest.make(
    _skipped_impl,
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
)

_skipped_linux_test = analysistest.make(
    _skipped_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:platforms": [str(Label("//tools/e2e_testing:linux_arm64"))],
    },
)

def command_line_tests(name, target, profile):
    """Analysis tests of `target` under each `-c`, with the profile flag on or off.

    Args:
        name: Prefix of the tests' names.
        target: A label that must analyse under each of them.
        profile: Whether the command line carries the profile flag.

    Returns:
        The tests' labels.
    """
    tests = []
    for suffix, rule in _COMMAND_LINES.items():
        if suffix.endswith("_profile") != profile:
            continue
        rule(name = "%s_%s_test" % (name, suffix), target_under_test = target)
        tests.append(":%s_%s_test" % (name, suffix))
    return tests

def analyses_test(name, target):
    """A test that `target` analyses in `-c dbg`: the control of `skipped_test`.

    Args:
        name: The test's name.
        target: The target that must be compatible.
    """
    _analyses_dbg_test(name = name, target_under_test = target)

def program_test(name, target, main):
    """A test that `target`, an app, analyses in `-c dbg` and passes on its program.

    Like `analyses_test`, it passes by being skipped if `target` is
    incompatible with the platform.

    Args:
        name: The test's name.
        target: The app.
        main: The workspace path of the program's `main`, which must be among
            the files it passes on.
    """
    _program_dbg_test(name = name, target_under_test = target, main = main)

def skipped_test(name, target, on_linux = False):
    """A test that passes only by being skipped: `target` is incompatible.

    Bazel skips a target incompatible with the platform and every test of it,
    and a skipped test passes. If `target` is analysed instead, the test body
    runs and fails.

    Args:
        name: The test's name.
        target: The target that must be incompatible.
        on_linux: Build for `//tools/e2e_testing:linux_arm64`, not the default platform.
    """
    rule = _skipped_linux_test if on_linux else _skipped_dbg_test
    rule(name = name, target_under_test = target)

def one_application_configuration_test(name, target):
    """A test that `target`, an app, reaches its `flutter_application` in one configuration, in `-c dbg`.

    Every edge from the app to the application, the bundle's and its checks',
    must arrive in the configuration the bundle is built in. An edge that
    arrives in another one analyses the application again there, and a build
    of the app (the dev tool's included) compiles its native code twice.

    Args:
        name: The test's name.
        target: The app.
    """
    _one_application_configuration_dbg_test(name = name, target_under_test = target)

def _split_debug_info_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    groups = target[OutputGroupInfo]
    symbols = groups.debug_info.to_list() if "debug_info" in groups else []
    asserts.equals(
        env,
        [ctx.attr.symbols],
        [f.basename for f in symbols],
        ("%s's `debug_info` output group should hold one split debug info " +
         "file, named as `flutter build` names it") % target.label,
    )

    # The shipped App binary's dSYM is made in the configuration the bundle
    # builds its application in, from that application's snapshot.
    shipped = [
        f
        for f in (groups.dsyms.to_list() if "dsyms" in groups else [])
        if f.path.endswith("/App.framework.dSYM/Contents/Resources/DWARF/App")
    ]
    asserts.equals(env, 1, len(shipped), "the bundle has the dSYM of one App binary: %s" % shipped)
    if symbols and len(shipped) == 1:
        asserts.equals(
            env,
            shipped[0].root.path,
            symbols[0].root.path,
            ("the `.symbols` should be the application's in the configuration " +
             "whose snapshot the bundle ships, as its App binary is"),
        )
    return analysistest.end(env)

_SPLIT_DEBUG_INFO_SETTINGS = {
    "//command_line_option:apple_generate_dsym": True,
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:obfuscate")): True,
    str(Label("@rules_dart//dart:split_debug_info")): True,
}

_split_debug_info_test = analysistest.make(
    _split_debug_info_impl,
    attrs = {"symbols": attr.string(mandatory = True)},
    config_settings = _SPLIT_DEBUG_INFO_SETTINGS,
)

_split_debug_info_ios_device_test = analysistest.make(
    _split_debug_info_impl,
    attrs = {"symbols": attr.string(mandatory = True)},
    config_settings = _SPLIT_DEBUG_INFO_SETTINGS | {"//command_line_option:ios_multi_cpus": ["arm64"]},
)

def split_debug_info_test(name, target, symbols, ios_device = False):
    """A test that `target`, an app, has its program's `.symbols` in its `debug_info` output group.

    Built `-c opt`, obfuscated, with `--@rules_dart//dart:split_debug_info`
    and `--apple_generate_dsym`. The file must be the one of the application
    in the configuration its shipped App binary (whose dSYM the bundle has)
    is built in: another configuration compiles another snapshot.

    Args:
        name: The test's name.
        target: The app.
        symbols: The file's basename, as `flutter build` names it
            (`app.darwin-arm64.symbols`).
        ios_device: Build for an arm64 iOS device.
    """
    rule = _split_debug_info_ios_device_test if ios_device else _split_debug_info_test
    rule(name = name, target_under_test = target, symbols = symbols)

def _dev_config_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = getattr(target[OutputGroupInfo], DEV_FILES_GROUP).to_list()
    asserts.equals(
        env,
        [ctx.attr.dev_config],
        [f.basename for f in files if f.basename.endswith("_dev_config.json")],
        ("the dev files of %s should hold the dev config of the application " +
         "it runs, and no other: the dev tool reads the one in the app's " +
         "configuration") % target.label,
    )
    return analysistest.end(env)

_dev_config_test = analysistest.make(
    _dev_config_impl,
    attrs = {"dev_config": attr.string(mandatory = True)},
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
    extra_target_under_test_aspects = [flutter_dev_files_aspect],
)

def dev_config_test(name, target, dev_config):
    """A test that the dev files the dev tool builds through `target` hold one dev config, in `-c dbg`.

    The dev tool builds `flutter_dev_files_aspect`'s group through the app and
    reads the `_dev_config.json` in the configuration the app reports. That
    must be the one of the application the app runs, alone: an app over a
    `flutter_application_variant` reaches the application it varies too, in
    the same configuration.

    Args:
        name: The test's name.
        target: The app.
        dev_config: The basename of the dev config (`<application>_dev_config.json`).
    """
    _dev_config_test(name = name, target_under_test = target, dev_config = dev_config)
