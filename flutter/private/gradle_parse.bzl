"""Statement-level Gradle parsers shared by every plugin-build reader.

These helpers operate on one lexed statement's raw text, exactly as the
historical single-file model did: whitespace skipping, quote-aware
literals, `add()` heads, `apply from:` in every DSL spelling, and
package-relative path normalization with refusal of URLs, absolute
paths, escapes and interpolation. Ported verbatim so every refusal the
test suite pins keeps its exact statement text.
"""

def gradle_leading_word(text):
    """Return the leading `[A-Za-z0-9_]` word of `text` ("" when none).

    Args:
        text: The text to read.

    Returns:
        The leading word, or "" when `text` starts with no word char.
    """
    out = []
    for i in range(len(text)):
        c = text[i:i + 1]
        if ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or ("0" <= c and c <= "9") or c == "_":
            out.append(c)
        else:
            break
    return "".join(out)

def gradle_stmt_token(stmt):
    """Return the leading identifier of a statement, dots kept.

    `project.dependencies.add(...)` yields one dotted token so the `.`
    rule can tell a method path from a bare configuration name.

    Args:
        stmt: The statement text.

    Returns:
        The leading dotted identifier, or "" when there is none.
    """
    out = []
    for i in range(len(stmt)):
        c = stmt[i:i + 1]
        if ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or ("0" <= c and c <= "9") or c == "_" or c == "." or c == "$":
            out.append(c)
        else:
            break
    return "".join(out)

def gradle_skip_ws(text, pos):
    """Return the first position at or after `pos` that is not blank.

    Args:
        text: The text to scan.
        pos: The position to start from.

    Returns:
        The first non-blank position at or after `pos`.
    """
    n = len(text)
    for _ in range(n + 1):
        if pos >= n:
            break
        if text[pos:pos + 1] in " \t\r":
            pos += 1
        else:
            break
    return pos

def gradle_quoted_at(text, pos):
    """Read the quoted literal at `pos`; return `(inner, end)` or `(None, pos)`.

    Only single- and double-quoted literals count; anything else (a
    variable, a catalog ref, string concatenation) is not a literal.

    Args:
        text: The text to read.
        pos: The position of the opening quote.

    Returns:
        `(inner, end)` with the literal body and the end position, or
        `(None, pos)` when no quoted literal opens at `pos`.
    """
    q = text[pos:pos + 1]
    if q != "'" and q != '"':
        return (None, pos)
    out = []
    n = len(text)
    i = pos + 1
    for _ in range(n + 1):
        if i >= n:
            return (None, pos)
        c = text[i:i + 1]
        if c == "\\" and i + 1 < n:
            out.append(c)
            out.append(text[i + 1:i + 2])
            i += 2
        elif c == q:
            return ("".join(out), i + 1)
        else:
            out.append(c)
            i += 1
    return (None, pos)

def gradle_match_paren(text, open_pos):
    """Return the index of the `)` matching the `(` at `open_pos`, or -1.

    Args:
        text: The text to scan.
        open_pos: The position of the opening paren.

    Returns:
        The matching close-paren index, or -1 when unbalanced.
    """
    depth = 0
    n = len(text)
    i = open_pos
    for _ in range(n + 1):
        if i >= n:
            return -1
        c = text[i:i + 1]
        if c == "(":
            depth += 1
            i += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
            i += 1
        elif c == "'" or c == '"':
            (_, end) = gradle_quoted_at(text, i)
            if end <= i:
                return -1
            i = end
        else:
            i += 1
    return -1

def gradle_bad_add():
    """The shared "not a modellable `add()` call" parse result."""
    return struct(kind = "bad", config = "", notation = "", project = False)

def gradle_parse_add_tail(stmt, pos, paren, config):
    """Parse the `(notation)` tail of an `add(config, ...)` statement.

    Args:
        stmt: The statement text.
        pos: The position where the notation starts.
        paren: Whether the `add(` call opened a paren to close.
        config: The already-parsed configuration name.

    Returns:
        A struct: `kind` `"dep"` or `"project"`, or `"bad"`.
    """
    pos = gradle_skip_ws(stmt, pos)
    if stmt[pos:pos + 7] == "project" and stmt[pos + 7:pos + 8] == "(":
        end = gradle_match_paren(stmt, pos + 7)
        if end < 0:
            return gradle_bad_add()
        pos = gradle_skip_ws(stmt, end + 1)
        if paren:
            if stmt[pos:pos + 1] != ")":
                return gradle_bad_add()
            pos = gradle_skip_ws(stmt, pos + 1)
        if pos != len(stmt):
            return gradle_bad_add()
        return struct(kind = "project", config = config, notation = "", project = True)
    (notation, end) = gradle_quoted_at(stmt, pos)
    if notation == None:
        return gradle_bad_add()
    pos = gradle_skip_ws(stmt, end)
    if paren:
        if stmt[pos:pos + 1] != ")":
            return gradle_bad_add()
        pos = gradle_skip_ws(stmt, pos + 1)
    if pos != len(stmt):
        return gradle_bad_add()
    return struct(kind = "dep", config = config, notation = notation, project = False)

def parse_gradle_add(stmt):
    """Parse a bare `add(config, notation)` dependency statement.

    Covers `add('implementation', 'g:a:1')` and the double-quoted
    spelling, with or without parentheses. A `project(...)` notation
    parses as a project reference.

    Args:
        stmt: The statement text; its leading word must be `add`.

    Returns:
        A struct: `kind` is `"dep"` (with `config` and `notation`),
        `"project"` (with `config`), or `"bad"` for anything else.
    """
    pos = gradle_skip_ws(stmt, 3)
    paren = False
    if stmt[pos:pos + 1] == "(":
        paren = True
        pos = gradle_skip_ws(stmt, pos + 1)
    (config, end) = gradle_quoted_at(stmt, pos)
    if config == None:
        return gradle_bad_add()
    pos = gradle_skip_ws(stmt, end)
    if stmt[pos:pos + 1] != ",":
        return gradle_bad_add()
    return gradle_parse_add_tail(stmt, pos + 1, paren, config)

def gradle_skip_arg_value(stmt, j):
    """Skip one Kotlin arg value at `j` (a literal or a word); return new pos.

    Args:
        stmt: The statement text.
        j: The position of the value.

    Returns:
        The position where scanning continues.
    """
    c2 = stmt[j:j + 1]
    if c2 == "'" or c2 == '"':
        (_, end) = gradle_quoted_at(stmt, j)
        return end if end > j else (j + 1)
    w2 = gradle_leading_word(stmt[j:])
    return j + len(w2) if w2 else (j + 1)

def gradle_apply_from_arg(stmt, j):
    """Read the `from` value at word position `j`; return a kind/path struct.

    Groovy map-entry (`from: 'x.gradle'`) and Kotlin assignment
    (`from = "x.gradle.kts"`) spellings both count; a missing separator
    or a non-literal value is `"bad"`.

    Args:
        stmt: The stripped statement text.
        j: Index of the `from` word.

    Returns:
        `struct(kind, path)`: `"path"` with the literal, or `"bad"`.
    """
    j2 = gradle_skip_ws(stmt, j + 4)
    if stmt[j2:j2 + 1] == "=":
        j3 = gradle_skip_ws(stmt, j2 + 1)
    elif stmt[j2:j2 + 1] == ":":
        j3 = gradle_skip_ws(stmt, j2 + 1)
    else:
        return struct(kind = "bad", path = "")
    (path, _) = gradle_quoted_at(stmt, j3)
    if path == None:
        return struct(kind = "bad", path = "")
    return struct(kind = "path", path = path)

def gradle_skip_call_arg(stmt, j, w):
    """Skip one named `name = value` call argument; return the next index.

    A bare word without `=` (a positional plugin id, a flag) stays put
    past its own end so the caller keeps scanning inside the call.

    Args:
        stmt: The stripped statement text.
        j: Index of the argument's leading word.
        w: The leading word.

    Returns:
        The index where scanning continues.
    """
    j = gradle_skip_ws(stmt, j + len(w))
    if stmt[j:j + 1] == "=":
        j = gradle_skip_arg_value(stmt, gradle_skip_ws(stmt, j + 1))
    return j

def parse_gradle_apply_kwargs(stmt, pos):
    """Parse parenthesised `apply(...)` args; return the `from` path struct.

    Args:
        stmt: The stripped statement text.
        pos: The position after the opening paren.

    Returns:
        `struct(kind, path)`: `"path"`, `"bad"`, or `"none"`.
    """
    n = len(stmt)
    j = pos
    for _ in range(n + 1):
        j = gradle_skip_ws(stmt, j)
        if j >= n:
            break
        c = stmt[j:j + 1]
        if c == ")":
            break
        if c == ",":
            j += 1
        elif c == "'" or c == '"':
            j = gradle_skip_arg_value(stmt, j)
        else:
            w = gradle_leading_word(stmt[j:])
            if not w:
                j += 1
            elif w == "from":
                return gradle_apply_from_arg(stmt, j)
            else:
                j = gradle_skip_call_arg(stmt, j, w)
    return struct(kind = "none", path = "")

def parse_gradle_apply(stmt):
    """Parse an `apply from:` statement; return a kind/path struct.

    `kind` is `"path"` (with the literal script path) for the Groovy
    `apply from: 'x.gradle'`, the parenthesised Groovy
    `apply(from: 'x.gradle')`, and Kotlin
    `apply(from = "x.gradle.kts")` spellings, `"bad"` for an `apply`
    whose `from` is missing or not a plain quoted literal, and `"none"`
    for anything else (`apply plugin:` and non-`apply` statements).

    Args:
        stmt: The stripped statement text.

    Returns:
        `struct(kind, path)`.
    """
    if gradle_leading_word(stmt) != "apply":
        return struct(kind = "none", path = "")
    pos = gradle_skip_ws(stmt, 5)
    if stmt[pos:pos + 1] == "(":
        return parse_gradle_apply_kwargs(stmt, pos + 1)
    if gradle_leading_word(stmt[pos:]) != "from":
        return struct(kind = "none", path = "")
    j = gradle_skip_ws(stmt, pos + 4)
    if stmt[j:j + 1] != ":":
        return struct(kind = "bad", path = "")
    j = gradle_skip_ws(stmt, j + 1)
    (path, end) = gradle_quoted_at(stmt, j)
    if path == None:
        return struct(kind = "bad", path = "")
    j = gradle_skip_ws(stmt, end)
    if j < len(stmt) and stmt[j:j + 1] != ",":
        return struct(kind = "bad", path = "")
    return struct(kind = "path", path = path)

def gradle_normalize_apply_path(path):
    """Resolve an applied-script path inside the package; "" when refused.

    Dots collapse, `..` pops, and popping past the package root, a URL
    scheme, an absolute path, an empty path or `$` interpolation refuses
    the path (""), so the caller reports the statement unreadable.

    Args:
        path: The literal path from the `apply from:` statement.

    Returns:
        The package-relative path, or "" when it escapes or is not plain.
    """
    if not path or "$" in path:
        return ""
    for i in range(len(path)):
        c = path[i:i + 1]
        if c == "/":
            break
        if c == ":":
            return ""
    if path.startswith("/"):
        return ""
    out = []
    for seg in path.split("/"):
        if seg == "" or seg == ".":
            continue
        if seg == "..":
            if not out:
                return ""
            out.pop()
        else:
            out.append(seg)
    if not out:
        return ""
    return "/".join(out)

def gradle_code_without_strings(text):
    """Return `text` with every quoted literal dropped.

    Lets the `dependencies`-mention check see references
    (`project.dependencies.add`) while a prose string that merely names
    dependencies stays invisible.

    Args:
        text: The statement text.

    Returns:
        `text` with every quoted literal removed.
    """
    out = []
    n = len(text)
    i = 0
    for _ in range(n + 1):
        if i >= n:
            break
        c = text[i:i + 1]
        if c == "'" or c == '"':
            (_, end) = gradle_quoted_at(text, i)
            if end <= i:
                out.append(c)
                i += 1
            else:
                i = end
        else:
            out.append(c)
            i += 1
    return "".join(out)
