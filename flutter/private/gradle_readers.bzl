"""Namespace, native-build and ProGuard readers for the plugin Gradle build.

Every reader folds the shared statement model (`gradle_model.bzl`): the
same lexed statements, the same `apply from:` scripts, the same depth
and cycle limits the dependency reader (`gradle_deps.bzl`) sees. No
reader scans raw text or single lines.

Never silent: a statement that names the reader's keyword in code (never
in a comment or a string) but whose value the model cannot determine is
reported for refusal, and the repository rule fails the fetch naming the
plugin, the file and the statement. A plugin overlay
(`flutter.plugin_overlays`) stays the escape for builds no model covers.
"""

load(
    ":gradle_lex.bzl",
    _lex_language_of = "gradle_language_of",
    _lex_lex = "gradle_lex",
)
load(
    ":gradle_model.bzl",
    _model_block_name = "gradle_block_name",
    _model_code_text = "gradle_code_text",
    _model_collect_files = "gradle_collect_files",
    _model_has_word = "gradle_has_word",
    _model_package_reader = "gradle_package_reader",
    _model_segments = "gradle_segments",
)
load(
    ":gradle_parse.bzl",
    _parse_leading_word = "gradle_leading_word",
)
load(
    ":gradle_plugin.bzl",
    _plugin_manifest_package = "parse_android_manifest_package",
)

def _gradle_dollar_slashy_value(literal):
    """Plain value of a `$/.../$` span; `$` inside may interpolate."""
    if len(literal) < 4 or literal[len(literal) - 2:] != "/$":
        return (None, False)
    inner = literal[2:len(literal) - 2]
    if "$" in inner:
        return (None, False)
    return (inner, True)

def _gradle_slashy_value(literal):
    """Plain value of a `/.../` span; `$` and backslash refuse it."""
    if len(literal) < 2 or literal[len(literal) - 1:] != "/":
        return (None, False)
    inner = literal[1:len(literal) - 1]
    if "$" in inner or "\\" in inner:
        return (None, False)
    return (inner, True)

def _gradle_quoted_value(literal, language):
    """Plain value of a quoted span; Kotlin `Char` and `$` refuse it."""
    q = literal[:1]
    if q != "'" and q != '"':
        return (None, False)
    if q == "'" and language == "kotlin":
        return (None, False)
    return _gradle_delimited_value(literal, q)

def _gradle_delimited_value(literal, q):
    """Plain value of a quote-delimited span; `$` in `"` may interpolate."""
    if literal[:3] == q + q + q:
        if len(literal) < 6 or literal[len(literal) - 3:] != q + q + q:
            return (None, False)
        inner = literal[3:len(literal) - 3]
        if q == '"' and "$" in inner:
            return (None, False)
        return (inner, True)
    if len(literal) < 2 or literal[len(literal) - 1:] != q:
        return (None, False)
    inner = literal[1:len(literal) - 1]
    if q == '"' and "$" in inner:
        return (None, False)
    return (inner, True)

def _gradle_string_value(literal, language):
    """Plain string value of one literal span; `(value, ok)`.

    Single-quoted Groovy holds its text raw (`$` never interpolates
    there); every other quoted, slashy or dollar-slashy form with a `$`
    may interpolate and is not plain. Kotlin single-quoted is a `Char`,
    never a string. Anything less than a whole literal — a variable, a
    catalog ref, concatenation residue — is not plain either.
    """
    if literal[:2] == "$/":
        return _gradle_dollar_slashy_value(literal)
    if literal[:1] == "/":
        return _gradle_slashy_value(literal)
    return _gradle_quoted_value(literal, language)

def _gradle_namespace_result(statement, value, literal):
    """One namespace declaration: `value` with its `literal` flag."""
    return struct(statement = statement, value = value, literal = literal)

def _gradle_namespace_forms(stmt, segs, compact, forms, language):
    """File one namespace-shaped statement as good, bad or ignored."""
    literals = [s.text for s in segs if not s.code]
    if len(literals) == 0:
        # A bare reference (`namespace`, `android.namespace`) reads
        # nothing; any other declaration-shaped statement without a
        # literal has a non-literal value.
        if compact in ("namespace", "android.namespace"):
            return None
        return _gradle_namespace_result(stmt, "", False)
    if len(literals) != 1 or compact not in forms:
        return _gradle_namespace_result(stmt, "", False)
    (inner, ok) = _gradle_string_value(literals[0], language)
    if not ok:
        return _gradle_namespace_result(stmt, "", False)
    return _gradle_namespace_result(stmt, inner, True)

def _gradle_parse_namespace_stmt(stmt, stack, language):
    """Parse one lexed statement as an Android namespace declaration.

    A declaration is a `namespace` assignment or call whose innermost
    block is `android` (at any nesting depth, including the
    `android.apply { ... }` and `configure<LibraryExtension> { ... }`
    receiver shapes), or a qualified `android.namespace = ...` at any
    depth (nested self-delegation, deferred `afterEvaluate { ... }`
    configuration). Anything else — including a `namespace` word inside
    a nested non-`android` block — declares nothing. Comments never reach
    this function (the lexer drops them) and string contents arrive as
    literal segments, so neither can count.

    Args:
        stmt: One statement from `gradle_lex`.
        stack: The block-name stack around the statement.
        language: `"groovy"` or `"kotlin"`.

    Returns:
        None when the statement declares no namespace, else
        `struct(statement, value, literal)`; `literal` is False when the
        statement names a namespace but its value is not one plain
        string literal.
    """
    segs = _model_segments(stmt, language)
    code = "".join([s.text for s in segs if s.code])
    compact = code.replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "")
    word = _parse_leading_word(code.strip())
    if word == "namespace":
        if not stack or _model_block_name(stack[len(stack) - 1]) != "android":
            return None
        return _gradle_namespace_forms(stmt, segs, compact, (
            "namespace=",
            "namespace",
            "namespace()",
            "namespace.set()",
        ), language)
    if word == "android":
        if len(compact) < 17 or compact[:17] != "android.namespace":
            return None
        tail = compact[17:]
        if tail != "" and tail[0] not in "=(.":
            return None
        return _gradle_namespace_forms(stmt, segs, compact, (
            "android.namespace=",
        ), language)
    return None

def _gradle_namespaces_of_events(events, language, file):
    """Namespace declarations among one script's events, tagged with `file`."""
    found = []
    stack = []
    for e in events:
        if e.kind == "open":
            stack.append(e.text)
        elif e.kind == "close":
            if stack:
                stack.pop()
        elif e.kind == "stmt":
            parsed = _gradle_parse_namespace_stmt(e.text, stack, language)
            if parsed != None:
                found.append(struct(
                    file = file,
                    statement = parsed.statement,
                    value = parsed.value,
                    literal = parsed.literal,
                ))
    return found

def gradle_scan_namespaces(files):
    """Namespace declarations across collected scripts, in source order.

    Gradle applies assignments in order, so the last literal one wins.

    Args:
        files: Collected scripts (`struct(path, language, events)`).

    Returns:
        The `struct(statement, value, literal)` list in source order.
    """
    found = []
    for f in files:
        found.extend(_gradle_namespaces_of_events(f.events, f.language, f.path))
    return found

def gradle_android_namespaces(content, language = "groovy"):
    """List every Android namespace declaration in one Gradle script.

    Walks the same lexed statement model the dependency reader uses, so
    layout is insignificant and comments and string contents never count.
    Several assignments each appear; Gradle applies them in order, so the
    last one wins.

    Args:
        content: The `build.gradle` / `build.gradle.kts` file content.
        language: `"groovy"` or `"kotlin"`, from the file extension.

    Returns:
        The `struct(statement, value, literal)` list in source order.
    """
    found = []
    stack = []
    for e in _lex_lex(content, language):
        if e.kind == "open":
            stack.append(e.text)
        elif e.kind == "close":
            if stack:
                stack.pop()
        elif e.kind == "stmt":
            parsed = _gradle_parse_namespace_stmt(e.text, stack, language)
            if parsed != None:
                found.append(parsed)
    return found

def parse_gradle_android_namespace(content, language = "groovy"):
    """Extract `android.namespace` from a Gradle build script.

    Reads the same lexed statement model as the dependency parser: a
    `namespace` assignment or call whose innermost block is `android`
    (even on one line, even nested inside other blocks), or a qualified
    `android.namespace = ...` at any depth. Comments and string contents
    never count. When several assignments exist the last one wins, the
    way Gradle applies them.

    Args:
        content: The `build.gradle` / `build.gradle.kts` file content.
        language: `"groovy"` or `"kotlin"`, from the file extension.

    Returns:
        The declared namespace, or empty string when the script
        declares none. A declaration whose value is not one plain string
        literal is reported through `gradle_android_namespaces` and
        refused by the repository rule; here it reads as no namespace.
    """
    value = ""
    for ns in gradle_android_namespaces(content, language):
        if ns.literal and ns.value:
            value = ns.value
    return value

def detect_android_namespace(ctx, build_file, build_content):
    """Resolve the plugin's Android namespace the way AGP does.

    AGP determines a library's namespace from `android.namespace` in the
    project's build scripts, falling back to the manifest's `package`
    attribute for pre-AGP-8 projects. The namespace is where the
    generated `R` and `BuildConfig` classes live, so resource
    references like `R.drawable.ic_mic` only resolve when we use the
    same one. `build_file` / `build_content` are the spoke's single
    Gradle build (see `plugin_android_build`); applied scripts are read
    the same way the dependency reader reads them.

    Several assignments resolve last-wins, the way Gradle applies them. A
    declaration whose value is not one plain string literal fails the
    fetch, naming the plugin, the file and the statement. Returns empty
    string when the plugin declares no namespace anywhere.

    Args:
        ctx: the spoke repository context (package name, manifest read).
        build_file: the spoke-relative Gradle build path, for errors.
        build_content: the text of the spoke's single Gradle build.

    Returns:
        The Android namespace, or "" when the plugin declares none.
    """
    if build_content:
        collected = _model_collect_files(
            build_file,
            build_content,
            _lex_language_of(build_file),
            _model_package_reader(ctx),
        )
        value = ""
        for ns in gradle_scan_namespaces(collected.files):
            if not ns.literal:
                fail((
                    "flutter.pub spoke for \"{pkg}\": {gradle} sets the Android " +
                    "namespace to {stmt}, which is not one plain string literal " +
                    "(expected namespace = 'com.example.plugin'). A namespace " +
                    "read from a variable, a catalog or an expression cannot " +
                    "be resolved to a Java package at fetch time."
                ).format(
                    pkg = ctx.attr.package_name,
                    gradle = ns.file,
                    stmt = repr(ns.statement),
                ))
            if ns.value:
                value = ns.value
        if value:
            return value
    manifest_path = ctx.path("android/src/main/AndroidManifest.xml")
    if manifest_path.exists:
        return _plugin_manifest_package(ctx.read(manifest_path))
    return ""

def gradle_scan_native(files):
    """Every `(file, statement)` mentioning `externalNativeBuild` in code.

    Comments and string contents never reach the check (the lexer drops
    the former, the segment model blanks the latter), so only a real
    reference counts — wherever in the collected scripts it stands,
    including applied scripts.

    Args:
        files: Collected scripts (`struct(path, language, events)`).

    Returns:
        The `(file, statement)` structs in source order.
    """
    found = []
    for f in files:
        for e in f.events:
            if e.kind != "stmt" and e.kind != "open":
                continue
            if _model_has_word(e.text, f.language, "externalNativeBuild"):
                found.append(struct(file = f.path, statement = e.text))
    return found

def detect_android_native_build(ctx, build_file, build_content):
    """Find the plugin's NDK build wherever its Gradle scripts declare it.

    Gradle-built Flutter plugins declare `externalNativeBuild` in the
    project's build scripts to compile C/C++ sources (CMake / ndk-build)
    into a shared library the APK must carry — e.g.
    package:jni's libdartjni.so. rules_flutter has no generic translation
    for those builds; packages that need one ship a curated overlay
    (bundled under `@rules_flutter//ext/` or user-supplied via
    `flutter.plugin_overlays`). Detection lets the generated android/
    sub-package fail loudly instead of silently producing an APK missing
    the library. Applied scripts are read the same way the dependency
    reader reads them, so factoring the NDK stanza into an applied
    script cannot hide it.

    Args:
        ctx: the spoke repository context (path, exists and read).
        build_file: the spoke-relative Gradle build path, for messages.
        build_content: The spoke's single Gradle build text (see
            `plugin_android_build`); "" when the plugin ships no build
            file.

    Returns:
        `struct(file, statement)` for the first reference, or None when
        the scripts never mention `externalNativeBuild` in code.
    """
    if not build_content:
        return None
    collected = _model_collect_files(
        build_file,
        build_content,
        _lex_language_of(build_file),
        _model_package_reader(ctx),
    )
    found = gradle_scan_native(collected.files)
    if found:
        return found[0]
    return None

def _gradle_proguard_residue(code):
    """Non-path remainder of a `consumerProguardFiles` call; "" when plain.

    Past the keyword a plain call holds only string literals, parens,
    commas and the `file(...)` / `files(...)` wrappers. Anything else — a
    bare variable, concatenation, a method result — means the rule files
    cannot be resolved at fetch time.
    """
    rest = code.split("consumerProguardFiles", 1)[1]
    words = []
    for tok in rest.replace("(", " ").replace(")", " ").replace(",", " ").split(" "):
        t = tok.strip()
        if t and t != "file" and t != "files":
            words.append(t)
    return " ".join(words)

def _gradle_visit_proguard_stmt(text, language, file, paths, bad):
    """File one statement's `consumerProguardFiles` paths or its refusal."""
    if not _model_has_word(text, language, "consumerProguardFiles"):
        return
    got = []
    plain = True
    for s in _model_segments(text, language):
        if s.code:
            continue
        (value, ok) = _gradle_string_value(s.text, language)
        if ok:
            got.append(value)
        else:
            plain = False
    if not plain or not got or _gradle_proguard_residue(_model_code_text(text, language)):
        bad.append(struct(file = file, statement = text))
        return
    for p in got:
        paths[p] = True

def gradle_scan_proguard(files):
    """Consumer keep-rule files across collected scripts.

    Multi-line calls and several files per call resolve like the
    single-line form; a variable argument, an interpolated path, or an
    empty call cannot resolve and is reported for refusal.

    Args:
        files: Collected scripts (`struct(path, language, events)`).

    Returns:
        `struct(paths, bad)`: `paths` the sorted distinct rule files,
        `bad` the `(file, statement)` refusals.
    """
    paths = {}
    bad = []
    for f in files:
        for e in f.events:
            if e.kind != "stmt" and e.kind != "open":
                continue
            _gradle_visit_proguard_stmt(e.text, f.language, f.path, paths, bad)
    return struct(paths = sorted(paths.keys()), bad = bad)

def detect_consumer_proguard_specs(ctx, build_file, build_content):
    """Find the plugin's `consumer-rules.pro` files, declared via Gradle.

    Reads the spoke's Gradle build scripts (see `plugin_android_build`)
    through the shared statement model — multi-line calls, several files
    per call and applied scripts included — and returns paths relative to
    the spoke's `android/` sub-package, only for files that actually
    exist on disk. Empty when the plugin doesn't ship consumer rules. AGP
    propagates these into the consuming app's R8 invocation;
    rules_android does the same when they appear in
    `kt_android_library(proguard_specs = [...])` and the binary has
    R8 enabled. A declaration whose files cannot be resolved fails the
    fetch, naming the plugin, the file and the statement.

    Args:
        ctx: the spoke repository context (file existence checks).
        build_file: the spoke-relative Gradle build path, for errors.
        build_content: the text of the spoke's single Gradle build.

    Returns:
        Spoke-`android/`-relative paths of existing consumer rule files.
    """
    paths = []
    if build_content:
        collected = _model_collect_files(
            build_file,
            build_content,
            _lex_language_of(build_file),
            _model_package_reader(ctx),
        )
        scanned = gradle_scan_proguard(collected.files)
        for refusal in scanned.bad:
            fail((
                "flutter.pub spoke for \"{pkg}\": {gradle} declares " +
                "consumerProguardFiles as {stmt}, which is not one or more " +
                "plain string literals (expected consumerProguardFiles " +
                "'consumer-rules.pro'). A declaration routed through a " +
                "variable or an expression cannot be resolved to keep-rule " +
                "files at fetch time; spell the literals out or cover the " +
                "package with a plugin overlay (flutter.plugin_overlays)."
            ).format(
                pkg = ctx.attr.package_name,
                gradle = refusal.file,
                stmt = repr(refusal.statement),
            ))
        for relpath in scanned.paths:
            if ctx.path("android/" + relpath).exists:
                paths.append(relpath)
    return paths
