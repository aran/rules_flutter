"""Reading Gradle build scripts without running Gradle.

A pub plugin's `android/build.gradle(.kts)` is a program in Groovy or Kotlin.
rules_flutter reads what it needs out of it statically: `gradle_tokens` splits
a script into statements and block headers, and `applied_scripts` names the
scripts it applies (`apply from:`).
"""

# Gradle configurations by what they mean for a plugin's compile classpath.
_KIND_BY_CONFIGURATION = {
    "implementation": "deps",
    "api": "deps",
    "compile": "deps",
    "compileOnly": "compile_only",
    "provided": "compile_only",
    "runtimeOnly": "runtime",
}

# Not part of the plugin's own classpath in an app build.
_IGNORED_PREFIXES = ("test", "androidTest", "testFixtures", "lint")
_IGNORED_CONFIGURATIONS = ("classpath",)

# Configurations the parser cannot honour.
_UNSUPPORTED_CONFIGURATIONS = (
    "kapt",
    "ksp",
    "annotationProcessor",
    "coreLibraryDesugaring",
)
_VARIANTS = ("debug", "release", "profile")
_VARIANT_SUFFIXES = ("Implementation", "Api", "CompileOnly", "RuntimeOnly")

_IDENT_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

def leading_identifier(line):
    """The identifier `line` starts with.

    Args:
        line: Text.

    Returns:
        The identifier, or the empty string.
    """
    end = 0
    for c in line.elems():
        if c not in _IDENT_CHARS:
            break
        end += 1
    return line[:end]

def _strip_line_comment(line):
    """Cuts a `//` comment that is not inside a string literal."""
    quote = ""
    for i in range(len(line)):
        c = line[i]
        if quote:
            if c == quote:
                quote = ""
        elif c == "'" or c == '"':
            quote = c
        elif c == "/" and line[i + 1:i + 2] == "/":
            return line[:i]
    return line

def _matching_brace(line, start):
    """Index of the `}` that closes the `{` at `start`, or -1; quotes are skipped."""
    depth = 0
    quote = ""
    for i in range(start, len(line)):
        c = line[i]
        if quote:
            if c == quote:
                quote = ""
        elif c == "'" or c == '"':
            quote = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1

def _opens_a_closure(header):
    """Whether a `{` after `header` configures a dependency, not opens a block.

    `implementation("a:b:1") { exclude(group = "x") }` is one statement: the
    braces are the dependency's own closure. `dependencies {`, `if (flag) {`
    and `kapt {` open blocks, whose contents are statements of their own.
    """
    header = header.strip()
    identifier = leading_identifier(header)
    if not identifier or (identifier != "add" and not dependency_kind(identifier)):
        return False
    rest = header[len(identifier):]
    return bool(rest.strip()) and rest[0] in " \t('\"" and not rest.strip().startswith("=")

def _split_statements(line, number, out):
    """Appends the tokens of one physical line of a Gradle script to `out`.

    Each token is a struct with `kind` (`"statement"`, `"open"` for a block
    header, whose `text` is what precedes its `{`, or `"close"`), `text` and
    `line`, the 1-based line `number`. A line holds several when a block is
    opened and closed on it (`dependencies { implementation 'a:b:1' }`) or `;`
    separates them. Braces, brackets and parentheses inside a string or inside
    a call's arguments never split, and the closure of a dependency declaration
    stays with it (see `_opens_a_closure`), so the declaration is reported
    whole if it is not one the reader supports.
    """

    def token(kind, text):
        out.append(struct(kind = kind, text = text.strip(), line = number))

    cur = ""
    quote = ""
    depth = 0
    i = 0
    n = len(line)
    for _ in range(n + 1):
        if i >= n:
            break
        c = line[i]
        if quote:
            cur += c
            if c == quote:
                quote = ""
        elif c == "'" or c == '"':
            quote = c
            cur += c
        elif c == "(" or c == "[":
            depth += 1
            cur += c
        elif c == ")" or c == "]":
            depth = max(depth - 1, 0)
            cur += c
        elif depth == 0 and c == "{" and _opens_a_closure(cur):
            close = _matching_brace(line, i)
            end = n if close < 0 else close + 1
            cur += line[i:end]
            i = end
            continue
        elif depth == 0 and c == "{":
            token("open", cur)
            cur = ""
        elif depth == 0 and c in ";}":
            if cur.strip():
                token("statement", cur)
            if c == "}":
                token("close", "")
            cur = ""
        else:
            cur += c
        i += 1
    if cur.strip():
        token("statement", cur)

def gradle_tokens(content):
    """The tokens of a Gradle build script, comments removed.

    Args:
        content: The text of `build.gradle` or `build.gradle.kts`.

    Returns:
        Structs of `kind` (`"statement"`, `"open"` for a block header, whose
        `text` is what precedes its `{`, or `"close"`), `text` and `line`, the
        1-based line number (see `_split_statements`).
    """
    out = []
    for number, raw in enumerate(content.split("\n")):
        _split_statements(_strip_line_comment(raw), number + 1, out)
    return out

def gradle_statements(content):
    """The statements of a Gradle build script, comments removed.

    Args:
        content: The text of `build.gradle` or `build.gradle.kts`.

    Returns:
        A list of stripped strings, one per statement or block header.
    """
    return [t.text for t in gradle_tokens(content) if t.kind != "close" and t.text]

def dependency_kind(identifier):
    """What a Gradle configuration means for a plugin's classpath.

    Args:
        identifier: A configuration name, such as `implementation`.

    Returns:
        A dependency kind (`"deps"`, `"compile_only"`, `"runtime"`),
        `"ignore"`, `"error"` for one the reader cannot honour, or `""` for
        a name that is no configuration.
    """
    if identifier in _KIND_BY_CONFIGURATION:
        return _KIND_BY_CONFIGURATION[identifier]
    if identifier in _IGNORED_CONFIGURATIONS:
        return "ignore"
    for p in _IGNORED_PREFIXES:
        if identifier.startswith(p):
            return "ignore"
    if identifier in _UNSUPPORTED_CONFIGURATIONS:
        return "error"
    for v in _VARIANTS:
        if identifier.startswith(v):
            for s in _VARIANT_SUFFIXES:
                if identifier == v + s:
                    return "error"
    return ""

def _unquote(text):
    if len(text) >= 2 and text[0] in "'\"" and text[-1] == text[0]:
        return text[1:-1]
    return None

def _call_argument(text, prefix):
    """The argument of `prefix(arg)` when `text` is exactly that call, else None."""
    if not text.startswith(prefix + "(") or not text.endswith(")"):
        return None
    return text[len(prefix) + 1:-1].strip()

def applied_script(text):
    """The path `apply from: "x"` / `apply(from = "x")` / `apply from: file("x")` names.

    A path that is not one string literal (an interpolation, say) is returned
    as written, which no file of the package has.

    Args:
        text: A statement.

    Returns:
        The path, or None when the statement applies no script.
    """
    if leading_identifier(text) != "apply":
        return None
    rest = text[len("apply"):].strip()
    if rest.startswith("(") and rest.endswith(")"):
        rest = rest[1:-1].strip()
    if not rest.startswith("from"):
        return None
    rest = rest[len("from"):].strip()
    if not rest or rest[0] not in ":=":
        return None
    rest = rest[1:].strip()
    arg = _call_argument(rest, "file")
    arg = arg if arg != None else rest
    unquoted = _unquote(arg)
    return unquoted if unquoted != None else arg

def applied_scripts(content):
    """The scripts a Gradle build script applies.

    Args:
        content: The text of `build.gradle` or `build.gradle.kts`.

    Returns:
        `struct(path, line, line_number)` of each, in order.
    """
    return [
        struct(path = path, line = t.text, line_number = t.line)
        for t in gradle_tokens(content)
        if t.kind == "statement"
        for path in [applied_script(t.text)]
        if path
    ]

def gradle_applied_scripts(content):
    """The paths of the scripts a Gradle build script applies.

    Args:
        content: The text of `build.gradle` or `build.gradle.kts`.

    Returns:
        The paths, relative to the script's directory, in order.
    """
    return [a.path for a in applied_scripts(content)]
