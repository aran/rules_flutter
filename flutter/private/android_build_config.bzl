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
    "assignment",
    "call_arguments",
    "gradle_scope",
    "gradle_string",
    "gradle_tokens_with_applied",
    "leading_identifier",
)

visibility("//flutter/...")

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

# FlutterFire's `user-agent.gradle` sets a variable to the version in the
# plugin's own pubspec.yaml, with `+` as `-`, by running a regular
# expression over the file. These are its statements, whitespace collapsed,
# `{P}`, `{Y}`, `{M}` and `{V}` standing for its names: the reader recognises
# them, as it cannot run the expression. Anything else is not recognised.
_PUBSPEC_VERSION = [
    ("statement", "File {P} = new File(project.projectDir.parentFile, 'pubspec.yaml')"),
    ("open", "if ({P}.exists())"),
    ("statement", "String {Y} = {P}.text"),
    ("statement", """Matcher {M} = Pattern.compile("^version:\\\\s*['|\\"]?([^\\\\n|'|\\"]*)['|\\"]?\\$", Pattern.MULTILINE).matcher({Y})"""),
    ("statement", """if ({M}.find()) {V} = {M}.group(1).replaceAll("\\\\+", "-")"""),
    ("close", ""),
]

def _collapsed(text):
    """`text` with each run of whitespace one space."""
    return " ".join([w for w in text.replace("\t", " ").split(" ") if w])

def _matched(template, text, names):
    """Whether `text` is `template` with each `{X}` an identifier, the same one as in `names`; adds to `names`."""
    found = {}
    rest = text
    pieces = template.split("{")
    if not rest.startswith(pieces[0]):
        return False
    rest = rest[len(pieces[0]):]
    for piece in pieces[1:]:
        key, literal = piece[0], piece[2:]
        name = leading_identifier(rest)
        if not name or names.get(key, name) != name or found.get(key, name) != name:
            return False
        found[key] = name
        rest = rest[len(name):]
        if not rest.startswith(literal):
            return False
        rest = rest[len(literal):]
    if rest:
        return False
    names.update(found)
    return True

def _pubspec_version_variables(tokens, version):
    """The variables FlutterFire's pubspec-version statements set, to `version` with `+` as `-`."""
    out = {}
    if not version:
        return out
    for i in range(len(tokens) - len(_PUBSPEC_VERSION) + 1):
        names = {}
        matched = True
        for j, (kind, template) in enumerate(_PUBSPEC_VERSION):
            t = tokens[i + j]
            if t.kind != kind or not _matched(template, _collapsed(t.text), names):
                matched = False
                break
        if not matched:
            continue
        variable = names["V"]

        # Set there and nowhere else but its definition.
        others = [
            t
            for k, t in enumerate(tokens)
            if t.kind == "statement" and k != i + 4 and assignment(t.text)[0] == variable and
               assignment(t.text)[1].startswith("=") and not assignment(t.text)[1].startswith("==")
        ]
        if not others:
            out[variable] = version.replace("+", "-")
    return out

def parse_gradle_build_config_fields(content, applied = {}, properties = {}, script = "android/build.gradle", pubspec_version = None, annotated = {}):
    """The `buildConfigField`s a plugin's Gradle build adds to its `BuildConfig`.

    Read in `android { defaultConfig { } }` of the script and of the scripts
    of the package it applies: `buildConfigField 'String', 'NAME', "\\"v\\""`
    and `buildConfigField("String", "NAME", "\\"v\\"")`, whose arguments are
    evaluated as `gradle_string` evaluates a string. A variable FlutterFire's
    statements set to the pubspec's version (`_PUBSPEC_VERSION`) has that
    version, `+` as `-`.

    Args:
        content: The text of `build.gradle` or `build.gradle.kts`.
        applied: The text of each script it applies that the package has, by
            the path `applied_script` gives.
        properties: The package's `gradle.properties`.
        script: The path of `content` in the package.
        pubspec_version: The `version` of the package's pubspec.yaml.
        annotated: The values of fields the root's `flutter_pub.annotation`
            gives, by name, each a Java expression; they replace what is read.

    Returns:
        `struct(fields, unread, unknown)`: each field once, as `<type>
        <name> = <value>`, where it is first declared (an annotated field
        declared in several blocks once, with its annotated value; a field
        `defaultConfig` declares again with its last value, as Gradle keeps
        it); `struct(script, line, line_number)` of each
        `buildConfigField` the reader cannot evaluate, or that is outside
        `defaultConfig`, that no annotation gives; and the names in
        `annotated` that no `buildConfigField` declares.
    """
    tokens = gradle_tokens_with_applied(content, applied, script)
    scope = gradle_scope(tokens, properties)
    for name, value in _pubspec_version_variables(tokens, pubspec_version).items():
        scope.variables[name] = '"%s"' % value
    fields = {}
    unread = []
    declared = {}
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
        values = [_literal(gradle_string(a, scope)) for a in call_arguments(rest)]
        if len(values) == 3 and values[1] and values[0] != None:
            declared[values[1]] = True
            if values[1] in annotated:
                if values[1] not in fields:
                    fields[values[1]] = "%s %s = %s" % (values[0], values[1], annotated[values[1]])
                continue
        if blocks != ["android", "defaultConfig"] or len(values) != 3 or None in values or not values[1]:
            unread.append(struct(script = t.script, line = t.text, line_number = t.line))
            continue
        fields[values[1]] = "%s %s = %s" % (values[0], values[1], values[2])
    return struct(
        fields = fields.values(),
        unread = unread,
        unknown = sorted([name for name in annotated if name not in declared]),
    )

def _literal(parts):
    """The string `parts` make when every part is known, else None."""
    if parts == None or [p for p in parts if type(p) != "string"]:
        return None
    return "".join(parts)

def unknown_build_config_message(package, unknown):
    """The message a plugin's Android build fails with when an annotation gives a field it does not declare.

    Args:
        package: The pub package.
        unknown: `parse_gradle_build_config_fields`' `unknown`.

    Returns:
        The message.
    """
    return (
        "flutter_pub.annotation(package = \"{package}\", build_config_fields = ...) " +
        "gives {fields}, which {package}'s Gradle build declares no " +
        "`buildConfigField` of. Remove {them} from the annotation."
    ).format(
        package = package,
        fields = ", ".join(["`%s`" % f for f in unknown]),
        them = "it" if len(unknown) == 1 else "them",
    )

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
        "properties and functions that return them, and FlutterFire's " +
        "version from the pubspec. Give the value of each in the root " +
        "module, as the Java expression of the line's last argument:\n\n" +
        "    flutter_pub.annotation(package = \"{package}\", build_config_fields = {{\"<NAME>\": \"<value>\"}})"
    ).format(
        package = package,
        lines = "\n".join(["    %s:%d: %s" % (u.script, u.line_number, u.line) for u in unread]),
    )
