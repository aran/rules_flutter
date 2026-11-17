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

def code_mask(text):
    """Which characters of `text` are code, outside every string literal.

    A string is `'...'` or `"..."`; a backslash escapes the character after it,
    and the `${...}` of a double-quoted string, strings of its own included, is
    part of the string, so `"\\"${v}\\""` and `"${f("x")}"` are each one.

    Args:
        text: Text of a script, a line or a statement.

    Returns:
        A list of booleans, one per character: True for one of code.
    """
    mask = []
    stack = []
    n = len(text)
    i = 0
    for _ in range(n + 1):
        if i >= n:
            break
        c = text[i]
        top = stack[-1] if stack else ""
        if top == "'" or top == '"':
            if c == "\\" and i + 1 < n:
                mask.extend([False, False])
                i += 2
                continue
            if c == top:
                stack.pop()
            elif top == '"' and c == "$" and text[i + 1:i + 2] == "{":
                stack.append("{")
                mask.extend([False, False])
                i += 2
                continue
            mask.append(False)
        elif top == "{":
            if c == "'" or c == '"' or c == "{":
                stack.append(c)
            elif c == "}":
                stack.pop()
            mask.append(False)
        elif c == "'" or c == '"':
            stack.append(c)
            mask.append(False)
        else:
            mask.append(True)
        i += 1
    return mask

def _strip_line_comment(line):
    """Cuts a `//` comment that is not inside a string literal."""
    mask = code_mask(line)
    for i in range(len(line) - 1):
        if mask[i] and mask[i + 1] and line[i] == "/" and line[i + 1] == "/":
            return line[:i]
    return line

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

def _split_statements(line, number, out, carry):
    """Appends the tokens of one physical line of a Gradle script to `out`.

    Each token is a struct with `kind` (`"statement"`, `"open"` for a block
    header, whose `text` is what precedes its `{`, or `"close"`), `text` and
    `line`, the 1-based line `number`. A line holds several when a block is
    opened and closed on it (`dependencies { implementation 'a:b:1' }`) or `;`
    separates them. Braces, brackets and parentheses inside a string or inside
    a call's arguments never split, and the closure of a dependency declaration
    stays with it (see `_opens_a_closure`), so the declaration is one
    statement, whose text holds the lines of the closure, `\\n` between them,
    when it spans several.

    Args:
        line: The line, its comment removed.
        number: Its 1-based number.
        out: The tokens so far.
        carry: What the line before left open: None, or a dependency
            declaration whose closure it did not close, as this returns it.

    Returns:
        The declaration this line leaves open, `struct(text, line, depth)`
        with its `{` depth, or None.
    """

    def token(kind, text, at):
        out.append(struct(kind = kind, text = text.strip(), line = at))

    mask = code_mask(line)
    cur = carry.text + "\n" if carry else ""
    start = carry.line if carry else number
    closure = carry.depth if carry else 0
    depth = 0
    for i in range(len(line)):
        c = line[i]
        if not mask[i]:
            cur += c
        elif closure > 0:
            cur += c
            if c == "{":
                closure += 1
            elif c == "}":
                closure -= 1
        elif c == "(" or c == "[":
            depth += 1
            cur += c
        elif c == ")" or c == "]":
            depth = max(depth - 1, 0)
            cur += c
        elif depth == 0 and c == "{" and _opens_a_closure(cur):
            closure = 1
            cur += c
        elif depth == 0 and c == "{":
            token("open", cur, start)
            cur = ""
            start = number
        elif depth == 0 and c in ";}":
            if cur.strip():
                token("statement", cur, start)
            if c == "}":
                token("close", "", number)
            cur = ""
            start = number
        else:
            cur += c
    if closure > 0:
        return struct(text = cur, line = start, depth = closure)
    if cur.strip():
        token("statement", cur, start)
    return None

def gradle_tokens(content):
    """The tokens of a Gradle build script, comments removed.

    Args:
        content: The text of `build.gradle` or `build.gradle.kts`.

    Returns:
        Structs of `kind` (`"statement"`, `"open"` for a block header, whose
        `text` is what precedes its `{`, or `"close"`), `text` and `line`, the
        1-based line number where it starts (see `_split_statements`).
    """
    out = []
    carry = None
    for number, raw in enumerate(content.split("\n")):
        carry = _split_statements(_strip_line_comment(raw), number + 1, out, carry)
    if carry and carry.text.strip():
        out.append(struct(kind = "statement", text = carry.text.strip(), line = carry.line))
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
