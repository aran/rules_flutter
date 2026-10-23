"""Statement model shared by every Gradle reader.

On top of the language-aware lexer (`gradle_lex.bzl`): how a statement
splits into code and literal spans (`gradle_segments`, mirroring the
lexer's literal forms one-to-one), and which files make up the build
(`gradle_collect_files`, following `apply from:` scripts with one
resolution, depth and cycle policy). No reader scans raw text or single
lines; every reader folds the same collected scripts. Comments never
reach a reader (the lexer drops them) and string contents arrive as
literal segments, so neither can count as code.
"""

load(
    ":gradle_lex.bzl",
    _lex_language_of = "gradle_language_of",
    _lex_lex = "gradle_lex",
)
load(
    ":gradle_parse.bzl",
    _parse_apply = "parse_gradle_apply",
    _parse_leading_word = "gradle_leading_word",
    _parse_normalize_apply_path = "gradle_normalize_apply_path",
)

_GRADLE_APPLY_MAX_DEPTH = 10

def _gradle_dollar_slashy_end(text, pos, n):
    """End of the `$/.../$` literal opening at `pos` (`$$` escapes)."""
    i = pos + 2
    for _ in range(n + 1):
        if i >= n:
            return n
        if text[i:i + 2] == "/$":
            return i + 2
        if text[i:i + 2] == "$$":
            i += 2
        else:
            i += 1
    return n

def _gradle_triple_end(text, pos, n, q):
    """End of the triple-quoted literal opening at `pos` (escapes honoured)."""
    i = pos + 3
    for _ in range(n + 1):
        if i >= n:
            return n
        if text[i:i + 3] == q + q + q:
            return i + 3
        if text[i:i + 1] == "\\" and i + 1 < n:
            i += 2
        else:
            i += 1
    return n

def _gradle_quoted_end(text, pos, n, q):
    """End of the short quoted literal opening at `pos`, templates honoured."""
    i = pos + 1
    for _ in range(n + 1):
        if i >= n:
            return n
        c = text[i:i + 1]
        if c == "\\" and i + 1 < n:
            i += 2
        elif c == q:
            return i + 1
        elif q == '"' and c == "$" and text[i + 1:i + 2] == "{":
            i = _gradle_template_end(text, i + 2, n)
        else:
            i += 1
    return n

def _gradle_segment_literal_end(text, pos):
    """End of the literal opening at `pos`, escapes and templates honoured."""
    n = len(text)
    if text[pos:pos + 2] == "$/":
        return _gradle_dollar_slashy_end(text, pos, n)
    q = text[pos:pos + 1]
    if text[pos:pos + 3] == q + q + q:
        return _gradle_triple_end(text, pos, n, q)
    return _gradle_quoted_end(text, pos, n, q)

def _gradle_template_end(text, i, n):
    """End of a `${...}` template body started before `i`; nested-aware."""
    depth = 1
    for _ in range(n + 1):
        if i >= n:
            return n
        c = text[i:i + 1]
        if c == "\\" and i + 1 < n:
            i += 2
        elif c == "'" or c == '"':
            end = _gradle_segment_literal_end(text, i)
            i = end if end > i else (i + 1)
        elif c == "{":
            depth += 1
            i += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
            i += 1
        else:
            i += 1
    return n

def _gradle_slashy_end(text, pos):
    """End of the `/.../` literal opening at `pos` (escapes honoured)."""
    n = len(text)
    i = pos + 1
    for _ in range(n + 1):
        if i >= n:
            return n
        c = text[i:i + 1]
        if c == "\\" and i + 1 < n:
            i += 2
        elif c == "/":
            return i + 1
        else:
            i += 1
    return n

def _gradle_slashy_opens_at(text, pos):
    """True when the `/` at `pos` opens a slashy string, not division."""
    i = pos - 1
    for _ in range(pos + 1):
        if i < 0:
            break
        c = text[i:i + 1]
        if c == " " or c == "\t" or c == "\r":
            i -= 1
        else:
            break
    if i < 0:
        return True
    c = text[i:i + 1]
    if c == "=" or c == "(" or c == "[" or c == ":" or c == ",":
        return True
    word = []
    for _ in range(pos + 1):
        if i < 0:
            break
        c = text[i:i + 1]
        if ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or c == "_":
            word.append(c)
            i -= 1
        else:
            break
    return "".join(word) == "nruter"

def gradle_segments(text, language):
    """Split one statement into `struct(text, code)` spans.

    Literal spans (`'...'`, `"..."`, triple-quoted, `/.../`, `$/.../$`,
    each with the lexer's escapes, plus `${...}` templates which stay
    inside their literal) arrive with `code = False`; everything else is
    code. Unterminated literals run to the end of the statement. An
    unknown dialect tag fails: without a known dialect the spans cannot
    be classified, and guessing would silently misread the statement.

    Args:
      text: One statement from `gradle_lex`.
      language: `"groovy"` or `"kotlin"`, from the file extension.

    Returns:
      A list of `struct(text, code)` spans.
    """
    if language != "groovy" and language != "kotlin":
        fail("gradle_segments: unknown Gradle dialect " + repr(language))
    spans = []
    cur = []
    n = len(text)
    i = 0
    for _ in range(n + 1):
        if i >= n:
            break
        c = text[i:i + 1]
        if c == "$" and text[i + 1:i + 2] == "/":
            if cur:
                spans.append(struct(text = "".join(cur), code = True))
                cur = []
            end = _gradle_segment_literal_end(text, i)
            spans.append(struct(text = text[i:end], code = False))
            i = end
        elif c == "'" or c == '"':
            if cur:
                spans.append(struct(text = "".join(cur), code = True))
                cur = []
            end = _gradle_segment_literal_end(text, i)
            spans.append(struct(text = text[i:end], code = False))
            i = end
        elif c == "/" and _gradle_slashy_opens_at(text, i):
            if cur:
                spans.append(struct(text = "".join(cur), code = True))
                cur = []
            end = _gradle_slashy_end(text, i)
            spans.append(struct(text = text[i:end], code = False))
            i = end
        else:
            cur.append(c)
            i += 1
    if cur:
        spans.append(struct(text = "".join(cur), code = True))
    return spans

def gradle_code_text(text, language):
    """The code spans of a statement joined with spaces (literals blanked)."""
    return " ".join([s.text for s in gradle_segments(text, language) if s.code])

def gradle_has_word(text, language, word):
    """True when `word` stands in code (never in a comment or a string).

    Args:
      text: One statement from `gradle_lex`.
      language: `"groovy"` or `"kotlin"`, from the file extension.
      word: The bare word to look for.

    Returns:
      True when `word` appears as a code token.
    """
    for tok in gradle_code_text(text, language).replace("(", " ").replace(")", " ").replace(",", " ").replace(":", " ").replace("=", " ").split(" "):
        if tok.strip() == word:
            return True
    return False

def gradle_block_name(header):
    """The canonical receiver name of a block header.

    `configure<LibraryExtension> { ... }` and `android.apply { ... }`
    configure the Android extension under another spelling, so the
    namespace reader treats them as `android`; every other header keeps
    its leading word.

    Args:
      header: One `open`-event header from `gradle_lex`.

    Returns:
      The canonical receiver name of the block.
    """
    word = _parse_leading_word(header.strip())
    if word == "configure" or word == "android":
        return "android"
    return word

def _gradle_mark_apply(norm, stmt_text, file, read_script, seen, depth, pending, bad):
    """Resolve one normalized `apply from:` path: queue it or refuse it."""
    if not norm or norm in seen:
        bad.append(struct(file = file, statement = stmt_text))
        return
    if depth >= _GRADLE_APPLY_MAX_DEPTH or read_script == None:
        bad.append(struct(file = file, statement = stmt_text))
        return
    sub_seen = dict(seen)
    sub_seen[norm] = True
    sub = read_script(norm)
    if sub == None:
        bad.append(struct(file = file, statement = stmt_text))
    else:
        pending.append((norm, sub, _lex_language_of(norm), sub_seen, depth + 1))

def gradle_collect_files(root_path, root_content, root_language, read_script):
    """Collect the scripts one build is made of, following `apply from:`.

    The root script and every resolvable applied script are lexed with the
    dialect of their own file extension; each entry keeps its own cycle
    chain and nesting depth. The walk is bounded; exhausting the budget
    reports the overflow for refusal rather than hanging.

    Args:
        root_path: Spoke-relative path of the root script, for messages.
        root_content: Its text.
        root_language: `"groovy"` or `"kotlin"`, from its extension.
        read_script: Optional callback taking a package-relative applied
            script path and returning its text, or None when missing.

    Returns:
        `struct(files, bad)`: `files` the collected
        `struct(path, language, events)` scripts in evaluation order,
        `bad` the `(file, statement)` apply refusals.
    """
    files = []
    bad = []
    seen = {}
    norm = _parse_normalize_apply_path(root_path)
    if norm:
        seen[norm] = True
    pending = [(root_path, root_content, root_language, seen, 0)]
    for _ in range(512):
        if not pending:
            break
        (path, content, language, branch, depth) = pending.pop()
        events = _lex_lex(content, language)
        files.append(struct(path = path, language = language, events = events))
        for e in events:
            if e.kind != "stmt":
                continue
            applied = _parse_apply(e.text)
            if applied.kind == "path":
                _gradle_mark_apply(
                    _parse_normalize_apply_path(applied.path),
                    e.text,
                    path,
                    read_script,
                    branch,
                    depth,
                    pending,
                    bad,
                )
            elif applied.kind == "bad":
                bad.append(struct(file = path, statement = e.text))
    if pending:
        bad.append(struct(
            file = root_path,
            statement = "applied Gradle scripts exceed the parse budget",
        ))
    return struct(files = files, bad = bad)

def gradle_package_reader(ctx):
    """A `read_script` callback confined to the spoke's `android/` tree.

    Args:
        ctx: the spoke repository context (path, exists and read).

    Returns:
        A callable taking a package-relative applied-script path and
        returning its text, or None when the script is missing.
    """

    def _read_package_script(path):
        gradle_file = ctx.path("android/" + path)
        if not gradle_file.exists:
            return None
        return ctx.read(gradle_file)

    return _read_package_script
