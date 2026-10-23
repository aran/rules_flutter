"""One escaping helper for every string emitted into generated BUILD files.

The pub spoke generators walk file names out of package archives and read
asset, font and shader paths out of pubspec.yaml files. Both are
attacker-controlled for hosted packages and user-controlled for path
packages. Pasting them into BUILD source with a `"..." % value` splice lets
a quote or a backslash in a name close the literal and continue the file as
Starlark: the generated BUILD then fails to parse, names a different file,
or adds rules of the package's choosing that run during the build.

Every generator routes each string it emits through
`starlark_string_literal`, which is `repr()`: the emitted literal always
parses back to the exact input, and ordinary names render byte-identical to
the old quoting. Names no Bazel target can name fail the fetch instead,
naming the package, the declaring entry and the file.
"""

def starlark_string_literal(value):
    """Render `value` as a Starlark string literal that parses back to it.

    Args:
        value: The string to emit (or a list of strings, for `includes`).

    Returns:
        A double-quoted literal with every quote, backslash and control
        character escaped, so the text parses back to the exact input.
    """
    return repr(value)

# Escape letters the Starlark lexer decodes to one fixed character.
_SIMPLE_STARLARK_ESCAPES = {
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "\\": "\\",
    '"': '"',
    "'": "'",
}

# Hex digit characters, lower- then upper-case, for `\xHH` value lookup.
_HEX_DIGIT_CHARS = "0123456789abcdefABCDEF"

# Octal digit characters, for `\ooo` value lookup.
_OCTAL_DIGIT_CHARS = "01234567"

# Printable ASCII (code points 32-126) in code-point order, for octal and
# `\x` escape value lookup. Tab, newline and carriage return decode without
# it; anything else outside this range fails the fetch at the call site.
_PRINTABLE_ASCII_CHARS = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

def _escape_code_point_char(code):
    """The character an octal or `\\x` escape value names, or "" when odd.

    Only printable ASCII passes through, plus tab, newline and carriage
    return; anything else (NUL, DEL, values past a byte) has no business in
    an overlay heredoc body and fails the fetch at the call site instead of
    guessing.

    Args:
        code: The escape's numeric value.

    Returns:
        The one-character string, or "" when `code` names nothing emittable.
    """
    if code == 9:
        return "\t"
    if code == 10:
        return "\n"
    if code == 13:
        return "\r"
    if code < 32 or code > 126:
        return ""
    return _PRINTABLE_ASCII_CHARS[code - 32]

def _decode_hex_escape(source, i, n):
    """Decode the two hex digits of a `\\xHH` escape starting at `source[i]`.

    Args:
        source: The still-encoded literal body.
        i: Index of the first hex digit (the character after the `x`).
        n: Length of `source`.

    Returns:
        A struct with the decoded `char`, the `next` index past the escape,
        and an `error` reason ("" on success).
    """
    if i + 2 > n:
        return struct(char = "", next = i, error = "a `\\x` escape needs two hex digits")
    hi = _HEX_DIGIT_CHARS.find(source[i])
    lo = _HEX_DIGIT_CHARS.find(source[i + 1])
    if hi < 0 or lo < 0:
        return struct(char = "", next = i, error = "a `\\x` escape needs two hex digits")
    if hi >= 16:
        hi -= 6
    if lo >= 16:
        lo -= 6
    char = _escape_code_point_char(hi * 16 + lo)
    if char == "":
        return struct(char = "", next = i, error = "a `\\x` escape names a character outside printable ASCII")
    return struct(char = char, next = i + 2, error = "")

def _decode_octal_escape(source, i, n):
    """Decode the one-to-three octal digits of an escape at `source[i]`.

    Args:
        source: The still-encoded literal body.
        i: Index of the first octal digit (the character after the backslash).
        n: Length of `source`.

    Returns:
        A struct with the decoded `char`, the `next` index past the escape,
        and an `error` reason ("" on success).
    """
    value = 0
    next = i
    for _ in range(3):
        if next >= n:
            break
        digit = _OCTAL_DIGIT_CHARS.find(source[next])
        if digit < 0:
            break
        value = value * 8 + digit
        next += 1
    char = _escape_code_point_char(value)
    if char == "":
        return struct(char = "", next = next, error = "an octal escape names a character outside printable ASCII")
    return struct(char = char, next = next, error = "")

def _decode_one_escape(source, i, n):
    """Decode the escape whose letter sits at `source[i]`, past its backslash.

    Args:
        source: The still-encoded literal body.
        i: Index of the escape letter (the character after the backslash).
        n: Length of `source`.

    Returns:
        A struct with the decoded `char`, the `next` index past the escape,
        and an `error` reason ("" on success).
    """
    if i >= n:
        return struct(char = "", next = i, error = "a backslash with nothing after it")
    letter = source[i]
    if letter in _SIMPLE_STARLARK_ESCAPES:
        return struct(char = _SIMPLE_STARLARK_ESCAPES[letter], next = i + 1, error = "")
    if letter == "x":
        return _decode_hex_escape(source, i + 1, n)
    if letter in _OCTAL_DIGIT_CHARS:
        return _decode_octal_escape(source, i, n)
    return struct(char = "", next = i, error = "an unknown escape \"\\" + letter + "\"")

def decode_starlark_escapes(source):
    """Decode Starlark string-literal escapes in `source` to the actual text.

    `source` is literal body text cut out of a quoted Starlark string — an
    overlay heredoc body, or a parsed `name`/`outs` line — where backslash
    sequences are still encoded. Every escape the Starlark lexer accepts
    (`\\\\`, `\\"`, `\\'`, `\\n`, `\\t`, `\\r`, one-to-three octal digits,
    `\\x` plus two hex digits) decodes to the character it names; anything
    else fails closed through `error` instead of guessing.

    Args:
        source: The still-encoded literal body.

    Returns:
        A struct with the decoded `text` and an `error` reason ("" on
        success). The caller fails the fetch with the package and the
        template in the message.
    """
    chars = []
    i = 0
    n = len(source)
    error = ""
    for _ in range(n):
        if i >= n or error != "":
            break
        if source[i] != "\\":
            chars.append(source[i])
            i += 1
            continue
        decoded = _decode_one_escape(source, i + 1, n)
        error = decoded.error
        if error == "":
            chars.append(decoded.char)
            i = decoded.next
    return struct(text = "".join(chars), error = error)

def spoke_file_name_error(package_name, entry, path):
    """The fetch failure for a declared or walked name no target can name.

    Names the package, the declaring pubspec entry and the file, so the fix
    (renaming the file) is in the message. Returns the message instead of
    failing so unit tests can assert it; the caller `fail()`s with it.

    Args:
        package_name: The pub package the entry comes from.
        entry: The pubspec declaration covering the file (the path itself
            for a direct entry, the trailing-slash directory for a file
            walked out of one, the font block for a font asset).
        path: The file path that cannot be emitted.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub spoke for \"{pkg}\": entry \"{entry}\" names file " +
        "{path} which cannot be a Bazel target name (empty, or holding " +
        "`:`, a backslash, a non-printable character, a leading or " +
        "trailing `/`, `//`, or a `.` or `..` path segment). Rename the " +
        "file rather than emitting a spoke that cannot name it."
    ).format(
        pkg = package_name,
        entry = entry,
        path = repr(path),
    )

def spoke_file_name_problem(path):
    """Why `path` cannot be a Bazel target name, or "" when Bazel takes it.

    Mirrors Bazel's own target-name validator, probed empirically (Bazel
    9.3.0 rejects `\\`, `:`, C0 controls, DEL, a leading `/`, `//`, `.`
    and `..` segments and a trailing `/`, while `"`, `%`, `*`, spaces,
    `$`, non-ASCII and a lone `.` load fine). A backslash is refused even
    though the escaping helper round-trips it: the emitted `:dir/back\\x`
    label is what Bazel rejects at load, so the fetch must fail first.

    Args:
        path: The file path to judge.

    Returns:
        A short reason, or "" when the name is emittable.
    """
    if not path:
        return "it is empty"
    if ":" in path:
        return "it holds a `:`"
    if "\\" in path:
        return "it holds a backslash"
    if path.startswith("/"):
        return "it starts with `/`"
    if "//" in path:
        return "it holds `//`"
    if path.endswith("/"):
        return "it ends with `/`"
    for segment in path.split("/"):
        if segment == "..":
            return "it holds a `..` segment"
        if segment == "." and path != ".":
            return "it holds a `.` segment"

    # No ord() in Starlark: a one-char string orders by code point, so
    # `c < " "` catches every C0 control, and "\177" (octal escape, which
    # the lexer accepts) is DEL.
    for c in path.elems():
        if c < " " or c == "\177":
            return "it holds a non-printable character"
    return ""

def check_spoke_file_name(package_name, entry, path):
    """Fail the spoke fetch when `path` cannot be a Bazel target name.

    Quotes pass through: Bazel accepts `"` in target names and the
    escaping helper round-trips it. Everything Bazel's own validator
    rejects fails here first, so no fetch ever emits an unloadable spoke.

    Args:
        package_name: The pub package the entry comes from.
        entry: The pubspec declaration covering the file.
        path: The file path to check.

    Returns:
        None when the name is emittable, so unit tests can assert the
        pass-through; otherwise fails with `spoke_file_name_error`.
    """
    if spoke_file_name_problem(path):
        fail(spoke_file_name_error(package_name, entry, path))
    return None
