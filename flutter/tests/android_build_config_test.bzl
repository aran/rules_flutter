"""The `BuildConfig` a plugin library gets says what Gradle's would in each mode.

`-c dbg` is debug, `-c opt --@rules_flutter//flutter:profile` is profile, and
any other `-c` (`opt`, and `fastbuild`, the default) is release.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:android_build_config.bzl", "android_build_config", "parse_gradle_build_config_fields", "unread_build_config_message")
load(":action_content.bzl", "written_text")
load(":engine_mode.bzl", "MODE_FLAGS")

def _expect(env, debug, build_type):
    content = written_text(env, "BuildConfig.java")
    if content == None:
        return
    for line in [
        "public static final boolean DEBUG = %s;" % debug,
        'public static final String BUILD_TYPE = "%s";' % build_type,
    ]:
        asserts.true(env, line in content, "%s in:\n%s" % (line, content))

def _fields_test_impl(ctx):
    env = analysistest.begin(ctx)
    content = written_text(env, "BuildConfig.java")
    if content != None:
        line = '  public static final String LIBRARY_NAME = "flutter-fire-core";\n}'
        asserts.true(env, line in content, "%s in:\n%s" % (line, content))
    return analysistest.end(env)

_fields_test = analysistest.make(_fields_test_impl)

# firebase_core 5.1.0's `android/user-agent.gradle`.
_FIREBASE_USER_AGENT = """\
import java.util.regex.Matcher
import java.util.regex.Pattern

String libraryVersionName = "UNKNOWN"
String libraryName = "flutter-fire-core"
File pubspec = new File(project.projectDir.parentFile,  'pubspec.yaml')

if (pubspec.exists()) {
    String yaml = pubspec.text
    // Using \\s*['|"]?([^\\n|'|"]*)['|"]? to extract version number.
    Matcher versionMatcher = Pattern.compile("^version:\\\\s*['|\\"]?([^\\\\n|'|\\"]*)['|\\"]?\\$", Pattern.MULTILINE).matcher(yaml)
    if (versionMatcher.find()) libraryVersionName = versionMatcher.group(1).replaceAll("\\\\+", "-")
}

android {
    defaultConfig {
        // BuildConfig.VERSION_NAME
        buildConfigField 'String', 'LIBRARY_VERSION', "\\"${libraryVersionName}\\""
        // BuildConfig.LIBRARY_NAME
        buildConfigField 'String', 'LIBRARY_NAME', "\\"${libraryName}\\""
    }
}
"""

def _parse_test_impl(ctx):
    env = unittest.begin(ctx)

    # Applied, as firebase_core's build.gradle applies it. The version is set
    # from the pubspec by a regular expression, which the reader does not
    # run: it is reported, not given the value it starts with.
    r = parse_gradle_build_config_fields(
        'apply from: file("./user-agent.gradle")\n',
        applied = {"./user-agent.gradle": _FIREBASE_USER_AGENT},
    )
    asserts.equals(env, ['String LIBRARY_NAME = "flutter-fire-core"'], r.fields)
    asserts.equals(
        env,
        [("android/user-agent.gradle", 18, "buildConfigField 'String', 'LIBRARY_VERSION', \"\\\"${libraryVersionName}\\\"\"")],
        [(u.script, u.line_number, u.line) for u in r.unread],
    )
    message = unread_build_config_message("firebase_core", r.unread)
    for needle in ["firebase_core's Gradle build", "    android/user-agent.gradle:18: buildConfigField 'String', 'LIBRARY_VERSION'"]:
        asserts.true(env, needle in message, message)

    # The Kotlin form, a property, and fields outside `defaultConfig`.
    r = parse_gradle_build_config_fields(
        """\
android {
    defaultConfig {
        buildConfigField("int", "LEVEL", "${level}")
        buildConfigField("boolean", "ON", "true")
    }
    buildTypes {
        release { buildConfigField("boolean", "RELEASE", "true") }
    }
}
""",
        properties = {"level": "3"},
    )
    asserts.equals(env, ["int LEVEL = 3", "boolean ON = true"], r.fields)
    asserts.equals(env, [7], [u.line_number for u in r.unread])
    return unittest.end(env)

_parse_test = unittest.make(_parse_test_impl)

def _make(debug, build_type, config_settings):
    def impl(ctx):
        env = analysistest.begin(ctx)
        _expect(env, debug, build_type)
        return analysistest.end(env)

    return analysistest.make(impl, config_settings = config_settings)

_debug_test = _make("true", "debug", MODE_FLAGS["debug"])
_profile_test = _make("true", "profile", MODE_FLAGS["profile"])
_opt_test = _make("false", "release", MODE_FLAGS["release"])
_fastbuild_test = _make("false", "release", {"//command_line_option:compilation_mode": "fastbuild"})

def android_build_config_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    android_build_config(
        name = name + "_src",
        package = "com.example.build_config",
        tags = ["manual"],
    )
    tests = {
        "debug": _debug_test,
        "fastbuild": _fastbuild_test,
        "opt": _opt_test,
        "profile": _profile_test,
    }
    for mode, test in tests.items():
        test(
            name = "%s_%s" % (name, mode),
            target_under_test = ":" + name + "_src",
        )
    android_build_config(
        name = name + "_fields_src",
        package = "com.example.build_config",
        fields = ['String LIBRARY_NAME = "flutter-fire-core"'],
        tags = ["manual"],
    )
    _fields_test(name = name + "_fields", target_under_test = ":" + name + "_fields_src")
    _parse_test(name = name + "_parse")
    native.test_suite(
        name = name,
        tests = ["%s_%s" % (name, mode) for mode in tests] + [name + "_fields", name + "_parse"],
    )
