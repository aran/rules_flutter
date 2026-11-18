"""Tests of `flutter_android_plugin_libs`: an app links the plugins it uses, and checks those only.

Over `//flutter/tests/android_plugin_libs_fixture`, where three plugins each
have an Android library and `app_uses_<n>` depends on plugin `<n>` alone.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:flutter_android_plugin_libs.bzl", "FlutterAndroidPluginNativeLibsInfo")

_FIXTURE = "//flutter/tests/android_plugin_libs_fixture:"

def _linked_jars(target):
    return sorted([jar.basename for jar in target[JavaInfo].transitive_runtime_jars.to_list()])

def _links_only_its_plugins_impl(ctx):
    """An app that depends on plugin A links A's library, and not B's or the other's."""
    env = analysistest.begin(ctx)
    asserts.equals(env, ["liblib_a.jar"], _linked_jars(analysistest.target_under_test(env)))
    return analysistest.end(env)

_links_only_its_plugins_test = analysistest.make(_links_only_its_plugins_impl)

def _checks_what_it_links_impl(ctx):
    """An app that links plugin A fails for what A's Gradle build declares, naming it."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, '"g:needed_by_a:2.0",  # declared by package:plugin_a 1.0; missing')
    asserts.expect_failure(env, "bazel run //app:a_maven_artifacts` prints the complete block for the plugins this app links")
    return analysistest.end(env)

_checks_what_it_links_test = analysistest.make(_checks_what_it_links_impl, expect_failure = True)

def _takes_one_application_impl(ctx):
    """`deps` that lists two applications fails, saying it takes one."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "lists 2 targets; it takes one `flutter_application`")
    return analysistest.end(env)

_takes_one_application_test = analysistest.make(_takes_one_application_impl, expect_failure = True)

def _ignores_what_it_does_not_link_impl(ctx):
    """An app builds whatever plugins the lock lists, when the ones it links are satisfied.

    The hub's Maven data says plugins A and B lack artifacts; the app links
    neither, so it neither fails nor links them.
    """
    env = analysistest.begin(ctx)
    asserts.equals(env, ["liblib_ok.jar"], _linked_jars(analysistest.target_under_test(env)))
    return analysistest.end(env)

_ignores_what_it_does_not_link_test = analysistest.make(_ignores_what_it_does_not_link_impl)

def _report_content(env):
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FileWrite"]
    asserts.equals(env, 1, len(actions))
    return json.decode(actions[0].content)

def _report_names_only_its_plugins_impl(ctx):
    """An app that links plugin A reports A's artifact, not B's."""
    env = analysistest.begin(ctx)
    content = _report_content(env)
    asserts.equals(env, {
        "g:needed_by_a": {"version": "2.0", "declared_by": ["package:plugin_a 1.0"], "exclusions": [], "managed": False},
    }, content["requirements"])
    asserts.equals(env, "//app:a", content["app"])
    return analysistest.end(env)

_report_names_only_its_plugins_test = analysistest.make(_report_names_only_its_plugins_impl)

def _report_does_not_fail_impl(ctx):
    """An app whose plugins the install all satisfies reports, listing only its own."""
    env = analysistest.begin(ctx)
    content = _report_content(env)
    asserts.equals(env, ["g:installed"], content["requirements"].keys())
    asserts.equals(env, {"g:installed": "1.0"}, content["resolved"])
    asserts.equals(env, ["https://maven.google.com"], content["repositories"])
    return analysistest.end(env)

_report_does_not_fail_test = analysistest.make(_report_does_not_fail_impl)

def _platform(label):
    return {"//command_line_option:platforms": str(Label(label))}

def _checks_native_libs_impl(ctx):
    """The plugins' prebuilt native libraries are checked for the ABI, and for 16 KB pages on a 64-bit one."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    validations = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterValidateNativeLibs"
    ]
    asserts.equals(env, 1, len(validations), "one validation of the native libraries")
    if validations:
        action = validations[0]
        asserts.true(
            env,
            "native_libs.zip" in [f.basename for f in action.inputs.to_list()],
            "the AAR's native libraries are checked: %s" % action.inputs.to_list(),
        )
        argv = action.argv
        asserts.true(env, ctx.attr.abi in argv, "checks for %s: %s" % (ctx.attr.abi, argv))
        asserts.equals(
            env,
            ctx.attr.sixteen_kb,
            "--min-load-align" in argv and "16384" in argv,
            "checks 16 KB alignment: %s" % argv,
        )

        # The check is a requirement of the build, not an output nobody asks for.
        stamps = getattr(target[OutputGroupInfo], "_validation").to_list()
        asserts.true(env, action.outputs.to_list()[0] in stamps, "validation: %s" % stamps)
    return analysistest.end(env)

_CHECK_ATTRS = {
    "abi": attr.string(mandatory = True),
    "sixteen_kb": attr.bool(mandatory = True),
}

_checks_native_libs_arm64_test = analysistest.make(
    _checks_native_libs_impl,
    attrs = _CHECK_ATTRS,
    config_settings = _platform("@rules_android//:arm64-v8a"),
)

_checks_native_libs_armv7_test = analysistest.make(
    _checks_native_libs_impl,
    attrs = _CHECK_ATTRS,
    config_settings = _platform("@rules_android//:armeabi-v7a"),
)

def _java_in_app_configuration_impl(ctx):
    """The plugins' Java is built in the configuration of the library that links it.

    Read in any other, a plugin's Java graph would be configured twice in an
    APK, once under the plugins and once under the engine and the app's own
    libraries, and every library both share compiled and resource-linked twice.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    validation = [
        f
        for f in getattr(target[OutputGroupInfo], "_validation").to_list()
        if f.basename == target.label.name + "_native_libs.validated"
    ]
    asserts.equals(env, 1, len(validation), "its own validation, an output of its configuration")
    jars = [
        jar
        for jar in target[JavaInfo].transitive_runtime_jars.to_list()
        if jar.basename == "liblib_java.jar"
    ]
    asserts.equals(env, 1, len(jars), "the plugin's jar")
    if validation and jars:
        asserts.equals(env, validation[0].root.path, jars[0].root.path)
    return analysistest.end(env)

_java_in_app_configuration_test = analysistest.make(
    _java_in_app_configuration_impl,
    config_settings = _platform("@rules_android//:arm64-v8a"),
)

def _plugin_native_libs(env):
    """What `FlutterAndroidPluginNativeLibsInfo.libraries` gives, as {library name: [basenames]}."""
    info = analysistest.target_under_test(env)[FlutterAndroidPluginNativeLibsInfo]
    return {label.name: sorted([f.basename for f in files]) for label, files in info.libraries.items()}

def _keeps_libraries_of_other_packages_impl(ctx):
    """A plugin's AAR carries what its library links from another Bazel package, but not what it links through another plugin's.

    `plugin_linked`'s library links `libshared.so` of another package, and
    `plugin_dep`'s depends on `plugin_linked`'s: the library goes in
    `plugin_linked`'s AAR alone, as Gradle builds it into that module.
    """
    env = analysistest.begin(ctx)
    asserts.equals(
        env,
        {"lib_dep": [], "lib_linked": ["libshared.so"]},
        _plugin_native_libs(env),
    )
    return analysistest.end(env)

_keeps_libraries_of_other_packages_test = analysistest.make(
    _keeps_libraries_of_other_packages_impl,
    config_settings = _platform("@rules_android//:arm64-v8a"),
)

def android_plugin_libs_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    _links_only_its_plugins_test(
        name = name + "_links_only_its_plugins",
        target_under_test = _FIXTURE + "libs_of_a",
    )
    _checks_what_it_links_test(
        name = name + "_checks_what_it_links",
        target_under_test = _FIXTURE + "checked_libs_of_a",
    )
    _takes_one_application_test(
        name = name + "_takes_one_application",
        target_under_test = _FIXTURE + "libs_of_two_apps",
    )
    _ignores_what_it_does_not_link_test(
        name = name + "_ignores_what_it_does_not_link",
        target_under_test = _FIXTURE + "checked_libs_of_ok",
    )
    _report_names_only_its_plugins_test(
        name = name + "_report_names_only_its_plugins",
        target_under_test = _FIXTURE + "report_of_a",
    )
    _report_does_not_fail_test(
        name = name + "_report_does_not_fail",
        target_under_test = _FIXTURE + "report_of_ok",
    )
    _checks_native_libs_arm64_test(
        name = name + "_checks_native_libs_arm64",
        target_under_test = _FIXTURE + "libs_of_native",
        abi = "arm64-v8a",
        sixteen_kb = True,
    )
    _checks_native_libs_armv7_test(
        name = name + "_checks_native_libs_armv7",
        target_under_test = _FIXTURE + "libs_of_native",
        abi = "armeabi-v7a",
        sixteen_kb = False,
    )
    _java_in_app_configuration_test(
        name = name + "_java_in_app_configuration",
        target_under_test = _FIXTURE + "libs_of_native",
    )
    _keeps_libraries_of_other_packages_test(
        name = name + "_keeps_libraries_of_other_packages",
        target_under_test = _FIXTURE + "native_libs_of_linked_and_dep",
    )
    native.test_suite(
        name = name,
        tests = [
            name + "_keeps_libraries_of_other_packages",
            name + "_java_in_app_configuration",
            name + "_checks_native_libs_arm64",
            name + "_checks_native_libs_armv7",
            name + "_report_names_only_its_plugins",
            name + "_report_does_not_fail",
            name + "_links_only_its_plugins",
            name + "_checks_what_it_links",
            name + "_takes_one_application",
            name + "_ignores_what_it_does_not_link",
        ],
    )
