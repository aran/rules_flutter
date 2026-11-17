"""Unit tests for android_plugin_jvm_target.bzl: the level a plugin's Gradle build declares.

The scripts are the forms pub.dev plugins write: `flutter create`'s Kotlin DSL
template, Groovy's method-call form, `kotlinOptions`, a toolchain, and a level
held in a variable another script defines (firebase_core's `local-config.gradle`).
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:android_plugin_jvm_target.bzl",
    "AGP_DEFAULT_JVM_LEVEL",
    "kotlinc_jvm_target",
    "parse_gradle_jvm_level",
    "unread_jvm_level_message",
)
load("//flutter/private:gradle_script.bzl", "gradle_applied_scripts")

# `flutter create --template=plugin --android-language=kotlin`, trimmed.
_TEMPLATE_KTS = """\
android {
    namespace = "com.example.plugin"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
"""

def _level(content, applied = {}):
    parsed = parse_gradle_jvm_level(content, applied)
    return (parsed.level, parsed.declared, len(parsed.unread))

def _declared_forms_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, (17, "targetCompatibility", 0), _level(_TEMPLATE_KTS))

    # Groovy's method-call form, and the legacy 1.x names.
    asserts.equals(env, (11, "targetCompatibility", 0), _level("""\
android {
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_11
        targetCompatibility JavaVersion.VERSION_11
    }
}
"""))
    asserts.equals(env, (8, "targetCompatibility", 0), _level(
        "android { compileOptions { targetCompatibility = JavaVersion.VERSION_1_8 } }\n",
    ))
    asserts.equals(env, (17, "targetCompatibility", 0), _level(
        "android {\n    compileOptions {\n        targetCompatibility = JavaVersion.toVersion(17)\n    }\n}\n",
    ))

    # Only Kotlin's target: `kotlinOptions`, as a string, a number or a
    # conversion of a JavaVersion.
    asserts.equals(env, (11, "jvmTarget", 0), _level("android {\n    kotlinOptions {\n        jvmTarget = '11'\n    }\n}\n"))
    asserts.equals(env, (8, "jvmTarget", 0), _level("kotlinOptions {\n    jvmTarget = \"1.8\"\n}\n"))
    asserts.equals(env, (17, "jvmTarget", 0), _level("kotlinOptions {\n    jvmTarget = 17\n}\n"))
    asserts.equals(env, (17, "jvmTarget", 0), _level("kotlinOptions {\n    jvmTarget = JavaVersion.VERSION_17.toString()\n}\n"))
    asserts.equals(env, (21, "jvmTarget", 0), _level("kotlin {\n    compilerOptions {\n        jvmTarget.set(JvmTarget.JVM_21)\n    }\n}\n"))

    # A toolchain, which the Android Gradle plugin's default follows.
    asserts.equals(env, (17, "toolchain", 0), _level("kotlin {\n    jvmToolchain(17)\n}\n"))
    asserts.equals(env, (21, "toolchain", 0), _level(
        "java {\n    toolchain {\n        languageVersion = JavaLanguageVersion.of(21)\n    }\n}\n",
    ))

    # Kotlin's own `languageVersion` is not a Java level.
    asserts.equals(env, (AGP_DEFAULT_JVM_LEVEL, "", 0), _level(
        "kotlin {\n    compilerOptions {\n        languageVersion = KotlinVersion.KOTLIN_2_0\n    }\n}\n",
    ))
    return unittest.end(env)

declared_forms_test = unittest.make(_declared_forms_test_impl)

def _java_target_comes_first_test_impl(ctx):
    """The Java target, else Kotlin's, else the toolchain's, else the AGP default."""
    env = unittest.begin(ctx)
    asserts.equals(env, (11, "targetCompatibility", 0), _level("""\
kotlin { jvmToolchain(17) }
android {
    compileOptions { targetCompatibility JavaVersion.VERSION_11 }
    kotlinOptions { jvmTarget = '17' }
}
"""))
    asserts.equals(env, (17, "jvmTarget", 0), _level("kotlin { jvmToolchain(21) }\nkotlinOptions { jvmTarget = '17' }\n"))
    asserts.equals(env, (AGP_DEFAULT_JVM_LEVEL, "", 0), _level("android {\n    namespace 'com.example'\n}\n"))
    asserts.equals(env, (AGP_DEFAULT_JVM_LEVEL, "", 0), _level(""))
    return unittest.end(env)

java_target_comes_first_test = unittest.make(_java_target_comes_first_test_impl)

def _variables_test_impl(ctx):
    """A level a variable holds, defined in the script or a script it applies."""
    env = unittest.begin(ctx)
    asserts.equals(env, (17, "targetCompatibility", 0), _level("""\
def javaVersion = JavaVersion.VERSION_17
android { compileOptions { targetCompatibility javaVersion } }
"""))
    asserts.equals(env, (11, "targetCompatibility", 0), _level("""\
val javaLevel: JavaVersion = JavaVersion.VERSION_11
android { compileOptions { targetCompatibility = javaLevel } }
"""))

    # firebase_core 5.x: `ext { }` in an applied `local-config.gradle`.
    firebase = """\
apply from: file("local-config.gradle")
android {
    compileOptions {
        sourceCompatibility project.ext.javaVersion
        targetCompatibility project.ext.javaVersion
    }
    kotlinOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(project.ext.javaVersion.toString())
    }
}
"""
    local_config = """\
ext {
    compileSdk=34
    javaVersion = JavaVersion.toVersion(17)
}
"""
    asserts.equals(env, ["local-config.gradle"], gradle_applied_scripts(firebase))
    asserts.equals(env, (17, "targetCompatibility", 0), _level(firebase, {"local-config.gradle": local_config}))

    # Without the applied script the variable is unknown: nothing declared is
    # read, so each declaration is reported with its file and line, and so is
    # the script not read, which could declare the level itself.
    parsed = parse_gradle_jvm_level(firebase)
    asserts.equals(
        env,
        [
            ("android/build.gradle", 5, "targetCompatibility project.ext.javaVersion"),
            ("android/build.gradle", 8, "jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(project.ext.javaVersion.toString())"),
            ("android/build.gradle", 1, "apply from: file(\"local-config.gradle\")"),
        ],
        [(u.script, u.line_number, u.line) for u in parsed.unread],
    )

    # A level an applied script sets is reported in that script.
    parsed = parse_gradle_jvm_level(
        "apply from: \"levels.gradle\"\n",
        {"levels.gradle": "android {\n    compileOptions {\n        targetCompatibility rootProject.ext.v\n    }\n}\n"},
    )
    asserts.equals(
        env,
        [("android/levels.gradle", 3, "targetCompatibility rootProject.ext.v")],
        [(u.script, u.line_number, u.line) for u in parsed.unread],
    )
    return unittest.end(env)

variables_test = unittest.make(_variables_test_impl)

def _unread_test_impl(ctx):
    """A declaration the reader cannot read is reported where it could decide the level."""
    env = unittest.begin(ctx)

    # An unread Java target is reported though Kotlin's is read: Gradle would
    # compile the Java at the former.
    parsed = parse_gradle_jvm_level("""\
android {
    compileOptions { targetCompatibility rootProject.ext.javaVersion }
    kotlinOptions { jvmTarget = '17' }
}
""", script = "android/build.gradle.kts")
    asserts.equals(
        env,
        [("android/build.gradle.kts", 2, "targetCompatibility rootProject.ext.javaVersion")],
        [(u.script, u.line_number, u.line) for u in parsed.unread],
    )

    # One Java target read and one not: which Gradle takes is not known.
    parsed = parse_gradle_jvm_level("""\
android {
    compileOptions { targetCompatibility JavaVersion.VERSION_17 }
    compileOptions { targetCompatibility someLevel() }
}
""")
    asserts.equals(env, [3], [u.line_number for u in parsed.unread])

    # One after the declaration that decides is not reported.
    parsed = parse_gradle_jvm_level("""\
android {
    compileOptions { targetCompatibility JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = rootProject.ext.kotlinTarget }
}
kotlin { jvmToolchain(rootProject.ext.jdk) }
""")
    asserts.equals(env, (17, "targetCompatibility", []), (parsed.level, parsed.declared, parsed.unread))

    # A script applied from outside the package, or by an interpolated path,
    # is not read. Where nothing declared is read, it could declare the level.
    content = "apply from: \"$rootDir/levels.gradle\"\nandroid {\n    namespace 'com.example'\n}\n"
    asserts.equals(env, ["$rootDir/levels.gradle"], gradle_applied_scripts(content))
    parsed = parse_gradle_jvm_level(content)
    asserts.equals(
        env,
        [("android/build.gradle", 1, "apply from: \"$rootDir/levels.gradle\"")],
        [(u.script, u.line_number, u.line) for u in parsed.unread],
    )
    asserts.equals(env, [], parse_gradle_jvm_level(content + "kotlin { jvmToolchain(17) }\n").unread)
    return unittest.end(env)

unread_test = unittest.make(_unread_test_impl)

def _unread_message_test_impl(ctx):
    """The failure names the package, and each file and line."""
    env = unittest.begin(ctx)
    message = unread_jvm_level_message("some_plugin", [
        struct(script = "android/build.gradle", line = "targetCompatibility rootProject.ext.v", line_number = 12),
        struct(script = "android/levels.gradle", line = "jvmTarget = x", line_number = 3),
    ])
    asserts.true(env, message.startswith("package some_plugin: "), message)
    asserts.true(env, "\n    android/build.gradle:12: targetCompatibility rootProject.ext.v\n" in message, message)
    asserts.true(env, "\n    android/levels.gradle:3: jvmTarget = x\n" in message, message)
    asserts.true(env, "flutter_pub.plugin_overlays" in message, message)
    return unittest.end(env)

unread_message_test = unittest.make(_unread_message_test_impl)

def _kotlinc_jvm_target_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "1.8", kotlinc_jvm_target(8))
    asserts.equals(env, "1.8", kotlinc_jvm_target(7))
    asserts.equals(env, "11", kotlinc_jvm_target(11))
    asserts.equals(env, "17", kotlinc_jvm_target(17))
    asserts.equals(env, "25", kotlinc_jvm_target(25))
    asserts.equals(env, None, kotlinc_jvm_target(26))
    return unittest.end(env)

kotlinc_jvm_target_test = unittest.make(_kotlinc_jvm_target_test_impl)

def android_plugin_jvm_target_test_suite(name):
    unittest.suite(
        name,
        declared_forms_test,
        java_target_comes_first_test,
        variables_test,
        unread_test,
        unread_message_test,
        kotlinc_jvm_target_test,
    )
