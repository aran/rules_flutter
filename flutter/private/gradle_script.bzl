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

def _script_path(script, path):
    """The path in the package of the script `script` applies as `path`, or None outside it."""
    if path.startswith("/") or "$" in path:
        return None
    out = script.split("/")[:-1]
    for segment in path.split("/"):
        if segment in ("", "."):
            continue
        if segment == "..":
            if not out:
                return None
            out.pop()
        else:
            out.append(segment)
    return "/".join(out)

def gradle_tokens_with_applied(content, applied, script):
    """The tokens of a script, those of each script it applies that `applied` has in its place.

    A script an applied one applies is not followed.

    Args:
        content: The text of the script.
        applied: The text of each script it applies that the package has,
            by the path `applied_script` gives.
        script: The path of the script in the package.

    Returns:
        `gradle_tokens`' structs, each with `script`, the path of the script
        it is in, and `applied`, whether it is an `apply from:` whose
        script's tokens follow it.
    """
    out = []
    for t in gradle_tokens(content):
        path = applied_script(t.text) if t.kind == "statement" else None
        target = _script_path(script, path) if path else None
        if target != None and path in applied:
            out.append(struct(kind = t.kind, text = t.text, line = t.line, script = script, applied = True))
            for a in gradle_tokens(applied[path]):
                out.append(struct(kind = a.kind, text = a.text, line = a.line, script = target, applied = False))
            continue
        out.append(struct(kind = t.kind, text = t.text, line = t.line, script = script, applied = False))
    return out

def parse_gradle_properties(content):
    """The properties a `gradle.properties` file sets.

    Each line is `key=value`, `key:value` or `key value`; a line starting
    `#` or `!` is a comment. Line continuations and escapes are not read.

    Args:
        content: The text of the file.

    Returns:
        A dict of key to value.
    """
    properties = {}
    for raw in content.split("\n"):
        line = raw.strip()
        if not line or line[0] in "#!":
            continue
        cut = len(line)
        for sep in "=: \t".elems():
            i = line.find(sep)
            if i >= 0 and i < cut:
                cut = i
        key = line[:cut].strip()
        value = line[cut + 1:].strip() if cut < len(line) else ""
        if value and value[0] in "=:":
            value = value[1:].strip()
        if key:
            properties[key] = value
    return properties

# The values of a script, evaluated statically.
#
# A Gradle script computes the coordinates it declares: a version is a
# literal, a variable, a project property (one of the package's
# `gradle.properties`, an `ext` property), another plugin's property
# (`findProject(":firebase_core").properties["FirebaseSDKVersion"]`), or what a
# function of the script returns for them. `gradle_scope` collects what a
# script defines and `gradle_string` evaluates a string expression in it.
#
# A string is a list of parts: a string, a dict `{"package", "property"}` for
# another plugin's property, which only the hub that reads every plugin knows,
# or None for a part the reader cannot evaluate. Other values are structs of
# `kind`: "null", "bool" (`value`), "project" (`name`: "" for the script's
# own, ":root" for the root project, else a pub package's name),
# "properties" and "ext" (`project`, the name as for "project").
#
# A Bazel build has no root Gradle project. The root project of a
# `flutter create` app sets no `ext` properties, so `rootProject.ext` is empty
# here, and what a plugin reads from it when it is set takes its default.
#
# Starlark has no recursion, so each kind of expression has its own function,
# and each calls only those below it: `gradle_string` (a string literal with
# its `${...}`), `_expression` (that, or a call of a function of the script),
# `_call_function`, `_condition`, `_chain` (`a.b[c].d(e)`) and `_atom` (a
# literal or a name). What needs more depth is not evaluated.

_NULL = struct(kind = "null")

def _str(parts):
    return struct(kind = "str", parts = parts)

def _project(name):
    return struct(kind = "project", name = name)

def _bool(value):
    return struct(kind = "bool", value = value)

def _defined_function(header):
    """`(name, params)` when a block header defines a function, else None."""
    header = header.strip()
    text = None
    for prefix in ("def ", "String ", "Object ", "private def ", "static def "):
        if header.startswith(prefix):
            text = header[len(prefix):].strip()
            break
    if text == None:
        return None
    name = leading_identifier(text)
    rest = text[len(name):].strip()
    if not name or not rest.startswith("(") or not rest.endswith(")"):
        return None
    params = []
    for p in rest[1:-1].split(","):
        p = p.strip()
        if not p:
            continue
        param = p.split(" ")[-1].strip()
        if leading_identifier(param) != param:
            return None
        params.append(param)
    return (name, params)

def _definition(text, blocks):
    """`(name, expression)` when a statement defines a variable or an `ext` property, else None."""
    if blocks and blocks[-1] == "ext":
        name = leading_identifier(text)
        rest = text[len(name):].strip()
        if name and rest.startswith("=") and not rest.startswith("=="):
            return (name, rest[1:].strip())
        return None
    rest = ""
    name = ""
    for prefix in ("def ", "val ", "var ", "String ", "final String ", "final def ", "final "):
        if text.startswith(prefix):
            rest = text[len(prefix):].strip()
            name = leading_identifier(rest)
            rest = rest[len(name):].strip()
            if rest.startswith(":"):
                rest = rest[1:].strip()
                rest = rest[len(leading_identifier(rest)):].strip()
            break
    if not name:
        for prefix in ("ext.", "project.ext."):
            if text.startswith(prefix):
                rest = text[len(prefix):]
                name = leading_identifier(rest)
                rest = rest[len(name):].strip()
                break
    if not name:
        for prefix in ("ext[", "project.ext["):
            if text.startswith(prefix) and text[len(prefix):len(prefix) + 1] in ("'", '"'):
                q = text[len(prefix)]
                close = text.find(q + "]", len(prefix) + 1)
                if close < 0:
                    return None
                name = text[len(prefix) + 1:close]
                rest = text[close + 2:].strip()
                break
    if not name or not rest.startswith("=") or rest.startswith("=="):
        return None
    return (name, rest[1:].strip())

_CONTROL_FLOW = ("if", "else", "for", "while", "try", "catch", "finally")

def _assignment(text):
    """`(name, rest)` of a statement `name ...`, `if (c) name ...` or `else name ...`."""
    text = text.strip()
    for _ in range(4):
        word = leading_identifier(text)
        if word == "else":
            text = text[len(word):].strip()
        elif word == "if" and text[2:].strip().startswith("("):
            text = text[2:].strip()
            close = _close_of(text, 0)
            if close < 0:
                break
            text = text[close + 1:].strip()
        else:
            break
    name = leading_identifier(text)
    return (name, text[len(name):].strip())

def gradle_scope(tokens, properties = {}):
    """What a script defines that its values may name.

    Args:
        tokens: The script's tokens (`gradle_tokens`), those of the scripts
            it applies in their place.
        properties: The package's `gradle.properties` (`parse_gradle_properties`).

    Returns:
        A struct of `variables` (name to the expression it is set to, the
        last one set; variables of `def`, `val` or `var`, `ext.x =` and `ext { }`
        blocks, and not one a statement sets again with `x = ...`, which the
        reader does not follow), `functions` (name to `struct(params, body)`, the statements of
        a function the script defines, or None for one whose body holds blocks)
        and `properties`.
    """
    variables = {}
    assigned = {}
    functions = {}
    blocks = []
    function = None
    for t in tokens:
        if function != None:
            if t.kind == "open":
                function.depth.append(t)
                function.nested.append(True)
            elif t.kind == "close":
                if function.depth:
                    function.depth.pop()
                else:
                    functions[function.name] = None if function.nested else struct(
                        params = function.params,
                        body = function.body,
                    )
                    function = None
            elif not function.depth:
                function.body.append(t.text)
            continue
        if t.kind == "open":
            defined = _defined_function(t.text) if not blocks else None
            if defined:
                function = struct(name = defined[0], params = defined[1], body = [], depth = [], nested = [])
                continue
            blocks.append(leading_identifier(t.text) or t.text)
        elif t.kind == "close":
            if blocks:
                blocks.pop()
        else:
            d = _definition(t.text, blocks)
            if d:
                variables[d[0]] = d[1]
                continue
            name, rest = _assignment(t.text)

            # In a configuration block, such as `android { }`, `x = ...` sets
            # the block's `x`; in the script or its control flow, the variable.
            in_script = not [b for b in blocks if b not in _CONTROL_FLOW]
            if name and in_script and rest.startswith("=") and not rest.startswith("=="):
                assigned[name] = True
    return struct(
        variables = {name: value for name, value in variables.items() if name not in assigned},
        functions = functions,
        properties = properties,
    )

def _scan_literal(text):
    """The index after the string literal `text` starts with, or -1."""
    mask = code_mask(text)
    for i in range(1, len(text)):
        if mask[i]:
            return i
    return len(text) if text and text[0] in "'\"" else -1

def _plain_literal(text):
    """The value of `text` when it is one string literal with no `$`, or a number, else None."""
    text = text.strip()
    if not text:
        return None
    if text[0] in "'\"":
        if _scan_literal(text) != len(text):
            return None
        inner = text[1:-1]
        if text[0] == '"' and "$" in inner:
            return None
        out = ""
        escaped = False
        for c in inner.elems():
            if escaped:
                out += c
                escaped = False
            elif c == "\\":
                escaped = True
            else:
                out += c
        return out
    if text.replace(".", "").isdigit():
        return text
    return None

def _project_path(text):
    """The project `findProject(":x")`, `project(":x")` or `rootProject.findProject(":x")` names, else None."""
    text = text.strip()
    if text.startswith("rootProject."):
        text = text[len("rootProject."):]
    for name in ("findProject", "project"):
        if text.startswith(name + "(") and text.endswith(")"):
            path = _plain_literal(text[len(name) + 1:-1])
            if path and path.startswith(":") and ":" not in path[1:]:
                return _project(path[1:])
    return None

def _variable_value(name, scope):
    """The value of a variable whose expression is a literal or names a project, else None."""
    expression = scope.variables[name]
    literal = _plain_literal(expression)
    if literal != None:
        return _str([literal])
    if expression in ("true", "false"):
        return _bool(expression == "true")
    return _project_path(expression)

def _property(project, key, scope):
    """The property `key` of `project`: the script's, another plugin's, or the root's."""
    if key == None:
        return None
    if project == "":
        if key in scope.properties:
            return _str([scope.properties[key]])
        if key in scope.variables:
            return _variable_value(key, scope)
        return _NULL
    if project == ":root":
        return None
    return _str([{"package": project, "property": key}])

def _atom(text, scope, bindings):
    """A literal, or the value a name has."""
    text = text.strip()
    literal = _plain_literal(text)
    if literal != None:
        return _str([literal])
    if text in ("true", "false"):
        return _bool(text == "true")
    if text == "null":
        return _NULL
    if leading_identifier(text) != text or not text:
        return None
    if text in bindings:
        return bindings[text]
    if text == "project":
        return _project("")
    if text == "rootProject":
        return _project(":root")
    if text == "properties":
        return struct(kind = "properties", project = "")
    if text == "ext":
        return struct(kind = "ext", project = "")
    if text in scope.variables:
        return _variable_value(text, scope)
    if text in scope.properties:
        return _str([scope.properties[text]])
    return None

def _key(value):
    """The string a key value is, else None."""
    if value == None or value.kind != "str" or len(value.parts) != 1 or type(value.parts[0]) != "string":
        return None
    return value.parts[0]

def _member(value, name, args, scope):
    """`value.name`, or `value.name(args)` when `args` is a list."""
    if value == None:
        return None
    if value.kind == "project":
        if args == None:
            if name == "properties":
                return struct(kind = "properties", project = value.name)
            if name == "ext":
                return struct(kind = "ext", project = value.name)
            return None
        if name in ("findProperty", "property") and len(args) == 1:
            return _property(value.name, _key(args[0]), scope)
        if name in ("findProject", "project") and len(args) == 1:
            path = _key(args[0])
            if path and path.startswith(":") and ":" not in path[1:]:
                return _project(path[1:])
            return None
        if name == "hasProperty" and len(args) == 1:
            found = _property(value.name, _key(args[0]), scope)
            if found == None or found.kind != "null" and _truth(found) == None:
                return None
            return _bool(found.kind != "null")
        return None
    if value.kind == "properties":
        if args == None:
            return _property(value.project, name, scope)
        if name == "get" and len(args) == 1:
            return _property(value.project, _key(args[0]), scope)
        return None
    if value.kind == "ext":
        key = _key(args[0]) if args and len(args) == 1 else None
        if value.project == ":root":
            if args == None or name == "get":
                return _NULL
            if name == "has":
                return _bool(False) if key != None else None
            return None
        if value.project != "":
            return None
        if args == None:
            key = name
        elif name == "has":
            return _bool(key in scope.variables) if key != None else None
        elif name != "get":
            return None
        if key == None:
            return None
        return _variable_value(key, scope) if key in scope.variables else _NULL
    return None

def _index(value, key, scope):
    """`value[key]`."""
    if value == None:
        return None
    if value.kind in ("properties", "ext"):
        return _member(value, "get", [key], scope)
    return None

def _close_of(text, start):
    """The index of the bracket that closes the one at `start`, or -1."""
    mask = code_mask(text)
    depth = 0
    for i in range(start, len(text)):
        if not mask[i]:
            continue
        if text[i] in "([{":
            depth += 1
        elif text[i] in ")]}":
            depth -= 1
            if depth == 0:
                return i
    return -1

def call_arguments(text):
    """The top-level comma-separated arguments of a call.

    Args:
        text: What is between the call's parentheses.

    Returns:
        The arguments' texts, stripped.
    """
    mask = code_mask(text)
    out = []
    depth = 0
    start = 0
    for i in range(len(text)):
        if not mask[i]:
            continue
        if text[i] in "([{":
            depth += 1
        elif text[i] in ")]}":
            depth -= 1
        elif text[i] == "," and depth == 0:
            out.append(text[start:i].strip())
            start = i + 1
    if text[start:].strip():
        out.append(text[start:].strip())
    return out

def _chain(text, scope, bindings):
    """`a.b[c].d(e)`: an atom, a project call, and members, indices and calls of atoms."""
    text = text.strip()
    project = _project_path(text)
    if project != None:
        return project
    head = leading_identifier(text)
    if text and text[0] in "'\"":
        end = _scan_literal(text)
        if end < 0:
            return None
        value = _atom(text[:end], scope, bindings)
        i = end
    elif head:
        rest = text[len(head):]
        if rest.startswith("("):
            close = _close_of(text, len(head))
            if close < 0:
                return None
            args = [_atom(a, scope, bindings) for a in call_arguments(text[len(head) + 1:close])]
            value = _member(_project(""), head, args, scope)
            i = close + 1
        else:
            value = _atom(head, scope, bindings)
            i = len(head)
    else:
        return None
    for _ in range(len(text)):
        if i >= len(text) or value == None:
            break
        c = text[i]
        if c == "?" and text[i + 1:i + 2] == ".":
            i += 1
            continue
        if c == ".":
            name = leading_identifier(text[i + 1:])
            if not name:
                return None
            i += 1 + len(name)
            args = None
            if text[i:i + 1] == "(":
                close = _close_of(text, i)
                if close < 0:
                    return None
                args = [_atom(a, scope, bindings) for a in call_arguments(text[i + 1:close])]
                i = close + 1
            value = _member(value, name, args, scope)
        elif c == "[":
            close = _close_of(text, i)
            if close < 0:
                return None
            value = _index(value, _atom(text[i + 1:close], scope, bindings), scope)
            i = close + 1
        else:
            return None
    return value

def _truth(value):
    """Groovy's truth of a value, or None when it is not known."""
    if value == None:
        return None
    if value.kind == "null":
        return False
    if value.kind == "bool":
        return value.value
    if value.kind == "str":
        if [p for p in value.parts if type(p) != "string"]:
            return None
        return bool("".join(value.parts))
    return True

def _condition(text, scope, bindings):
    """Whether a condition `!a.b(c)` holds, or None."""
    text = text.strip()
    negate = False
    for _ in range(len(text)):
        if not text.startswith("!"):
            break
        negate = not negate
        text = text[1:].strip()
    if text.startswith("(") and _close_of(text, 0) == len(text) - 1:
        text = text[1:-1].strip()
    truth = _truth(_chain(text, scope, bindings))
    if truth == None:
        return None
    return truth != negate

def _call_function(function, args, scope):
    """What a function of the script returns for `args`, or None.

    Its body is read when every statement is `return x` or `if (c) return x`.
    """
    if function == None or len(args) != len(function.params):
        return None
    bindings = {}
    for name, arg in zip(function.params, args):
        bindings[name] = _chain(arg, scope, {})
    for statement in function.body:
        if statement.startswith("return ") or statement == "return":
            return _chain(statement[len("return"):], scope, bindings)
        if leading_identifier(statement) != "if":
            return None
        rest = statement[2:].strip()
        if not rest.startswith("("):
            return None
        close = _close_of(rest, 0)
        if close < 0:
            return None
        then = rest[close + 1:].strip()
        if not then.startswith("return "):
            return None
        holds = _condition(rest[1:close], scope, bindings)
        if holds == None:
            return None
        if holds:
            return _chain(then[len("return"):], scope, bindings)
    return _NULL

def _expression(text, scope):
    """A chain, or a call of a function of the script."""
    text = text.strip()
    name = leading_identifier(text)
    if name and name in scope.functions and text[len(name):].startswith("("):
        if _close_of(text, len(name)) != len(text) - 1:
            return None
        return _call_function(scope.functions[name], call_arguments(text[len(name) + 1:-1]), scope)
    return _chain(text, scope, {})

def _interpolation_end(text, start):
    """The index of the `}` that closes the `${` before `start` in a string's text, or -1."""
    mask = code_mask(text[start:])
    depth = 0
    for i in range(len(mask)):
        if not mask[i]:
            continue
        c = text[start + i]
        if c == "{":
            depth += 1
        elif c == "}":
            if depth == 0:
                return start + i
            depth -= 1
    return -1

def gradle_string(text, scope):
    """The parts of the string an expression evaluates to, or None when it is not a string.

    Args:
        text: An expression: a string literal, whose `$name`, `$a.b` and
            `${...}` are evaluated, or a value (`_expression`).
        scope: What the script defines (`gradle_scope`).

    Returns:
        A list of parts (see above), adjacent strings joined, or None.
    """
    text = text.strip()
    if not text or text[0] not in "'\"":
        value = _expression(text, scope)
        return value.parts if value != None and value.kind == "str" else None
    if _scan_literal(text) != len(text):
        return None
    if text[0] == "'":
        return [_plain_literal(text)]
    inner = text[1:-1]
    parts = []
    literal = ""
    i = 0
    for _ in range(len(inner) + 1):
        if i >= len(inner):
            break
        c = inner[i]
        if c == "\\" and i + 1 < len(inner):
            literal += inner[i + 1]
            i += 2
            continue
        if c != "$":
            literal += c
            i += 1
            continue
        if inner[i + 1:i + 2] == "{":
            end = _interpolation_end(inner, i + 2)
            if end < 0:
                return None
            value = _expression(inner[i + 2:end], scope)
            i = end + 1
        else:
            # `$name.member`: a name and its dotted members.
            end = i + 1
            for _ in range(len(inner)):
                name = leading_identifier(inner[end:])
                if not name:
                    break
                end += len(name)
                if inner[end:end + 1] != "." or not leading_identifier(inner[end + 1:]):
                    break
                end += 1
            if end == i + 1:
                literal += c
                i += 1
                continue
            value = _chain(inner[i + 1:end], scope, {})
            i = end
        if literal:
            if parts and type(parts[-1]) == "string":
                parts[-1] += literal
            else:
                parts.append(literal)
            literal = ""
        if value == None or value.kind != "str":
            parts.append(None)
            continue
        for p in value.parts:
            if type(p) == "string" and parts and type(parts[-1]) == "string":
                parts[-1] += p
            else:
                parts.append(p)
    if literal:
        if parts and type(parts[-1]) == "string":
            parts[-1] += literal
        else:
            parts.append(literal)
    return parts if parts else [""]
