"""The `BuildConfig` class Gradle generates for each Android module.

Gradle writes a `BuildConfig` into every library's namespace, and plugins read
`BuildConfig.DEBUG` and `BUILD_TYPE` from it. rules_android generates none, so
every plugin library gets one from here. Its values are those of the Gradle
build of the same mode (Flutter's Gradle plugin makes the `profile` build type
with `initWith(debug)`, and copies the app's build types, `isDebuggable`
included, to its plugins):

| mode    | `DEBUG` | `BUILD_TYPE` |
|---------|---------|--------------|
| debug   | true    | `debug`      |
| profile | true    | `profile`    |
| release | false   | `release`    |

The mode is the configuration's, as for the engine: `-c dbg` is debug,
`-c opt --@rules_flutter//flutter:profile` is profile, anything else release.

A plugin's Gradle build can add fields of its own with `buildConfigField` in
`android { defaultConfig { } }`: FlutterFire's plugins add `LIBRARY_NAME` and
`LIBRARY_VERSION`, which their registrars read. `parse_gradle_build_config_fields`
reads them, and evaluates their values as the Maven reader does; one it cannot
evaluate, or one declared anywhere else (a build type, a flavor, a
condition), fails the plugin's Android build rather than leaving the field
out or giving it a value Gradle would not.
"""

load(
    "//flutter/private:gradle_script.bzl",
    "call_arguments",
    "gradle_scope",
    "gradle_string",
    "gradle_tokens_with_applied",
    "leading_identifier",
)

_SOURCE = """\
package {package};

public final class BuildConfig {{
  public static final boolean DEBUG = {debug};
  public static final String LIBRARY_PACKAGE_NAME = "{package}";
  public static final String BUILD_TYPE = "{build_type}";
{fields}}}
"""

def _android_build_config_src_impl(ctx):
    out = ctx.actions.declare_file("%s/%s/BuildConfig.java" % (
        ctx.label.name,
        ctx.attr.package.replace(".", "/"),
    ))
    ctx.actions.write(out, _SOURCE.format(
        package = ctx.attr.package,
        debug = "true" if ctx.attr.debug else "false",
        build_type = ctx.attr.build_type,
        fields = "".join(["  public static final %s;\n" % f for f in ctx.attr.fields]),
    ))
    return [DefaultInfo(files = depset([out]))]

_android_build_config_src = rule(
    implementation = _android_build_config_src_impl,
    doc = "Writes `BuildConfig.java` for `package`. Writes the file itself, so it needs no shell.",
    attrs = {
        "package": attr.string(
            mandatory = True,
            doc = "The Android namespace the class is in.",
        ),
        "debug": attr.bool(
            mandatory = True,
            doc = "`BuildConfig.DEBUG`.",
        ),
        "build_type": attr.string(
            mandatory = True,
            doc = "`BuildConfig.BUILD_TYPE`.",
        ),
        "fields": attr.string_list(
            doc = "The plugin's own fields, each `<type> <name> = <value>` in Java.",
        ),
    },
)

def android_build_config(name, package, fields = [], tags = None):
    """Declares `name`, the `BuildConfig.java` of `package`, for a library's `srcs`.

    Gradle compiles the class it generates with the module's own sources, so
    it goes in the `srcs` of the plugin's library, not a library of its own.
    Its `DEBUG` and `BUILD_TYPE` follow the build mode of the configuration it
    is built in: see the file's docstring.

    Args:
        name: Name of the target that writes the source.
        package: The plugin's Android namespace.
        fields: The fields its Gradle build adds, each `<type> <name> =
            <value>` in Java (`parse_gradle_build_config_fields`).
        tags: Tags for the target.
    """
    _android_build_config_src(
        name = name,
        package = package,
        fields = fields,
        debug = select({
            "@rules_flutter//flutter/private:dbg": True,
            "@rules_flutter//flutter/private:profile": True,
            "//conditions:default": False,
        }),
        build_type = select({
            "@rules_flutter//flutter/private:dbg": "debug",
            "@rules_flutter//flutter/private:profile": "profile",
            "//conditions:default": "release",
        }),
        tags = tags,
        visibility = ["//visibility:private"],
    )

def parse_gradle_build_config_fields(content, applied = {}, properties = {}, script = "android/build.gradle"):
    """The `buildConfigField`s a plugin's Gradle build adds to its `BuildConfig`.

    Read in `android { defaultConfig { } }` of the script and of the scripts
    of the package it applies: `buildConfigField 'String', 'NAME', "\\"v\\""`
    and `buildConfigField("String", "NAME", "\\"v\\"")`, whose arguments are
    evaluated as `gradle_string` evaluates a string.

    Args:
        content: The text of `build.gradle` or `build.gradle.kts`.
        applied: The text of each script it applies that the package has, by
            the path `applied_script` gives.
        properties: The package's `gradle.properties`.
        script: The path of `content` in the package.

    Returns:
        `struct(fields, unread)`: each field as `<type> <name> = <value>`, and
        `struct(script, line, line_number)` of each `buildConfigField` the
        reader cannot evaluate or that is outside `defaultConfig`.
    """
    tokens = gradle_tokens_with_applied(content, applied, script)
    scope = gradle_scope(tokens, properties)
    fields = []
    unread = []
    blocks = []
    for t in tokens:
        if t.kind == "open":
            blocks.append(leading_identifier(t.text) or t.text)
            continue
        if t.kind == "close":
            if blocks:
                blocks.pop()
            continue
        if leading_identifier(t.text) != "buildConfigField":
            continue
        rest = t.text[len("buildConfigField"):].strip()
        if rest.startswith("(") and rest.endswith(")"):
            rest = rest[1:-1]
        args = [gradle_string(a, scope) for a in call_arguments(rest)]
        values = [_literal(a) for a in args]
        if blocks != ["android", "defaultConfig"] or len(values) != 3 or None in values or not values[1]:
            unread.append(struct(script = t.script, line = t.text, line_number = t.line))
            continue
        fields.append("%s %s = %s" % (values[0], values[1], values[2]))
    return struct(fields = fields, unread = unread)

def _literal(parts):
    """The string `parts` make when every part is known, else None."""
    if parts == None or [p for p in parts if type(p) != "string"]:
        return None
    return "".join(parts)

def unread_build_config_message(package, unread):
    """The message a plugin's Android build fails with when its `buildConfigField`s are not all read.

    Args:
        package: The pub package.
        unread: `parse_gradle_build_config_fields`' `unread`.

    Returns:
        The message.
    """
    return (
        "{package}'s Gradle build adds fields to its BuildConfig that " +
        "rules_flutter cannot evaluate without running Gradle, so it cannot " +
        "give the class the values Gradle would:\n\n{lines}\n\n" +
        "rules_flutter reads a `buildConfigField` in " +
        "`android {{ defaultConfig {{ }} }}` whose arguments are strings it " +
        "can evaluate: literals, variables the script sets once, project " +
        "properties and functions that return them. A plugin overlay " +
        "(flutter_pub.plugin_overlays) can supply the plugin's Android " +
        "library instead."
    ).format(
        package = package,
        lines = "\n".join(["    %s:%d: %s" % (u.script, u.line_number, u.line) for u in unread]),
    )
