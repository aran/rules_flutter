"""Dependency reader: the plugin Gradle build's runtime deps as Bazel labels.

Folds the shared statement model (`gradle_model.bzl`): the same lexed
scripts, the same `apply from:` files, the same depth and cycle limits
every other reader sees. Layout is insignificant (single-line blocks,
`;` separators, parenthesised calls spanning lines) and comments and
string contents never count. Statement semantics are the historical
ones, verbatim, so every refusal the test suite pins keeps its exact
text; only lexing gained the dialect parameter.
"""

load(
    ":gradle_model.bzl",
    _model_collect_files = "gradle_collect_files",
)
load(
    ":gradle_parse.bzl",
    _parse_add = "parse_gradle_add",
    _parse_code_without_strings = "gradle_code_without_strings",
    _parse_leading_word = "gradle_leading_word",
    _parse_stmt_token = "gradle_stmt_token",
)

# Map well-known maven coordinates the plugin's `build.gradle` may pull
# in to labels under `@rules_android_maven`. We translate
# `implementation("group:artifact:version")` declarations into Bazel
# dep labels by looking up the `group:artifact` here. The user's
# workspace `maven.install` must include matching artifacts; the bundle
# of androidx + jetbrains coordinates Flutter plugins typically use is
# documented in `docs/TESTING.md` § Plugin verification matrix.
_MAVEN_COORD_TO_LABEL = {
    "androidx.annotation:annotation": "@rules_android_maven//:androidx_annotation_annotation",
    "androidx.lifecycle:lifecycle-common": "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
    "androidx.lifecycle:lifecycle-runtime": "@rules_android_maven//:androidx_lifecycle_lifecycle_runtime",
    "androidx.media:media": "@rules_android_maven//:androidx_media_media",
    "androidx.window:window": "@rules_android_maven//:androidx_window_window",
    "androidx.core:core": "@rules_android_maven//:androidx_core_core",
    "androidx.browser:browser": "@rules_android_maven//:androidx_browser_browser",
    "androidx.fragment:fragment": "@rules_android_maven//:androidx_fragment_fragment",
    "androidx.activity:activity": "@rules_android_maven//:androidx_activity_activity",
    "com.google.android.material:material": "@rules_android_maven//:com_google_android_material_material",
    "com.getkeepsafe.relinker:relinker": "@rules_android_maven//:com_getkeepsafe_relinker_relinker",
}

# Coordinates we deliberately ignore — provided by the kt_android_library
# rule itself or out-of-band. Listing them avoids the parser falling back
# to "drop unknown" silently for things we do recognize.
_MAVEN_COORDS_PROVIDED = {
    "org.jetbrains.kotlin:kotlin-stdlib": True,
    "org.jetbrains.kotlin:kotlin-stdlib-jdk7": True,
    "org.jetbrains.kotlin:kotlin-stdlib-jdk8": True,
}

_MAVEN_RUNTIME_CONFIGS = ("implementation", "api", "runtimeOnly", "compile")
_MAVEN_RUNTIME_SUFFIXES = ("Implementation", "Api", "RuntimeOnly")

def _gradle_is_runtime_config(token):
    """True for configurations that land on the app's runtime classpath."""
    if token in _MAVEN_RUNTIME_CONFIGS:
        return True
    for suffix in _MAVEN_RUNTIME_SUFFIXES:
        if token.endswith(suffix):
            return True
    return False

def _gradle_is_nonruntime_config(token):
    """True for test-source-set and `compileOnly` configurations."""
    if token == "compileOnly" or token.endswith("CompileOnly"):
        return True
    if token.startswith("test"):
        return True
    if "Test" in token:
        return True
    return False

def _gradle_coord_from_inner(inner):
    """Reduce a dependency-notation string's inner text to `group:artifact`.

    `inner` is the text between one pair of quotes (or an `add()` notation
    argument). Anything without a `group:artifact` pair — a version-catalog
    ref, a variable, a local path, a Gradle map — yields "".

    Args:
        inner: The unquoted notation text.

    Returns:
        `group:artifact`, or "" when it has none.
    """
    parts = inner.split(":")
    if len(parts) < 2:
        return ""
    for part in (parts[0], parts[1]):
        if not part:
            return ""
        for i in range(len(part)):
            c = part[i:i + 1]
            if c in " \t/$'\"{}()":
                return ""
    return parts[0] + ":" + parts[1]

def _gradle_coord_of(rest):
    """Reduce dependency notation to `group:artifact`, or "" when it has none.

    `implementation("androidx.browser:browser:1.9.0")` reduces to
    `androidx.browser:browser`; anything without a quoted `group:artifact`
    pair — a version-catalog ref (`libs.foo`), a variable, a local
    `files(...)` / `fileTree(...)` jar, a Gradle map
    (`group: ..., name: ...`) — yields "". The version part may carry Gradle
    templates (`$kotlin_version`); only `group:artifact` is validated, so
    those still reduce. Callers report "" as unreadable unless the notation
    is a `project()` sibling-module reference, which is left out.
    """
    quote_idx = -1
    quote_char = ""
    for q in ('"', "'"):
        idx = rest.find(q)
        if idx >= 0 and (quote_idx < 0 or idx < quote_idx):
            quote_idx = idx
            quote_char = q
    if quote_idx < 0:
        return ""
    end = rest.find(quote_char, quote_idx + 1)
    if end < 0:
        return ""
    return _gradle_coord_from_inner(rest[quote_idx + 1:end])

def _maven_add_coord(coord, merged, ignored, labels, unknown):
    """File one coordinate into `labels` or `unknown` (provided coords pass)."""
    if coord in _MAVEN_COORDS_PROVIDED:
        return
    label = merged.get(coord)
    if label:
        labels[label] = True
    elif coord not in ignored:
        unknown[coord] = True

def _maven_visit_add_stmt(text, merged, ignored, labels, unknown, unreadable):
    """File one bare `add(config, notation)` statement."""
    parsed = _parse_add(text)
    if parsed.kind == "bad":
        unreadable[text] = True
        return
    if parsed.kind == "project":
        if _gradle_is_nonruntime_config(parsed.config) or _gradle_is_runtime_config(parsed.config):
            return
        unreadable[text] = True
        return
    if _gradle_is_nonruntime_config(parsed.config):
        return
    if _gradle_is_runtime_config(parsed.config):
        coord = _gradle_coord_from_inner(parsed.notation)
        if coord:
            _maven_add_coord(coord, merged, ignored, labels, unknown)
        else:
            unreadable[text] = True
        return
    unreadable[text] = True

def _maven_visit_dep_stmt(text, merged, ignored, labels, unknown, unreadable):
    """File one statement inside a non-`buildscript` `dependencies` block."""
    token = _parse_stmt_token(text)
    if token == "add":
        _maven_visit_add_stmt(text, merged, ignored, labels, unknown, unreadable)
        return
    if not token or "." in token:
        unreadable[text] = True
        return
    if _gradle_is_nonruntime_config(token):
        return
    if _gradle_is_runtime_config(token):
        rest = text[len(token):].strip()
        coord = _gradle_coord_of(rest)
        if coord:
            _maven_add_coord(coord, merged, ignored, labels, unknown)
        elif "project(" in rest:
            pass
        else:
            unreadable[text] = True
        return
    if "project(" in text:
        return
    unreadable[text] = True

def _maven_visit_gradle_stmt(text, stack, merged, ignored, labels, unknown, unreadable):
    """File one statement with its block context."""
    tainted = False
    in_buildscript = False
    for name in stack:
        if name == "!":
            tainted = True
        if name == "buildscript":
            in_buildscript = True
    if tainted:
        unreadable[text] = True
        return
    if in_buildscript:
        return
    if stack and stack[len(stack) - 1] == "dependencies":
        _maven_visit_dep_stmt(text, merged, ignored, labels, unknown, unreadable)
        return
    if "dependencies" in _parse_code_without_strings(text).lower():
        unreadable[text] = True

def _maven_visit_open(header, stack, unreadable):
    """Push one block header, reporting nested and stray `dependencies`."""
    in_deps = False
    in_buildscript = False
    for name in stack:
        if name == "dependencies":
            in_deps = True
        if name == "buildscript":
            in_buildscript = True
    if in_deps and not in_buildscript:
        unreadable[header if header else "{"] = True
        stack.append("!")
    else:
        if header and header != "dependencies" and "dependencies" in _parse_code_without_strings(header).lower():
            unreadable[header] = True
        stack.append(_parse_leading_word(header))

def _maven_walk_events(events, merged, ignored, labels, unknown, unreadable):
    """Walk one script's lexed events, filing deps and refusals."""
    stack = []
    for e in events:
        if e.kind == "open":
            _maven_visit_open(e.text, stack, unreadable)
        elif e.kind == "close":
            if stack:
                stack.pop()
        elif e.kind == "unbalanced":
            unreadable[e.text] = True
        else:
            _maven_visit_gradle_stmt(e.text, stack, merged, ignored, labels, unknown, unreadable)

def maven_labels_for_gradle(content, mapping, ignore, read_script = None, language = "groovy"):
    """Translate a Gradle build file's runtime deps to Bazel labels.

    Pure and loadable from another .bzl: `content` is the `build.gradle` /
    `build.gradle.kts` text, `mapping` is a caller-supplied
    `{group:artifact: label}` dict layered over the built-in
    `_MAVEN_COORD_TO_LABEL` (`mapping` wins on collision), and `ignore` is a
    list of `group:artifact` coordinates that need no label.

    The script is lexed string-aware (`//` and `/* */` comments strip only
    outside single-, double-, triple-quoted, slashy and dollar-slashy
    literals) and bracket-aware (newlines, `;` and carriage returns inside
    `(...)` / `[...]` are layout), and split into statements on newlines,
    `;`, `{` and `}` at bracket depth 0, so layout is insignificant: a
    single-line `dependencies { implementation 'g:a:1' }`, two declarations
    on one line separated by `;`, a parenthesised call spanning lines, and
    Gradle's public `add('implementation', 'g:a:1')` (single- or
    double-quoted) resolve exactly like one declaration per line. Only
    statements inside a `dependencies` block that is not inside `buildscript`
    count (`buildscript` dependencies are build classpath, never packaged).

    Covers the configurations that put code on the app's runtime classpath —
    `implementation`, `api`, `runtimeOnly` and legacy `compile` — in both
    Groovy (bare, single-quoted) and Kotlin DSL (parenthesised,
    double-quoted) spellings, including variant-prefixed siblings
    (`debugImplementation`, ...). `compileOnly` is provided-scope (Gradle
    never packages it; the plugin's compile classpath already carries the
    equivalent in the neverlink engine target) and test-source-set
    configurations (`testImplementation`, `androidTest...`, ...) exercise
    the plugin's own unit tests, never the APK — both are left out of every
    list rather than reported. `project()` references name a sibling Gradle
    module, not an external artifact, and are left out the same way.

    `apply from:` scripts in every DSL spelling (`apply from: 'x.gradle'`,
    `apply(from: 'x.gradle')`, `apply(from = "x.gradle.kts")`, each even
    spanning lines) resolve when the path stays inside
    the package: the script is read through `read_script` and parsed the
    same way, recursively, with cycle detection and a depth cap of 10.

    Refusals (each reported in `unreadable`, failing the spoke fetch):
    statements in a `dependencies` block that are neither recognised
    runtime nor non-runtime declarations nor `project()` references
    (version-catalog `libs.*` refs, variables, local `files(...)` jars,
    Gradle maps, interpolated coordinates, nested blocks
    such as `constraints {}`); `dependencies` mentions outside the block
    form (`project.dependencies.add(...)`, `dependencies.implementation
    ...`); an unbalanced bracket at end of input; `apply from:` with a URL,
    an absolute path, a path escaping the
    package, a missing file, or a non-literal argument (or when no
    `read_script` is given).

    Args:
        content: The Gradle build-file text.
        mapping: Dict from `group:artifact` to Bazel label string.
        ignore: List of `group:artifact` coordinates that need no label.
        read_script: Optional callback taking a package-relative applied
            script path and returning its text, or None when the file is
            missing. The repository rule passes a reader confined to the
            package; without one, applied scripts are unreadable.
        language: `"groovy"` or `"kotlin"`, from the file extension.

    Returns:
        `struct(labels, unknown, unreadable)`: `labels` is the sorted,
        distinct Bazel labels for recognised coordinates; `unknown` is the
        sorted coordinates found in neither table and not in `ignore` (nor
        already provided, e.g. `kotlin-stdlib`); `unreadable` is the sorted
        dependency declarations no coordinate could be reduced from.
    """
    merged = dict(_MAVEN_COORD_TO_LABEL)
    if mapping:
        merged.update(mapping)
    ignored = {}
    for coord in (ignore or []):
        ignored[coord] = True
    labels = {}
    unknown = {}
    unreadable = {}
    collected = _model_collect_files("", content, language, read_script)
    for f in collected.files:
        _maven_walk_events(f.events, merged, ignored, labels, unknown, unreadable)
    for refusal in collected.bad:
        unreadable[refusal.statement] = True
    return struct(
        labels = sorted(labels.keys()),
        unknown = sorted(unknown.keys()),
        unreadable = sorted(unreadable.keys()),
    )
