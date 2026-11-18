"""System libraries that a pub plugin's CMake build links its Linux/Windows library with.

A pub plugin's `windows/CMakeLists.txt` and `linux/CMakeLists.txt` are how the
Flutter tool builds the plugin, and they declare what the plugin's code needs
at link time:

    target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin shlwapi.lib)

rules_flutter does not run CMake. It compiles the plugin's sources into the
application's runner, so the runner has to be linked with what the plugin
declares. `parse_cmake_link_libraries` reads the `target_link_libraries` calls
that name the plugin's own library and turns them into linker flags:

* The targets the Flutter template always links (`flutter`,
  `flutter_wrapper_plugin` on Windows; `flutter`, `PkgConfig::GTK` on Linux)
  are what the runner already links, so they need nothing.
* A plain system library (`shlwapi`, `shlwapi.lib`, `m`) becomes a linker
  flag: `shlwapi.lib` on Windows, `-lm` on Linux.
* A list variable (`${wmf_libs}`) is read when the file sets it once, outside
  any block, to literal values (`set(wmf_libs dxva2.lib mf.lib)`) before the
  call; its values are then read as above. This is the rule the Gradle reader
  applies to a version variable.
* Everything else cannot be translated without running CMake: other
  variables, generator expressions, imported targets (`PkgConfig::LIBSECRET`), targets
  defined by the plugin or fetched by it, paths, linker flags, and calls inside
  `if()`/`foreach()` blocks. Each is reported with its line, never dropped,
  because a dropped library is a link error far from its cause.

The plugin's own declaration is the only input, as with the Gradle dependency
reader in `android_plugin_maven.bzl`. The caller turns the errors into a
failure when a runner links the plugin, so that builds for other platforms are
unaffected.
"""

visibility("//flutter/...")

_WHITESPACE = " \t\r\n"
_IDENTIFIER_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

# Characters that end an unquoted argument.
_ARGUMENT_END = _WHITESPACE + "()#\""

_BLOCK_OPENERS = ("if", "foreach", "while", "function", "macro", "block")
_BLOCK_CLOSERS = ("endif", "endforeach", "endwhile", "endfunction", "endmacro", "endblock")

# Commands that bring in targets this file does not define.
_EXTERNAL_TARGET_COMMANDS = (
    "add_subdirectory",
    "fetchcontent_makeavailable",
    "externalproject_add",
)

# What the runner links already, by platform.
_PROVIDED_TARGETS = {
    "windows": ("flutter", "flutter_wrapper_plugin"),
    "linux": ("flutter", "PkgConfig::GTK"),
}

# `target_link_libraries` keywords that carry no library.
_SCOPE_KEYWORDS = ("PRIVATE", "PUBLIC", "INTERFACE")
_CONFIG_KEYWORDS = ("debug", "optimized", "general")

def _line_of(content, index):
    return content[:index].count("\n") + 1

def _bracket_open(content, i):
    """The `=` count of a bracket opener `[==[` at `i`, or -1 if there is none."""
    if content[i:i + 1] != "[":
        return -1
    j = i + 1
    for _ in range(len(content)):
        if content[j:j + 1] != "=":
            break
        j += 1
    if content[j:j + 1] != "[":
        return -1
    return j - i - 1

def _bracket_end(content, i, level):
    """The index after the bracket that opens at `i` closes; the end if it never does."""
    close = "]" + "=" * level + "]"
    found = content.find(close, i + level + 2)
    if found < 0:
        return len(content)
    return found + len(close)

def _skip_comment(content, i):
    """The index after the comment that starts at `i`."""
    level = _bracket_open(content, i + 1)
    if level >= 0:
        return _bracket_end(content, i + 1, level)
    end = content.find("\n", i)
    if end < 0:
        return len(content)
    return end

def _quoted_end(content, i):
    """The index of the closing quote of the string that opens at `i`, or -1."""
    n = len(content)
    j = i + 1
    for _ in range(n):
        if j >= n:
            return -1
        if content[j] == "\\":
            j += 2
        elif content[j] == "\"":
            return j
        else:
            j += 1
    return -1

def _argument(text, quoted):
    return struct(text = text, quoted = quoted)

def _parse_arguments(content, start):
    """Reads a command's arguments from the index after its `(`.

    Returns:
        A struct with `end` (the index after the closing `)`) and `args`, or
        None when the call is never closed.
    """
    n = len(content)
    args = []
    nested = 0
    i = start
    for _ in range(n + 1):
        if i >= n:
            return None
        c = content[i]
        if c in _WHITESPACE:
            i += 1
        elif c == "#":
            i = _skip_comment(content, i)
        elif c == ")":
            if nested == 0:
                return struct(end = i + 1, args = args)
            nested -= 1
            args.append(_argument(")", False))
            i += 1
        elif c == "(":
            nested += 1
            args.append(_argument("(", False))
            i += 1
        elif c == "\"":
            close = _quoted_end(content, i)
            if close < 0:
                return None
            args.append(_argument(content[i + 1:close], True))
            i = close + 1
        else:
            level = _bracket_open(content, i)
            if level >= 0:
                end = _bracket_end(content, i, level)
                args.append(_argument(content[i + level + 2:end - level - 2], True))
                i = end
                continue
            j = i
            for _ in range(n):
                if j >= n or content[j] in _ARGUMENT_END:
                    break
                j += 1
            args.append(_argument(content[i:j], False))
            i = j
    return None

def scan_cmake_commands(content):
    """Splits a CMake script into its command invocations.

    Args:
        content: The `CMakeLists.txt` text.

    Returns:
        A list of structs with `name` (lower case), `args` (structs with `text`
        and `quoted`), `line` (1-based) and `depth` (how many `if`, `foreach`,
        `while`, `function`, `macro` or `block` blocks enclose the call).
    """
    n = len(content)
    commands = []
    depth = 0
    i = 0
    for _ in range(n + 1):
        if i >= n:
            break
        c = content[i]
        if c in _WHITESPACE:
            i += 1
        elif c == "#":
            i = _skip_comment(content, i)
        elif c in _IDENTIFIER_CHARS:
            j = i
            for _ in range(n):
                if j >= n or content[j] not in _IDENTIFIER_CHARS:
                    break
                j += 1
            name = content[i:j].lower()
            k = j
            for _ in range(n):
                if k >= n or content[k] not in _WHITESPACE:
                    break
                k += 1
            if content[k:k + 1] != "(":
                i = j
                continue
            parsed = _parse_arguments(content, k + 1)
            if parsed == None:
                break
            if name in _BLOCK_CLOSERS and depth > 0:
                depth -= 1
            commands.append(struct(
                name = name,
                args = parsed.args,
                line = _line_of(content, i),
                depth = depth,
            ))
            if name in _BLOCK_OPENERS:
                depth += 1
            i = parsed.end
        else:
            i += 1
    return commands

def _plugin_target(commands):
    """The name token of the plugin's library, as written ("${PLUGIN_NAME}")."""
    first = None
    for cmd in commands:
        if cmd.name != "add_library" or not cmd.args:
            continue
        if first == None:
            first = cmd.args[0].text
        if len(cmd.args) > 1 and cmd.args[1].text in ("SHARED", "MODULE"):
            return cmd.args[0].text
    return first

def _local_targets(commands):
    return [
        cmd.args[0].text
        for cmd in commands
        if cmd.name in ("add_library", "add_executable", "add_custom_target") and cmd.args
    ]

# `set()` options that make the variable something other than a local list.
_SET_OPTIONS = ("CACHE", "PARENT_SCOPE", "FORCE", "INTERNAL")

def _literal_values(cmd):
    """The values of a `set(<name> <values>...)` call that are all literal, else None."""
    values = []
    for arg in cmd.args[1:]:
        text = arg.text
        if text in _SET_OPTIONS or "$" in text or ";" in text or "\\" in text:
            return None
        if text != "":
            values.append(text)
    if not values:
        return None
    return values

def _literal_variables(commands):
    """Variables the file sets once, outside any block, to literal values.

    A variable qualifies when a single command of the file names it (`set`,
    `list(APPEND ...)`, `unset`, `foreach`, `if` and the rest all count), and that
    command is a `set()` at the top level with literal values only.

    Returns:
        A dict of variable name to a struct with `values`, `index` (of the
        `set()` in `commands`) and `line`.
    """
    variables = {}
    for index, cmd in enumerate(commands):
        if cmd.name != "set" or cmd.depth > 0 or not cmd.args:
            continue
        name = cmd.args[0].text
        if name in variables:
            continue
        values = _literal_values(cmd)
        if values == None:
            continue
        mentions = 0
        for other in commands:
            if other.name == "target_link_libraries":
                continue
            for arg in other.args:
                if arg.text == name:
                    mentions += 1
                    break
        if mentions == 1:
            variables[name] = struct(values = values, index = index, line = cmd.line)
    return variables

def _expand_items(cmd, index, variables):
    """The items of a `target_link_libraries` call, with literal variables replaced.

    Returns:
        A list of structs with `text`, `quoted` and `origin` (the variable an
        item came from, or "").
    """
    items = []
    for arg in cmd.args[1:]:
        text = arg.text
        name = text[2:-1] if text.startswith("${") and text.endswith("}") else ""
        known = variables.get(name) if name and not arg.quoted else None
        if known != None and known.index < index:
            for value in known.values:
                items.append(struct(text = value, quoted = False, origin = text))
        else:
            items.append(struct(text = text, quoted = arg.quoted, origin = ""))
    return items

def _library_flag(item, platform, local_targets, has_external_targets):
    """The linker flag for one `target_link_libraries` item.

    Returns:
        A struct with `flag` (a string, or None) and `error` (a string, or
        None). Exactly one is set, except that an item the runner links
        already has neither.
    """
    text = item.text
    if text in _PROVIDED_TARGETS[platform]:
        return struct(flag = None, error = None)
    if text in _SCOPE_KEYWORDS:
        return struct(flag = None, error = None)
    if text in _CONFIG_KEYWORDS:
        return struct(flag = None, error = "`%s` makes the next library depend on the build mode" % text)
    if text.startswith("${"):
        return struct(flag = None, error = "`%s` is a CMake variable that this file does not set once, outside any block, to literal values before this call" % text)
    if "$" in text:
        return struct(flag = None, error = "`%s` is a generator expression or contains a variable" % text)
    if ";" in text or " " in text or text == "":
        return struct(flag = None, error = "`%s` is not a single library name" % text)
    if "::" in text:
        return struct(flag = None, error = "`%s` is an imported CMake target" % text)
    if text.startswith("-"):
        return struct(flag = None, error = "`%s` is a linker flag" % text)
    if "/" in text or "\\" in text:
        return struct(flag = None, error = "`%s` is a path" % text)
    if text in local_targets:
        return struct(flag = None, error = "`%s` is a CMake target this file defines" % text)
    if text.startswith("flutter"):
        return struct(flag = None, error = "`%s` is a Flutter template target rules_flutter does not provide" % text)

    if platform == "windows":
        if text.lower().endswith(".lib"):
            return struct(flag = text, error = None)
        if "." in text:
            return struct(flag = None, error = "`%s` is not a plain library name" % text)
        if has_external_targets:
            return struct(flag = None, error = "`%s` may be a target of a subdirectory or fetched project" % text)
        return struct(flag = text + ".lib", error = None)

    for c in text.elems():
        if c not in _IDENTIFIER_CHARS and c not in "+-":
            return struct(flag = None, error = "`%s` is not a plain library name" % text)
    if has_external_targets:
        return struct(flag = None, error = "`%s` may be a target of a subdirectory or fetched project" % text)
    return struct(flag = "-l" + text, error = None)

def parse_cmake_link_libraries(content, platform, path):
    """The linker flags a plugin's `target_link_libraries` calls ask for.

    Args:
        content: The plugin's `CMakeLists.txt` text.
        platform: `"windows"` or `"linux"`.
        path: The file's path in the package, for the error lines.

    Returns:
        A struct with `linkopts` (linker flags in declaration order, without
        duplicates) and `errors` (lines `<path>:<line>: <what>` for everything
        that cannot be translated).
    """
    if platform not in _PROVIDED_TARGETS:
        fail("parse_cmake_link_libraries: platform must be 'windows' or 'linux', got %r" % platform)
    commands = scan_cmake_commands(content)
    target = _plugin_target(commands)
    local_targets = _local_targets(commands)
    has_external_targets = False
    for cmd in commands:
        if cmd.name in _EXTERNAL_TARGET_COMMANDS:
            has_external_targets = True

    variables = _literal_variables(commands)
    linkopts = []
    seen = {}
    errors = []
    for index, cmd in enumerate(commands):
        if cmd.name != "target_link_libraries" or not cmd.args or cmd.args[0].text != target:
            continue
        if cmd.depth > 0:
            errors.append("%s:%d: target_link_libraries is inside an if(), foreach() or function() block" % (path, cmd.line))
            continue
        config_specific = False
        for item in _expand_items(cmd, index, variables):
            if config_specific:
                # The library after `debug`/`optimized`/`general` is the one
                # whose use depends on the build mode: not linked unconditionally.
                config_specific = False
                continue
            result = _library_flag(item, platform, local_targets, has_external_targets)
            if item.text in _CONFIG_KEYWORDS:
                config_specific = True
            if result.error:
                origin = " (from %s)" % item.origin if item.origin else ""
                errors.append("%s:%d: %s%s" % (path, cmd.line, result.error, origin))
            elif result.flag != None and result.flag.lower() not in seen:
                seen[result.flag.lower()] = True
                linkopts.append(result.flag)
    return struct(linkopts = linkopts, errors = errors)
