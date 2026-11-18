"""The Java and Kotlin level a pub plugin's Android sources compile at.

Gradle compiles each Android library at the level its own
`android/build.gradle(.kts)` declares: the Java half at
`android.compileOptions.targetCompatibility`, the Kotlin half at
`kotlin.compilerOptions.jvmTarget` (or `kotlinOptions.jvmTarget`). Flutter's
Gradle plugin leaves a plugin's level to the plugin. Where the script declares
none, the Android Gradle plugin takes the version of the module's Java
toolchain (`java.toolchain.languageVersion`, which Kotlin's `jvmToolchain(n)`
also sets), else its own default.

rules_kotlin compiles both halves of a `kt_android_library` at one level, its
`kotlinc_opts`'s `jvm_target` (the Java half gets `-source`/`-target` of it),
so a plugin gets one level: its Java target, else its Kotlin target, else its
toolchain's, else the Android Gradle plugin's default.

A declaration whose value the reader cannot read, where it could decide that
level, is reported rather than skipped: the plugin's Android build fails
naming it (`unread_jvm_level_message`).
"""

load("//flutter/private:gradle_script.bzl", "applied_script", "call_argument", "gradle_scope", "gradle_string", "gradle_tokens_with_applied", "gradle_value", "leading_identifier")

# The Android Gradle plugin's `compileOptions` default when the module names
# no Java toolchain: Java 11 since AGP 9.0 (issuetracker 369246556), the AGP
# that `flutter create`'s Android templates use in the pinned Flutter (9.1).
AGP_DEFAULT_JVM_LEVEL = 11

# The newest `jvm_target` rules_kotlin's `kt_kotlinc_options` accepts (its
# `values`, "1.6", "1.8" and "9" to "25" in rules_kotlin 2.4.21).
_KT_MAX_JVM_TARGET = 25

def kotlinc_jvm_target(level):
    """The `kt_kotlinc_options.jvm_target` for a Java major version, or None.

    Java 8 and below are `1.8`: javac and kotlinc no longer target older
    bytecode, and source written for an older level compiles at 8. A level
    newer than rules_kotlin accepts is None.

    Args:
        level: A Java major version.

    Returns:
        The `jvm_target` string, or None.
    """
    if level <= 8:
        return "1.8"
    if level > _KT_MAX_JVM_TARGET:
        return None
    return str(level)

def _major(text):
    """`17`, `1.8`, `8` as a Java major version, or None."""
    text = text.strip()
    if text.startswith("1.") or text.startswith("1_"):
        text = text[2:]
    return int(text) if text.isdigit() else None

# The forms of a version the reader knows: a qualified name of a constant, and
# the conversions between Java's and Kotlin's version types.
_CONSTANT_PREFIXES = (
    "JavaVersion.VERSION_",
    "org.gradle.api.JavaVersion.VERSION_",
    "JvmTarget.JVM_",
    "org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_",
)
_CONVERSIONS = (
    "JavaVersion.toVersion",
    "org.gradle.api.JavaVersion.toVersion",
    "JvmTarget.fromTarget",
    "org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget",
    "JavaLanguageVersion.of",
    "org.gradle.jvm.toolchain.JavaLanguageVersion.of",
)
_SUFFIXES = (".toString()", ".majorVersion", ".target", ".asInt()")

def _value(text, scope):
    """The Java major version `text` evaluates to, or None when it is not readable.

    The forms of a version are this reader's; what a name stands for (a
    variable, `ext`, `extra`, a project property, `gradle.properties`) is the
    shared evaluator's (`gradle_value`).
    """
    text = text.strip()

    # Each round unwraps one conversion or variable.
    for _ in range(8):
        if not text:
            return None
        for _ in range(4):
            stripped = False
            for suffix in _SUFFIXES:
                if text.endswith(suffix):
                    text = text[:-len(suffix)].strip()
                    stripped = True
            if not stripped:
                break
        if _major(text) != None:
            return _major(text)
        for prefix in _CONSTANT_PREFIXES:
            if text.startswith(prefix):
                return _major(text[len(prefix):])
        inner = None
        for call in _CONVERSIONS:
            arg = call_argument(text, call)
            if arg != None:
                inner = arg
                break
        if inner != None:
            text = inner.strip()
            continue
        if text[0] in "'\"":
            # A string, whose `$x` and `${...}` the evaluator follows.
            parts = gradle_string(text, scope)
            value = struct(kind = "str", parts = parts) if parts != None else None
        else:
            value = gradle_value(text, scope)
        if value == None:
            return None
        if value.kind == "str":
            if [p for p in value.parts if type(p) != "string"]:
                return None
            return _major("".join(value.parts))
        if value.kind != "expression":
            return None
        text = value.text.strip()
    return None

def _assigned(text, key):
    """The value `text` gives `key` (`key = v`, `key v`, `key(v)`, `key.set(v)`), or None."""
    if leading_identifier(text) != key:
        return None
    rest = text[len(key):]
    if not rest:
        return None
    if rest.startswith(".set(") and rest.endswith(")"):
        return rest[len(".set("):-1]
    if rest[0] == "(" and rest.endswith(")"):
        return rest[1:-1]
    rest = rest.strip()
    if rest.startswith("="):
        return rest[1:]
    if rest != text[len(key):] and rest and rest[0] not in "{.":
        return rest
    return None

_KEYS = {
    "targetCompatibility": "java",
    "jvmTarget": "kotlin",
    "jvmToolchain": "toolchain",
    "languageVersion": "toolchain",
}

# What decides the level, first to last.
_PRECEDENCE = (("java", "targetCompatibility"), ("kotlin", "jvmTarget"), ("toolchain", "toolchain"))

def parse_gradle_jvm_level(content, applied = {}, properties = {}, script = "android/build.gradle"):
    """The level a plugin's Android sources compile at, read from its Gradle script.

    Statement based, like the Maven reader (`gradle_tokens`). Reads
    `targetCompatibility`, `jvmTarget`, `jvmToolchain(n)` and a toolchain's
    `languageVersion = JavaLanguageVersion.of(n)`, written as a version
    (`JavaVersion.VERSION_17`, `JvmTarget.JVM_17`, `"17"`, `'1.8'`, `17`, the
    conversions between them) or as a name the shared evaluator resolves
    (`gradle_value`): a variable the script, or a script it applies, defines
    (`def`, `val`, `final`, `String x =`, `ext.x =`, `ext["x"] =`, an
    `ext { }` block), or a property of `gradle.properties`.

    Args:
        content: The text of `build.gradle` or `build.gradle.kts`.
        applied: The text of each script `content` applies that the package
            has, by the path `gradle_applied_scripts` gives.
        properties: The package's `gradle.properties` (`parse_gradle_properties`).
        script: The path of `content` in the package, for `unread`.

    Returns:
        A struct: `level`, the Java major version to compile at; `declared`,
        what it comes from (`"targetCompatibility"`, `"jvmTarget"`,
        `"toolchain"` or `""` for the Android Gradle plugin's default); and
        `unread`, structs of `script`, `line` and `line_number`, each a
        declaration whose value the reader cannot read and which could decide
        the level: one of the kind `level` comes from or of a kind before it,
        and, where nothing declared is read, each script applied that is not
        in `applied`. The level is not known when `unread` is not empty.
    """
    tokens = gradle_tokens_with_applied(content, applied, script)
    scope = gradle_scope(tokens, properties)

    # A script the script applies that is not read, which could declare the
    # level itself. One an applied script applies is not read either.
    missing = [
        struct(script = script, line = t.text, line_number = t.line)
        for t in tokens
        if t.kind == "statement" and t.script == script and not t.applied and applied_script(t.text)
    ]

    found = {}
    unread = {}
    for t in tokens:
        if t.kind != "statement":
            continue
        key = leading_identifier(t.text)
        kind = _KEYS.get(key)
        if not kind:
            continue
        value = _assigned(t.text, key)
        if value == None:
            continue
        value = value.strip()

        # Kotlin's own `languageVersion` is a Kotlin version, not a toolchain's.
        if key == "languageVersion" and "JavaLanguageVersion" not in value:
            continue
        level = _value(value, scope)
        if level == None:
            unread.setdefault(kind, []).append(struct(script = t.script, line = t.text, line_number = t.line))
            continue
        found[kind] = level

    deciding = []
    for kind, declared in _PRECEDENCE:
        deciding.extend(unread.get(kind, []))
        if kind in found:
            return struct(level = found[kind], declared = declared, unread = deciding)
    return struct(level = AGP_DEFAULT_JVM_LEVEL, declared = "", unread = deciding + missing)

def unread_jvm_level_message(package, unread):
    """What an Android build of a plugin whose level is not read fails with.

    Args:
        package: The pub package.
        unread: `parse_gradle_jvm_level`'s `unread`.

    Returns:
        The message, naming each file and line.
    """
    return (
        "package {pkg}: its Gradle build declares the Java level of its Android sources " +
        "in a form rules_flutter cannot read, so the level they compile at is not known:\n" +
        "{lines}\n" +
        "To build it, supply a plugin overlay (`flutter_pub.plugin_overlays`) whose " +
        "android/BUILD.bazel.tpl sets the level as `kt_kotlinc_options.jvm_target` " +
        "(README, \"Plugins' Java and Kotlin level\")."
    ).format(
        pkg = package,
        lines = "\n".join(["    {}:{}: {}".format(u.script, u.line_number, u.line) for u in unread]),
    )

def unsupported_jvm_level_message(package, script, level):
    """What an Android build of a plugin at a level rules_kotlin lacks fails with."""
    return (
        "package {pkg}: {script} declares Java {level}, newer than the Java {max} " +
        "rules_kotlin compiles at."
    ).format(pkg = package, script = script, level = level, max = _KT_MAX_JVM_TARGET)
