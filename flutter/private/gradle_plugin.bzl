"""Plugin-level Gradle orchestration and validation.

`resolve_plugin_maven_deps` reduces the spoke's Android build dependencies
to Bazel labels, failing closed on anything it cannot translate. The
manifest/package/label validators check plugin-controlled strings before
they reach generated BUILD text. The statement scanners live in
`gradle_readers.bzl`; this module only consumes the shared model, never
raw text.
"""

load(
    ":gradle_deps.bzl",
    _deps_maven_labels_for_gradle = "maven_labels_for_gradle",
)
load(
    ":gradle_lex.bzl",
    _lex_language_of = "gradle_language_of",
)
load(
    ":gradle_model.bzl",
    _model_package_reader = "gradle_package_reader",
)

def resolve_plugin_maven_deps(ctx, build_file, build_content):
    """Translate the spoke's Android build deps to Bazel labels.

    Reads the spoke's single Gradle build (see `plugin_android_build`;
    `build_file` is its path for messages, `build_content` its text) and
    reduces its runtime dependencies to Maven coordinates
    with `maven_labels_for_gradle` — layering the user's
    `flutter.pub(android_maven_deps)` over the built-in table and honouring
    `flutter.pub(android_maven_ignore)` — then maps them to
    `@rules_android_maven//:...` labels.

    Fail-closed: coordinates found in neither table, and declarations no
    coordinate can be reduced from, fail the fetch with a message naming the
    package, the build file, every offending entry, and both attributes with
    an example. A plugin whose native dependency is missing can otherwise
    still compile — a reflection-only or run-time-only dep — and then crash
    on the device, so dropping them silently is not an option.

    Args:
        ctx: the spoke repository context (attrs, path, exists and read).
        build_file: the spoke-relative Gradle build path, for messages.
        build_content: the text of the spoke's single Gradle build.

    Returns:
        A sorted list of distinct `@rules_android_maven//:...` labels.
    """
    if not build_content:
        return []

    # The workspace owner's label mapping is trusted like hand-written
    # BUILD text, but a broken-out value would still poison the generated
    # deps list; refuse it here (naming the package and the key) the way
    # the extension refuses it at eval time.
    for _coord_key in ctx.attr.android_maven_deps.keys():
        _label_value = ctx.attr.android_maven_deps[_coord_key]
        if not is_maven_dep_label(_label_value):
            fail((
                "flutter.pub spoke for \"{pkg}\": android_maven_deps[{key}] " +
                "is not a valid Bazel label ({label}). Map the coordinate " +
                "to a label in another repository (\"@...\" ) or an absolute " +
                "label (\"//...\") with no quotes, backslashes or newlines."
            ).format(
                pkg = ctx.attr.package_name,
                key = _coord_key,
                label = _label_value,
            ))

    result = _deps_maven_labels_for_gradle(
        build_content,
        ctx.attr.android_maven_deps,
        ctx.attr.android_maven_ignore,
        _model_package_reader(ctx),
        _lex_language_of(build_file),
    )
    if result.unknown or result.unreadable:
        details = []
        if result.unknown:
            details.append("unknown Maven coordinates: " + ", ".join(result.unknown))
        if result.unreadable:
            details.append("unreadable dependency declarations: " + ", ".join(result.unreadable))
        fail(
            ('flutter.pub spoke for "{pkg}": {gradle} declares Android ' +
             "dependencies rules_flutter cannot translate to Bazel labels " +
             "({details}). Map each external artifact in MODULE.bazel, e.g. " +
             'flutter.pub(android_maven_deps = {{"com.example:thing": ' +
             '"@rules_android_maven//:com_example_thing_thing"}}), or silence ' +
             "a coordinate that needs no label with " +
             'flutter.pub(android_maven_ignore = ["com.example:thing"]). ' +
             "Declarations that are not Maven coordinates (version-catalog " +
             "`libs.*` refs, variables, local jars) need a plugin overlay " +
             "instead - see flutter.plugin_overlays.").format(
                pkg = ctx.attr.package_name,
                gradle = build_file,
                details = "; ".join(details),
            ),
        )
    return result.labels

def parse_android_manifest_package(content):
    """Extract the `package` attribute from an AndroidManifest.xml.

    The pre-AGP-8 way for a library to declare its namespace.

    Args:
        content: The AndroidManifest.xml file content.

    Returns:
        The `package` attribute of the `<manifest>` element, or empty
        string when the manifest carries none.
    """
    start = content.find("<manifest")
    if start < 0:
        return ""
    end = content.find(">", start)
    if end < 0:
        return ""
    tag = content[start:end]
    for quote in ('"', "'"):
        marker = "package=" + quote
        idx = tag.find(marker)
        if idx >= 0:
            close = tag.find(quote, idx + len(marker))
            if close >= 0:
                return tag[idx + len(marker):close]
    return ""

def is_java_package_name(value):
    """True when `value` is a well-formed Java package name.

    Each dot-separated segment must start with a letter or underscore and
    continue with letters, digits or underscores. Used to refuse a hostile
    plugin-controlled Android namespace before it reaches generated BUILD
    text.

    Args:
        value: The candidate package name.

    Returns:
        True for names like `com.example.plugin`, False for "", for empty
        segments, and for anything holding quotes, dashes, spaces or `$`.
    """
    if not value:
        return False
    for part in value.split("."):
        if not part:
            return False
        for i in range(len(part)):
            c = part[i:i + 1]
            is_start = ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or c == "_"
            is_part = is_start or ("0" <= c and c <= "9")
            if not (is_part if i else is_start):
                return False
    return True

def is_maven_dep_label(value):
    """True when `value` is a plausible Bazel label for `android_maven_deps`.

    The value must look like a label in another repository (`@...`) or an
    absolute label (`//...`), and must not hold a quote, a backslash or a
    newline that could break out of the generated `deps` list.

    Args:
        value: The candidate label string.

    Returns:
        True when the value has a label shape and no quoting characters.
    """
    if not value:
        return False
    if not (value.startswith("@") or value.startswith("//")):
        return False
    for i in range(len(value)):
        c = value[i:i + 1]
        if c == '"' or c == "'" or c == "\\" or c == "\n" or c == "\r":
            return False
    return True
