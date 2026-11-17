"""Maven dependencies of pub plugins' Android Gradle builds.

A pub plugin's `android/build.gradle(.kts)` declares the Maven artifacts its
Kotlin/Java sources compile against. The app's Android Maven classpath is one
`rules_jvm_external` resolution, `@rules_flutter_maven`, so that Coursier picks
one version of every artifact for the whole app (the highest, as Gradle does).
A plugin's declared artifacts therefore have to come from that repo.

This file holds the pieces:

* `parse_gradle_maven_dependencies` reads the declarations out of a script.
* `merge_plugin_requirements` and `maven_problems` merge what every plugin of
  the build's plugins declare and compare it with what `@rules_flutter_maven` resolved.
* `flutter_android_maven` is a repository rule, one per build, that gathers what
  every plugin declares and what `@rules_flutter_maven` resolved. It writes
  a `requirements` target, which an application's `flutter_android_plugin_libs`
  reads to check the plugins that application links (and those only),
  `resolved.bzl`, which a plugin's `android/` package
  loads to depend on the artifacts that exist, and a `maven_artifacts` target
  that prints the complete block of every plugin of the lock for the root
  module's `maven.install`. An application's own `<name>_maven_artifacts`
  (`flutter_android_maven_artifacts`) prints the part its plugins need.

Only an Android build that links a plugin reads any of this, so only such a
build fetches it.
"""

load(
    "//flutter/private:gradle_script.bzl",
    "applied_script",
    "code_mask",
    "dependency_kind",
    "gradle_scope",
    "gradle_string",
    "gradle_tokens_with_applied",
    "leading_identifier",
)

# Where each spoke records what its Gradle build declares, at the spoke's root.
MAVEN_DEPS_FILE = "flutter_android_maven_deps.json"

def _string_literal(text):
    """The value of `text` when it is exactly one string literal, else None."""
    text = text.strip()
    if len(text) < 2:
        return None
    q = text[0]
    if q != "'" and q != '"':
        return None
    if text[-1] != q:
        return None
    inner = text[1:-1]
    if q in inner:
        return None
    return inner

def _is_dynamic(version):
    if "+" in version or version.startswith("latest."):
        return True
    for c in "[](),".elems():
        if c in version:
            return True
    return False

def _add_call_as_declaration(line):
    """`add("implementation", "a:b:1")` as `implementation("a:b:1")`.

    Anything else (a configuration that is not a dependency one, or a first
    argument that is not a string) is returned as `add`, which the caller
    does not treat as a declaration.
    """
    rest = line[len("add"):].strip()
    if not rest.startswith("(") or not rest.endswith(")"):
        return line
    inner = rest[1:-1]
    comma = -1
    quote = ""
    for i in range(len(inner)):
        c = inner[i]
        if quote:
            if c == quote:
                quote = ""
        elif c == "'" or c == '"':
            quote = c
        elif c == ",":
            comma = i
            break
    if comma < 0:
        return line
    configuration = _string_literal(inner[:comma])
    if configuration == None or not dependency_kind(configuration):
        return line
    return configuration + "(" + inner[comma + 1:].strip() + ")"

# Blocks a `dependencies { }` block may sit in and still declare the
# project's dependencies unconditionally: `android { dependencies { } }`
# delegates to the project's.
_TRANSPARENT_BLOCKS = ("android",)

def _unconditional(blocks):
    """Whether a statement inside the block headers `blocks` always runs as a dependency declaration.

    True inside a top-level `dependencies { }` (or one in `android { }`); false
    inside anything else, such as an `if`, an `afterEvaluate` or a loop, whose
    statements Gradle may run once, many times, or never.
    """
    if not blocks or blocks[-1] != "dependencies":
        return False
    for header in blocks[:-1]:
        if header not in _TRANSPARENT_BLOCKS:
            return False
    return True

def _group_declaration(text):
    """The group a top-level `group = "x"` (or `group "x"`) statement sets, else None."""
    if leading_identifier(text) != "group":
        return None
    rest = text[len("group"):].strip()
    if rest.startswith("="):
        rest = rest[1:]
    elif not rest or rest[0] not in "'\"":
        return None
    return _string_literal(rest)

def _closure(text):
    """`(declaration, body, offset)` when `text` ends with a closure `{ ... }`, else None.

    `offset` is the number of lines of `text` before the one the closure opens on.
    """
    mask = code_mask(text)
    depth = 0
    for i in range(len(text)):
        if not mask[i]:
            continue
        c = text[i]
        if c == "(" or c == "[":
            depth += 1
        elif c == ")" or c == "]":
            depth -= 1
        elif c == "{" and depth == 0:
            body = text[i + 1:].rstrip()
            if not body.endswith("}"):
                return None
            return (text[:i].strip(), body[:-1], text[:i].count("\n"))
    return None

def _named_arguments(text):
    """The named arguments of `group: 'g', module: 'm'` or `(group = "g", module = "m")`, else None."""
    text = text.strip()
    if text.startswith("(") and text.endswith(")"):
        text = text[1:-1]
    args = {}
    for part in text.split(","):
        part = part.strip()
        name = leading_identifier(part)
        rest = part[len(name):].strip()
        if not name or not rest or rest[0] not in ":=":
            return None
        value = _string_literal(rest[1:])
        if value == None:
            return None
        args[name] = value
    return args

def _closure_exclusions(body, first_line):
    """What a dependency's closure excludes, and the statements of it the reader does not read.

    Gradle's `exclude group: "g", module: "m"` leaves `g:m` out of what the
    dependency brings, as rules_jvm_external's `exclusions` do; an exclusion
    of a whole group, or of a module of any group, has no such counterpart.
    `because "..."` explains and changes nothing.

    Returns:
        `struct(exclusions, unread)`: the `group:module` strings, and
        `struct(line, line_number)` of each statement not read.
    """
    exclusions = []
    unread = []
    for offset, raw in enumerate(body.split("\n")):
        for statement in raw.split(";"):
            statement = statement.strip()
            if not statement:
                continue
            identifier = leading_identifier(statement)
            if identifier == "because":
                continue
            args = _named_arguments(statement[len(identifier):]) if identifier == "exclude" else None
            if args != None and sorted(args.keys()) == ["group", "module"]:
                exclusion = args["group"] + ":" + args["module"]
                if exclusion not in exclusions:
                    exclusions.append(exclusion)
                continue
            unread.append(struct(line = statement, line_number = first_line + offset))
    return struct(exclusions = exclusions, unread = unread)

def _call_argument(text, names):
    """`(name, argument)` when `text` is a call `name(argument)` of one of `names`, else None."""
    name = leading_identifier(text)
    if name not in names or not text[len(name):].startswith("(") or not text.endswith(")"):
        return None
    mask = code_mask(text)
    depth = 0
    for i in range(len(name), len(text)):
        if not mask[i]:
            continue
        if text[i] in "([{":
            depth += 1
        elif text[i] in ")]}":
            depth -= 1
            if depth == 0 and i != len(text) - 1:
                return None
    return (name, text[len(name) + 1:-1].strip())

def _coordinate(parts):
    """`struct(group, artifact, version, version_parts)` of a string's parts, else None.

    `version` is the version when it is known, else None; `version_parts`
    is the version's parts when they name another plugin's property, which
    the hub resolves (`resolve_plugin_properties`), else None. A coordinate
    with no version (`group:artifact`) has `version` "".
    """
    prefix = ""
    rest = []
    for i in range(len(parts)):
        if type(parts[i]) != "string":
            rest = parts[i:]
            break
        prefix += parts[i]
    if not rest:
        fields = prefix.split("@")[0].split(":")
        if len(fields) < 2 or len(fields) > 4 or not fields[0] or not fields[1]:
            return None
        if len(fields) == 2:
            return struct(group = fields[0], artifact = fields[1], version = "", version_parts = None)
        if not fields[2]:
            return None
        return struct(group = fields[0], artifact = fields[1], version = fields[2], version_parts = None)
    fields = prefix.split(":")
    if len(fields) != 3 or not fields[0] or not fields[1]:
        return None
    version_parts = ([fields[2]] if fields[2] else []) + rest
    if None in version_parts:
        version_parts = None
    elif version_parts and type(version_parts[-1]) == "string":
        version_parts[-1] = version_parts[-1].split("@")[0]
    return struct(group = fields[0], artifact = fields[1], version = None, version_parts = version_parts)

def parse_gradle_maven_dependencies(content, applied = {}, properties = {}, script = "android/build.gradle"):
    """Reads the Maven dependencies out of a Gradle build script.

    Statement based (see `_split_statements`: a line can hold several, and a
    block opened and closed on one line is read like one spread over many).
    The scripts it applies (`apply from:`) that the package has are read in
    their place.

    A dependency the reader understands is a string of the form
    `group:artifact:version` (a `:classifier` and an `@packaging` are allowed
    and dropped), declared as `implementation "..."`,
    `implementation("...")` or `add("implementation", "...")`, with a closure
    of `exclude group:, module:` statements or none. The string may be
    computed: from variables, project properties (the package's
    `gradle.properties`, `ext`), another plugin's properties and the
    functions of the script (`gradle_string`). `platform("...")` and
    `enforcedPlatform("...")` declare a BoM, which gives the versions of the
    artifacts declared as `group:artifact`, with none. Only the declarations
    directly in the `dependencies { }` block are `checked`: the application
    that links the plugin fails when `@rules_flutter_maven` lacks one.

    The rest is reported in `unread`, each with its line, so a dependency the
    reader cannot read is never silently lost, and is a warning rather than a
    failure, since a reader of Gradle's language that is not Gradle can be
    wrong about it: a declaration in another form (a version catalog entry,
    `files(...)`, a project, a `kapt` or `debugImplementation`
    configuration), an `apply from:` of a script the package lacks, and a
    well-formed declaration inside a condition or another block, which is
    also in `deps`, unchecked, and linked where `@rules_flutter_maven`
    has it.

    Args:
        content: The text of `build.gradle` or `build.gradle.kts`.
        applied: The text of each script `content` applies that the package
            has, by the path `applied_script` gives.
        properties: The package's `gradle.properties`
            (`parse_gradle_properties`).
        script: The path of `content` in the package.

    Returns:
        A struct. `group` is the Maven group the script sets at its top level
        (`group = "com.example.plugin"`), which Gradle publishes the plugin
        under, or None when it sets none the reader can read. `deps` is a list
        of structs with `kind` (`"deps"`, `"compile_only"` or `"runtime"`),
        `configuration` (the Gradle configuration, such as `"api"` or
        `"implementation"`), `group`, `artifact`, `version` (a string, ""
        for a declaration that names none, which a BoM gives, or None when it
        is one the reader cannot evaluate or a dynamic version, which get a
        presence-only check), `version_parts` (see `_coordinate`), `line`
        (the statement's first line), `line_number`, `script`, `checked` and
        `exclusions` (the `group:artifact`s its closure excludes). `boms` is
        a list of structs as `deps`' for the BoMs, without `kind` and
        `exclusions`. `unread` is a list of structs with `line`,
        `line_number`, `script` and `why`: `"form"` for a statement the
        reader cannot read, `"conditional"` for a declaration it reads but
        outside the `dependencies` block's own statements.
    """
    tokens = gradle_tokens_with_applied(content, applied, script)
    scope = gradle_scope(tokens, properties)

    deps = []
    boms = []
    unread = []
    blocks = []
    plugin_group = None
    for t in tokens:
        if t.kind == "statement" and not blocks and t.script == script:
            declared = _group_declaration(t.text)
            if declared:
                plugin_group = declared
        if t.kind == "open":
            blocks.append(t.text)
            continue
        if t.kind == "close":
            if blocks:
                blocks.pop()
            continue
        if t.applied:
            continue
        original = t.text
        line = original
        identifier = leading_identifier(line)
        if not identifier:
            continue

        # A declaration whose closure spans lines is named by its first.
        reported = original.split("\n")[0].strip()

        def report(why, line = reported, line_number = t.line):
            unread.append(struct(line = line, line_number = line_number, script = t.script, why = why))

        # `apply from: "deps.gradle"` of a script the package lacks pulls in
        # statements this reader never sees.
        if identifier == "apply" and applied_script(line):
            report("form")
            continue

        # `add("implementation", "a:b:1")` is `implementation("a:b:1")`.
        if identifier == "add":
            line = _add_call_as_declaration(line)
            identifier = leading_identifier(line)
            if not identifier:
                continue
        kind = dependency_kind(identifier)
        if not kind or kind == "ignore":
            continue
        rest = line[len(identifier):]

        # `implementation = ...`, `kapt { ... }` and `api.foo` configure
        # something else; a dependency is followed by an argument.
        if not rest or rest[0] not in " \t('\"":
            continue
        rest = rest.strip()
        if not rest or rest[0] == "=" or rest[0] == "{":
            continue
        if kind == "error":
            report("form")
            continue

        # `implementation("g:a:1") { exclude ... }`: the dependency, configured
        # by its closure.
        exclusions = []
        closure = _closure(rest)
        if closure:
            rest = closure[0]
            configured = _closure_exclusions(closure[1], t.line + closure[2])
            exclusions = configured.exclusions
            for u in configured.unread:
                report("form", u.line, u.line_number)

        arg = rest
        if arg.startswith("(") and _call_argument("call" + arg, ["call"]):
            # `implementation(...)`: the argument in the parentheses.
            arg = arg[1:-1].strip()
        platform = _call_argument(arg, ["platform", "enforcedPlatform"])
        if platform:
            arg = platform[1]
        parts = gradle_string(arg, scope)
        coordinate = _coordinate(parts) if parts != None else None

        # A BoM is only of use with its version.
        if coordinate == None or (platform and not coordinate.version and not coordinate.version_parts):
            report("form")
            continue
        group = coordinate.group
        artifact = coordinate.artifact
        if group == "io.flutter":
            continue
        if group == "org.jetbrains.kotlin" and artifact.startswith("kotlin-stdlib"):
            continue
        version = coordinate.version
        if version and _is_dynamic(version):
            version = None
        checked = _unconditional(blocks)
        if not checked:
            report("conditional")
        declaration = dict(
            configuration = identifier,
            group = group,
            artifact = artifact,
            version = version,
            version_parts = coordinate.version_parts,
            line = reported,
            line_number = t.line,
            script = t.script,
            checked = checked,
        )
        if platform:
            boms.append(struct(**declaration))
        else:
            deps.append(struct(kind = kind, exclusions = exclusions, **declaration))
    return struct(group = plugin_group, deps = deps, boms = boms, unread = unread)

def maven_target_name(group, artifact):
    """rules_jvm_external's target name for `group:artifact`.

    Args:
        group: The Maven group.
        artifact: The Maven artifact id.

    Returns:
        The name of the target `@rules_flutter_maven` gives the artifact.
    """
    name = group + ":" + artifact
    for c in ".-:/+$".elems():
        name = name.replace(c, "_")
    return name

# Qualifier order, as Maven's ComparableVersion: alpha < beta < milestone <
# rc < snapshot < release < sp. Unknown qualifiers sort after all of these.
_QUALIFIER_RANK = {
    "alpha": 0,
    "a": 0,
    "beta": 1,
    "b": 1,
    "milestone": 2,
    "m": 2,
    "rc": 3,
    "cr": 3,
    "snapshot": 4,
    "": 5,
    "ga": 5,
    "final": 5,
    "release": 5,
    "sp": 6,
}
_RELEASE_RANK = 5
_UNKNOWN_RANK = 7

def _version_tokens(version):
    """Splits on `.`, `-` and digit/letter transitions.

    Each token is `(True, int)` or `(False, qualifier)`.
    """
    tokens = []
    current = ""
    current_numeric = False
    for c in version.lower().elems():
        if c == "." or c == "-" or c == "_":
            if current:
                tokens.append((current_numeric, current))
            current = ""
            continue
        numeric = c.isdigit()
        if current and numeric != current_numeric:
            tokens.append((current_numeric, current))
            current = ""
        current += c
        current_numeric = numeric
    if current:
        tokens.append((current_numeric, current))
    return [(True, int(t)) if numeric else (False, t) for numeric, t in tokens]

def _qualifier_key(qualifier):
    rank = _QUALIFIER_RANK.get(qualifier)
    if rank == None:
        return (_UNKNOWN_RANK, qualifier)
    return (rank, "")

def _cmp(x, y):
    return 1 if x > y else (-1 if x < y else 0)

def _compare_present(a, b):
    """Compares token `a` with `b`, which may be None (absent)."""
    if a[0]:
        if b == None:
            return 0 if a[1] == 0 else 1
        if b[0]:
            return _cmp(a[1], b[1])
        return 1
    ka = _qualifier_key(a[1])
    if b == None:
        kb = (_RELEASE_RANK, "")
    elif b[0]:
        return -1
    else:
        kb = _qualifier_key(b[1])
    return _cmp(ka, kb)

def _compare_tokens(a, b):
    """Compares two tokens, either of which may be None (absent)."""
    if a == None and b == None:
        return 0
    if a == None:
        return -_compare_present(b, None)
    return _compare_present(a, b)

def compare_maven_versions(a, b):
    """Orders two Maven version strings, as Maven's ComparableVersion.

    Simplified: tokens split on `.`/`-` and digit/letter transitions; numbers
    compare numerically with missing ones as 0; qualifiers order
    alpha < beta < milestone < rc < snapshot < release < sp, unknown ones
    after, lexically.

    Args:
        a: A version.
        b: Another version.

    Returns:
        -1, 0 or 1.
    """
    ta = _version_tokens(a)
    tb = _version_tokens(b)
    for i in range(max(len(ta), len(tb))):
        c = _compare_tokens(
            ta[i] if i < len(ta) else None,
            tb[i] if i < len(tb) else None,
        )
        if c != 0:
            return c
    return 0

def maven_labels(declared, resolved = None):
    """The `@rules_flutter_maven` labels of a plugin's declared artifacts.

    Args:
        declared: List of dicts with `kind` (`"deps"`, `"compile_only"`,
            `"runtime"`) and `coordinate` (`group:artifact`).
        resolved: Dict of `group:artifact` to the version `@rules_flutter_maven`
            resolved, or None for every artifact. An artifact it lacks has no
            target to depend on, so one not in `resolved` is left out.

    Returns:
        A struct with the label lists `deps`, `compile_only` and
        `runtime_deps`, without duplicates.
    """
    labels = {"deps": [], "compile_only": [], "runtime": []}
    for d in declared:
        if resolved != None and d["coordinate"] not in resolved:
            continue
        group, artifact = d["coordinate"].split(":")[:2]
        label = "@rules_flutter_maven//:" + maven_target_name(group, artifact)
        if label not in labels[d["kind"]]:
            labels[d["kind"]].append(label)
    return struct(
        deps = labels["deps"],
        compile_only = labels["compile_only"],
        runtime_deps = labels["runtime"],
    )

def annotated_requirements(packages, resolved):
    """Each package's `flutter_pub.annotation` artifacts as the declarations they stand for.

    An annotation names the target of an artifact in `@rules_flutter_maven`;
    the checks and the report work on `group:artifact`. The artifact is the
    resolved one whose target that is, so a plugin's annotated dependency is a
    requirement like one its Gradle build declares: present in the install,
    reported, and checked for the duplicates of a second library.

    Args:
        packages: The decoded spokes' records (`package`, `deps`, `unread`
            and `annotated`, a list of dicts with `label` and `name`).
        resolved: Dict of `group:artifact` to the version resolved.

    Returns:
        `struct(packages, errors)`: the packages with each annotated artifact
        added to `deps` (declared with no version, so any resolution meets it),
        and the messages for annotations naming an artifact the install lacks.
    """
    by_name = {}
    for coordinate in sorted(resolved.keys()):
        group, artifact = coordinate.split(":")[:2]
        by_name.setdefault(maven_target_name(group, artifact), coordinate)
    out = []
    errors = []
    for pkg in packages:
        pkg = dict(pkg)
        pkg["deps"] = list(pkg["deps"])
        for a in pkg.get("annotated", []):
            coordinate = by_name.get(a["name"])
            if coordinate == None:
                errors.append((
                    "flutter_pub.annotation(package = \"{package}\") adds `{label}`, " +
                    "which is not an artifact @rules_flutter_maven resolves. Add the " +
                    "artifact to the root module's " +
                    '`maven.install(name = "rules_flutter_maven", artifacts = [...])` ' +
                    "and regenerate its lock file, or correct the label."
                ).format(package = pkg["package"], label = a["label"]))
                continue
            pkg["deps"].append({
                "kind": "deps",
                # What an annotation stands for is a dependency of the plugin's
                # own, as Gradle's `implementation` declares one.
                "configuration": "implementation",
                "coordinate": coordinate,
                "version": None,
                "line": "flutter_pub.annotation(android_deps = [...])",
                "checked": True,
            })
        out.append(pkg)
    return struct(packages = out, errors = errors)

def resolve_plugin_properties(packages):
    """Each package's versions that name another plugin's property, with the property's value.

    A plugin's Gradle build can read another's properties:
    cloud_firestore's BoM version is firebase_core's `FirebaseSDKVersion`.
    Only the hub, which reads every plugin's record, knows them.

    Args:
        packages: The decoded spokes' records: `package`, `properties` (its
            `gradle.properties`), and `deps` and `boms`, dicts whose
            `version_parts` (as `parse_gradle_maven_dependencies` gives
            them) may name `{"package", "property"}`.

    Returns:
        The packages, each `version_parts` replaced by the `version` it
        evaluates to, or None when a property it names is not known.
    """
    properties = {p["package"]: p.get("properties", {}) for p in packages}
    out = []
    for pkg in packages:
        pkg = dict(pkg)
        for key in ("deps", "boms"):
            declarations = []
            for d in pkg.get(key, []):
                parts = d.get("version_parts")
                if parts:
                    d = dict(d)
                    version = ""
                    for part in parts:
                        if type(part) != "string":
                            part = properties.get(part["package"], {}).get(part["property"])
                            if part == None:
                                version = None
                                break
                        version += part
                    d["version"] = version or None
                    d.pop("version_parts")
                declarations.append(d)
            pkg[key] = declarations
        out.append(pkg)
    return out

def merge_plugin_requirements(packages, key = "deps"):
    """The version each Maven artifact must have for every plugin of the build.

    Args:
        packages: List of dicts with `package`, `version` and `deps`, the
            latter dicts with `coordinate` (`group:artifact`), `version`
            (a string, "" for a declaration that leaves it to a BoM, or None
            for one that names no usable one) and `checked`. A declaration
            that is not `checked` (one the reader found inside a condition)
            is no requirement.
        key: `"deps"` for the artifacts, `"boms"` for the BoMs.

    Returns:
        A dict of coordinate to a dict with `version` (the highest declared,
        or None when no plugin names one), `managed` (whether a plugin
        leaves the version to a BoM), `declared_by`, the list of
        `package:<name> <version>` strings of the plugins that declare it, and
        `exclusions`, the `group:artifact`s every declaration of it excludes
        from what it brings (one that excludes nothing brings them all, as in
        Gradle, where any path to an artifact keeps it).
    """
    requirements = {}
    for pkg in packages:
        label = "package:%s %s" % (pkg["package"], pkg["version"])
        for d in pkg.get(key, []):
            if not d["checked"]:
                continue
            exclusions = d.get("exclusions", [])
            req = requirements.get(d["coordinate"])
            if req == None:
                req = {"version": None, "managed": False, "declared_by": [], "exclusions": sorted(exclusions)}
                requirements[d["coordinate"]] = req
            else:
                req["exclusions"] = [e for e in req["exclusions"] if e in exclusions]
            if label not in req["declared_by"]:
                req["declared_by"].append(label)
            v = d["version"]
            if v == "":
                req["managed"] = True
            elif v != None and (req["version"] == None or compare_maven_versions(v, req["version"]) > 0):
                req["version"] = v
    return requirements

def maven_problems(requirements, resolved):
    """The requirements `@rules_flutter_maven` does not meet.

    Args:
        requirements: The result of `merge_plugin_requirements`.
        resolved: Dict of `group:artifact` to the version resolved.

    Returns:
        A list of dicts with `coordinate`, `version`, `managed`, `declared_by` and
        `reason` (`"missing"` or `"resolves <version>"`), sorted by
        coordinate. A requirement with no version is met by any resolution.
    """
    problems = []
    for coordinate in sorted(requirements.keys()):
        req = requirements[coordinate]
        have = resolved.get(coordinate)
        if have == None:
            reason = "missing"
        elif req["version"] != None and compare_maven_versions(have, req["version"]) < 0:
            reason = "resolves " + have
        else:
            continue
        problems.append({
            "coordinate": coordinate,
            "version": req["version"],
            "managed": req.get("managed", False),
            "declared_by": req["declared_by"],
            "reason": reason,
        })
    return problems

def maven_check_message(data, linked, report = None):
    """What an application that links `linked` plugins fails with, or "".

    Args:
        data: The decoded `maven_requirements.json` of the build: `resolved`
            (`group:artifact` to version), `boms` (the BoMs of the install,
            `group:artifact` to version) and `packages` (each a dict of
            `package`, `version`, `script`, `deps`, `boms` and `unread`).
        linked: The names of the packages whose Android libraries the
            application links. A package the hub records no requirements for
            needs nothing.
        report: The label of the application's `maven_artifacts` target, which
            the message points to. None points to a hub's.

    Returns:
        The failure message naming only what those packages need, or the empty
        string when `@rules_flutter_maven` provides all of it.
    """
    packages = [p for p in data["packages"] if p["package"] in linked]
    return format_maven_failure(
        maven_problems(merge_plugin_requirements(packages), data["resolved"]),
        report,
        maven_problems(merge_plugin_requirements(packages, "boms"), data.get("boms", {})),
    )

def maven_warning_message(data, linked, app):
    """What an application that links `linked` plugins warns of, or "".

    The Gradle lines of those plugins that the reader did not check: ones it
    cannot read, and declarations inside a condition. Each is named by file
    and line. A reader of Gradle's language that is not Gradle can be wrong
    about these, so they warn rather than fail.

    Args:
        data: The decoded `maven_requirements.json` of the build, as for
            `maven_check_message`.
        linked: The names of the packages whose Android libraries the
            application links.
        app: The label of the application, for the message.

    Returns:
        The warning, or the empty string when there is nothing to say.
    """
    form = []
    form_packages = []
    conditional = []
    for p in sorted(data["packages"], key = lambda p: p["package"]):
        if p["package"] not in linked:
            continue
        for kind, out in [("form", form), ("conditional", conditional)]:
            # A plugin the root annotated has had its dependencies stated.
            if kind == "form" and p.get("annotated"):
                continue
            lines = [u for u in p["unread"] if u["why"] == kind]
            if lines:
                if kind == "form":
                    form_packages.append(p["package"])
                out.append("    package:%s %s\n%s" % (
                    p["package"],
                    p["version"],
                    "\n".join([
                        "        %s:%d: %s" % (u.get("script") or p["script"], u["line_number"], u["line"])
                        for u in lines
                    ]),
                ))
    parts = []
    if form:
        parts.append((
            "{app} links Android plugins whose Gradle builds declare " +
            "dependencies in a form rules_flutter does not read, so it neither " +
            "checks them nor links them:\n\n{groups}\n\n" +
            "If a plugin's Android code then fails to compile, add the " +
            "artifacts it needs to the root module's " +
            '`maven.install(name = "rules_flutter_maven", artifacts = [...])` ' +
            "and state them for that plugin in MODULE.bazel, once per package:\n\n" +
            "{lines}\n\n" +
            "A plugin that needs more than dependencies can have an overlay " +
            "instead (flutter_pub.plugin_overlays)."
        ).format(
            app = app,
            groups = "\n".join(form),
            lines = "\n".join([
                '    flutter_pub.annotation(package = "%s", android_deps = ["@rules_flutter_maven//:<artifact target>"])' % name
                for name in form_packages
            ]),
        ))
    if conditional:
        parts.append((
            "{app} links Android plugins whose Gradle builds declare " +
            "dependencies inside a condition or another block, which Gradle " +
            "may or may not run. rules_flutter links each one " +
            "@rules_flutter_maven has, and does not require the others:" +
            "\n\n{groups}\n\n" +
            "If a plugin's Android code needs one that is missing, add it to " +
            'the root module\'s `maven.install(name = "rules_flutter_maven", ' +
            "artifacts = [...])`."
        ).format(app = app, groups = "\n".join(conditional)))
    return "\n\n".join(parts)

def maven_app_report(data, linked, app):
    """What an application's `maven_artifacts` target reads.

    Args:
        data: The decoded `maven_requirements.json` of the build, as for
            `maven_check_message`.
        linked: The names of the packages whose Android libraries the
            application links.
        app: The label of the application, for the header.

    Returns:
        The artifacts those packages declare, as `artifacts_report` writes
        them.
    """
    packages = [p for p in data["packages"] if p["package"] in linked]
    return artifacts_report(
        merge_plugin_requirements(packages),
        data["resolved"],
        data["repositories"],
        app,
        unread_lines(packages),
        merge_plugin_requirements(packages, "boms"),
        data.get("boms", {}),
        data.get("locked", True),
        data.get("listed", {}),
    )

def _artifact_line(p, note):
    if p["version"]:
        coordinate = p["coordinate"] + ":" + p["version"]
    elif p.get("managed"):
        # Its version is the BoM's.
        coordinate = p["coordinate"]
    else:
        coordinate = p["coordinate"] + ":<version>"
    return '"%s",  # declared by %s%s' % (
        coordinate,
        ", ".join(p["declared_by"]),
        "; " + note if note else "",
    )

def format_maven_failure(problems, report = None, bom_problems = []):
    """The message `check()` fails with.

    Args:
        problems: The result of `maven_problems` for the artifacts.
        report: The label of the application's `maven_artifacts` target. None
            points to a hub's, which covers every plugin of the build.
        bom_problems: The result of `maven_problems` for the BoMs, against
            those of the install.

    Returns:
        The message, listing every problem at once, or the empty string when
        there is none.
    """
    if not problems and not bom_problems:
        return ""
    blocks = []
    for attribute, found in [("artifacts", problems), ("boms", bom_problems)]:
        if found:
            blocks.append("Add to `{attribute} = [...]`:\n\n    {lines}".format(
                attribute = attribute,
                lines = "\n    ".join([_artifact_line(p, p["reason"]) for p in found]),
            ))
    return (
        "The Android plugins this app links declare Maven " +
        "dependencies that @rules_flutter_maven does not provide at a " +
        "high enough version. Gradle gives a plugin the highest version " +
        "declared anywhere in the app, and so does the single resolution " +
        "behind @rules_flutter_maven. Change the root module's " +
        '`maven.install(name = "rules_flutter_maven")`.\n\n{blocks}\n\n' +
        "Then regenerate that install's lock file:\n\n" +
        "    REPIN=1 bazel run @rules_flutter_maven//:pin\n\n" +
        "`bazel run {report}` prints the complete block for {scope}."
    ).format(
        blocks = "\n\n".join(blocks),
        report = report or "@<hub>//android:maven_artifacts",
        scope = "the plugins this app links" if report else "every plugin of the build",
    )

def unread_lines(packages):
    """The Gradle lines of `packages` the reader cannot read, for a report.

    A plugin the root annotated has had its dependencies stated, so its lines
    are left out, as `maven_warning_message` leaves them out.

    Args:
        packages: Dicts as `maven_check_message`'s `data` holds them.

    Returns:
        A list of dicts with `package` (`package:<name> <version>`), `script`,
        `line_number` and `line`, by package and line.
    """
    lines = []
    for p in sorted(packages, key = lambda p: p["package"]):
        if p.get("annotated"):
            continue
        for u in p["unread"]:
            if u["why"] == "form":
                lines.append({
                    "package": "package:%s %s" % (p["package"], p["version"]),
                    "script": u.get("script") or p["script"],
                    "line_number": u["line_number"],
                    "line": u["line"],
                })
    return lines

def artifacts_report(requirements, resolved, repositories, app = None, unread = [], boms = {}, resolved_boms = {}, locked = True, listed = {}):
    """The JSON a `maven_artifacts` program reads (tools/maven_artifacts.dart).

    The program prints the lines to paste into `maven.install`, after reading
    the Gradle module metadata of what the install resolves, which takes the
    network and so cannot happen in the build.

    Args:
        requirements: The result of `merge_plugin_requirements`.
        resolved: Dict of `group:artifact` to the version the install
            resolves.
        repositories: The install's Maven repositories, in its order.
        app: The label of the application whose plugins `requirements` cover.
            None means every plugin of the build.
        unread: The result of `unread_lines` for the same plugins: what they
            may declare that `requirements` does not have.
        boms: The result of `merge_plugin_requirements` for their BoMs.
        resolved_boms: Dict of `group:artifact` to the version of each BoM
            the install lists.
        locked: Whether the install has a lock file, which a change to it
            regenerates.
        listed: Dict of `group:artifact` to the coordinate the install's
            `artifacts` list it as, for the artifacts it lists (not those it
            resolves for them).

    Returns:
        The JSON string.
    """
    return json.encode({
        "app": app,
        "boms": boms,
        "listed": listed,
        "locked": locked,
        "repositories": repositories,
        "requirements": requirements,
        "resolved": resolved,
        "resolved_boms": resolved_boms,
        "unread": unread,
    })

def _resolved_versions(build):
    """`group:artifact` to version from a rules_jvm_external repo's BUILD."""
    plain = {}
    classified = {}
    for chunk in build.split("maven_coordinates=")[1:]:
        parts = chunk.split('"')[0].split("@")[0].split(":")
        if len(parts) < 3:
            continue
        key = parts[0] + ":" + parts[1]
        versions = plain if len(parts) == 3 else classified
        if key not in versions or compare_maven_versions(parts[2], versions[key]) > 0:
            versions[key] = parts[2]

    # A classifier-less entry is the artifact itself.
    best = dict(classified)
    best.update(plain)
    return best

def _lines(rctx, label):
    return [line.strip() for line in rctx.read(rctx.path(label)).splitlines() if line.strip()]

def _flutter_android_maven_impl(rctx):
    build = rctx.read(rctx.path(Label("@rules_flutter_maven//:BUILD")))
    resolved = _resolved_versions(build)

    # A pinned install's `pin` is an alias of its unpinned repository's.
    # rules_jvm_external gives another module no provider, no repository
    # attribute it can read and no label of the install's `lock_file` (the
    # `maven.install` tag is the root module's), so the alias in the BUILD it
    # writes is what says the install is locked.
    locked = "unpinned_" in build

    # The BoMs the install lists, which rules_jvm_external lists for its own
    # `outdated` program, as `group:artifact:version`.
    resolved_boms = {}
    for bom in _lines(rctx, Label("@rules_flutter_maven//:outdated.boms")):
        fields = bom.split(":")
        if len(fields) >= 3:
            resolved_boms[fields[0] + ":" + fields[1]] = fields[-1]

    # The artifacts the install lists, likewise.
    listed = {}
    for artifact in _lines(rctx, Label("@rules_flutter_maven//:outdated.artifacts")):
        fields = artifact.split(":")
        if len(fields) >= 2:
            listed[fields[0] + ":" + fields[1]] = artifact

    # The install's repositories, which rules_jvm_external lists for its own
    # `outdated` program.
    repositories = _lines(rctx, Label("@rules_flutter_maven//:outdated.repositories"))
    packages = resolve_plugin_properties([json.decode(rctx.read(rctx.path(label))) for label in rctx.attr.spokes])

    annotated = annotated_requirements(packages, resolved)
    if annotated.errors:
        fail("\n\n".join(annotated.errors))
    packages = [p for p in annotated.packages if p["deps"] or p.get("boms") or p["unread"]]

    # The whole build's requirements, as an application's check reads them: it
    # picks the packages it links and no others. The build-wide report below is
    # for finding what a lock's plugins need all at once.
    requirements_json = json.encode({
        "boms": resolved_boms,
        "listed": listed,
        "locked": locked,
        "repositories": repositories,
        "resolved": resolved,
        "packages": packages,
    })
    rctx.file("resolved.bzl", "RESOLVED = %s\n" % repr(resolved))
    rctx.file("report.json", artifacts_report(
        merge_plugin_requirements(packages),
        resolved,
        repositories,
        unread = unread_lines(packages),
        boms = merge_plugin_requirements(packages, "boms"),
        resolved_boms = resolved_boms,
        locked = locked,
        listed = listed,
    ))
    rctx.file("maven_artifacts.dart", rctx.read(Label("//flutter/private/tools:maven_artifacts.dart")))
    rctx.file("BUILD.bazel", """\
load("@rules_dart//dart:defs.bzl", "dart_binary")
load("@rules_flutter//flutter/private:flutter_android_plugin_libs.bzl", "flutter_android_maven_requirements")

# What an application's `flutter_android_plugin_libs` checks the plugins it
# links against.
flutter_android_maven_requirements(
    name = "requirements",
    data = {data},
    visibility = ["//visibility:public"],
)

# Prints every Maven artifact the build's Android plugins declare, and those
# Gradle would align, as the lines to paste into
# maven.install(name = "rules_flutter_maven").
dart_binary(
    name = "maven_artifacts",
    args = ["$(rlocationpath :report.json)"],
    compile_mode = "exe",
    data = [":report.json"],
    main = "maven_artifacts.dart",
    visibility = ["//visibility:public"],
    deps = ["@rules_dart//dart/runfiles"],
)
""".replace("{data}", repr(requirements_json)))

flutter_android_maven = repository_rule(
    implementation = _flutter_android_maven_impl,
    attrs = {
        "spokes": attr.label_list(
            doc = "Each built spoke's `flutter_android_maven_deps.json`.",
            allow_files = True,
        ),
    },
    doc = """The Maven requirements of the build's Android plugins.

Reads the versions `@rules_flutter_maven` resolved and the dependencies every
spoke's Gradle build declares, and generates a `requirements` target (for an
application's check of the plugins it links), `resolved.bzl` (what a plugin's
library may depend on) and the `maven_artifacts` target (every plugin of the
lock at once). It is fetched only when an Android build links a plugin.
""",
)
