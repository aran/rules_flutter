"""What rules_flutter reads from a pub plugin's `Package.swift`.

rules_flutter compiles a plugin's own sources, not a SwiftPM build, and builds
them as the manifest says: `swift package dump-package` evaluates the manifest
(the plugin's Apple repository runs it, see `apple_plugin_repo.bzl`), and
`swift_package_targets` turns the plugin's targets into the attributes of its
`flutter_apple_plugin_library`: its sources, its header search paths, and its
C, C++, Swift and linker settings, each under the platform and configuration
its condition names.

Dependencies. A pub plugin whose Apple side is a SwiftPM package lists what it
needs from other packages in `dependencies:`:

    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
        .package(path: "../shared"),
    ],

A remote package's products are the targets of the repository the root
module's rules_swift_package_manager declares for it (`swift_packages.bzl`). The Flutter framework's package
and a sibling plugin's are supplied by the build. A dependency on a directory
inside the plugin is fine: its sources are part of the plugin. Another
directory outside the plugin is not, and `find_unsupported_swiftpm_dependencies`
reports it.

Settings a manifest computes. `.define` and `.unsafeFlags` in a target's
`cSettings`, `cxxSettings` or `swiftSettings` set preprocessor macros and
compiler flags, and a manifest that imports more than `PackageDescription`, or
reads its `Context`, can compute them from what surrounds the build:
`permission_handler_apple` reads the app's `Info.plist` and enables a
permission's code only when the plist declares its usage description, so
built without its defines every permission reports `denied`, and nothing
fails. Evaluated in the plugin's repository, such a manifest computes them for
no app at all. `find_manifest_computations` says whether a manifest can, and
`find_swiftpm_build_settings` whether it sets any: a manifest that does both is
evaluated again for each app, which its defines are taken from
(`swiftpm_app_settings.bzl`).
"""

def _strip_comments(text):
    """Returns `text` without `//` and `/* */` comments, leaving strings alone."""
    out = []
    i = 0
    n = len(text)
    quote = None
    for _ in range(n * 2 + 1):
        if i >= n:
            break
        c = text[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
        elif c == '"':
            quote = c
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)

def _call_arguments(text, start):
    """Returns the text between the parenthesis opened at `start` and its match."""
    depth = 0
    quote = None
    i = start
    n = len(text)
    for _ in range(n + 1):
        if i >= n:
            break
        c = text[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c == '"':
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
        i += 1
    return text[start + 1:]

def _string_argument(args, label):
    """The string literal after top-level `label:` in `args`, or None."""
    marker = label + ":"
    quote = None
    depth = 0
    i = 0
    n = len(args)
    for _ in range(n + 1):
        if i >= n:
            break
        c = args[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c == '"':
            quote = c
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif depth == 0 and args.startswith(marker, i) and (i == 0 or not (args[i - 1].isalnum() or args[i - 1] == "_")):
            rest = args[i + len(marker):].lstrip()
            if rest.startswith('"'):
                end = rest.find('"', 1)
                if end > 0:
                    return rest[1:end]
            return ""
        i += 1
    return None

def _escapes(base_dir, path):
    """Whether `path`, taken relative to `base_dir` inside the plugin, leaves it."""
    if path.startswith("/") or path.startswith("~"):
        return True
    parts = [p for p in base_dir.split("/") if p and p != "."]
    for seg in path.split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if not parts:
                return True
            parts.pop()
        else:
            parts.append(seg)
    return False

def find_unsupported_swiftpm_dependencies(content, package_dir):
    """Finds the `.package(...)` dependencies of a `Package.swift` that cannot be met.

    Args:
        content: The text of the `Package.swift`.
        package_dir: The directory holding it, relative to the plugin's root
            (`ios/foo`), which local `path:` dependencies are resolved against.

    Returns:
        A list of strings, one per dependency: the URL of a remote package
        (`url:`, or a registry `id:`), or `path <path>` for a local one that
        lies outside the plugin.
    """
    text = _strip_comments(content)
    found = []
    marker = ".package("
    pos = 0
    for _ in range(len(text) + 1):
        at = text.find(marker, pos)
        if at < 0:
            break
        open_at = at + len(marker) - 1
        args = _call_arguments(text, open_at)
        pos = open_at + 1
        url = _string_argument(args, "url")
        pkg_id = _string_argument(args, "id")
        path = _string_argument(args, "path")
        if url != None:
            found.append(url)
        elif pkg_id != None:
            found.append("registry package " + pkg_id)
        elif path != None and _escapes(package_dir, path):
            found.append("path " + path)
    return found

def _top_level_arguments(args):
    """Splits a call's argument text at its top-level commas, trimmed."""
    parts = []
    depth = 0
    quote = None
    start = 0
    i = 0
    n = len(args)
    for _ in range(n + 1):
        if i >= n:
            break
        c = args[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c == '"':
            quote = c
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "," and depth == 0:
            parts.append(args[start:i])
            start = i + 1
        i += 1
    parts.append(args[start:])
    return [_collapse_whitespace(p) for p in parts if p.strip()]

def _collapse_whitespace(text):
    """`text` with each run of whitespace outside strings made one space."""
    out = []
    quote = None
    space = False
    i = 0
    n = len(text)
    for _ in range(n + 1):
        if i >= n:
            break
        c = text[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in " \t\n\r":
            space = True
        else:
            if space and out:
                out.append(" ")
            space = False
            if c == '"':
                quote = c
            out.append(c)
        i += 1
    return "".join(out).strip()

def _describe_define(args):
    """`define NAME`, `define NAME = <value>`, and any condition after them."""
    parts = _top_level_arguments(args)
    if not parts:
        return "define()"
    name = parts[0]
    if len(name) >= 2 and name.startswith('"') and name.endswith('"'):
        name = name[1:-1]
    text = "define " + name
    for part in parts[1:]:
        if part.startswith("to:"):
            text += " = " + part[len("to:"):].strip()
        else:
            text += ", " + part
    return text

def find_swiftpm_build_settings(content):
    """Finds the build settings of a `Package.swift` that change its compile.

    These are the `.define(...)` and `.unsafeFlags(...)` settings, wherever the
    manifest writes them: in a target's `cSettings`, `cxxSettings` or
    `swiftSettings`, or in a list it builds first and adds to them. Header
    search paths and linker settings are not reported: a missing one fails
    the compile or the link by itself.

    Args:
        content: The text of the `Package.swift`.

    Returns:
        A list of strings, one per setting, in manifest order:
        `define NAME`, `define NAME = <value as written>` (a value may be an
        expression the manifest computes), with any condition after a comma,
        or `unsafeFlags(<arguments>)`.
    """
    text = _strip_comments(content)
    found = []
    pos = 0
    for _ in range(len(text) + 1):
        define_at = text.find(".define(", pos)
        flags_at = text.find(".unsafeFlags(", pos)
        if define_at < 0 and flags_at < 0:
            break
        if flags_at < 0 or (define_at >= 0 and define_at < flags_at):
            open_at = define_at + len(".define(") - 1
            args = _call_arguments(text, open_at)
            found.append(_describe_define(args))
        else:
            open_at = flags_at + len(".unsafeFlags(") - 1
            args = _call_arguments(text, open_at)
            found.append("unsafeFlags(%s)" % _collapse_whitespace(args))
        pos = open_at + len(args) + 2
    return found

def find_manifest_computations(content):
    """What lets a `Package.swift` compute its result from what surrounds the build.

    A manifest that imports only `PackageDescription` and does not read its
    `Context` evaluates to the same package wherever it is evaluated. Any other
    import (`Foundation`, for `ProcessInfo` and `FileManager`) or `Context`
    (its environment and package directory) can make it read the environment,
    the file system or the app.

    Args:
        content: The text of the `Package.swift`.

    Returns:
        A list of strings, in manifest order: `import <module>` for each
        import of another module, then `Context` when the manifest names it.
    """
    text = _strip_comments(content)
    found = []
    for line in text.split("\n"):
        words = [w for w in line.replace(";", " ").replace("\t", " ").split(" ") if w]
        for i, word in enumerate(words):
            if word != "import" or i + 1 >= len(words):
                continue

            # Only a statement: at the start of the line, or after attributes
            # (`@preconcurrency import Foundation`).
            if [w for w in words[:i] if not w.startswith("@")]:
                continue

            # `import Foundation`, `import struct Foundation.URL`.
            module = words[i + 1]
            if module in _IMPORT_KINDS and i + 2 < len(words):
                module = words[i + 2]
            module = module.split(".")[0]
            if module != "PackageDescription":
                found.append("import " + module)
    pos = 0
    for _ in range(len(text) + 1):
        at = text.find("Context.", pos)
        if at < 0:
            break
        pos = at + 1
        before = text[at - 1] if at > 0 else " "
        if not (before.isalnum() or before in "_."):
            found.append("Context")
            break
    return found

_IMPORT_KINDS = ("struct", "class", "enum", "protocol", "func", "var", "let", "typealias")

# The file extensions SwiftPM compiles in a target, and the headers beside them.
SWIFTPM_SOURCE_EXTENSIONS = ("swift", "c", "m", "mm", "cc", "cpp", "cxx", "c++", "s", "S")
SWIFTPM_HEADER_EXTENSIONS = ("h", "hh", "hpp", "hxx", "h++")

# A setting under a condition on the build configuration lands in one of these,
# "" holding the unconditional ones. `flutter build` builds Xcode's Debug
# configuration in debug mode, and its Release configuration in profile and
# release mode, both of which Bazel builds with `-c opt`.
CONFIGURATIONS = ("", "debug", "release")

_SETTING_ATTRS = ("clang_copts", "cxxopts", "conlyopts", "swift_copts", "linkopts", "sdk_frameworks", "sdk_dylibs")

def _join(base, path):
    """`path` relative to `base` (both relative), normalized; None if it leaves the root."""
    parts = []
    for seg in (base + "/" + path).split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if not parts:
                return None
            parts.pop()
        else:
            parts.append(seg)
    return "/".join(parts)

def shell_quote_copt(flag):
    """`flag` as a `copts` entry of a C-family rule, which passes it on unchanged.

    Bazel splits those entries as a Bourne shell would, and expands `$(...)`:
    a define whose value is a string literal (`NAME="x"`) needs both undone.

    Args:
        flag: The flag as the compiler is to get it.

    Returns:
        The entry.
    """
    flag = flag.replace("$", "$$")
    for c in flag.elems():
        if not (c.isalnum() or c in "-_=+,./:@%"):
            return "'" + flag.replace("'", "'\\''") + "'"
    return flag

def _setting_value(kind, name):
    """The payload (`_0`) of a setting of kind `name` in `dump-package`'s JSON."""
    value = kind.get(name)
    if type(value) == "dict":
        return value.get("_0")
    return None

def _local_dependencies(target, targets, platform):
    """The names of the package's own targets `target` depends on for `platform`.

    A product of another package is the Flutter framework, a sibling plugin
    (which pubspec.yaml makes a dependency of the plugin) or a remote
    package, which the fetch refuses: none is the package's own.
    """
    found = []
    for dep in target.get("dependencies", []):
        for key in ("byName", "target"):
            value = dep.get(key)
            if not value:
                continue
            condition = value[-1] if type(value[-1]) == "dict" else None
            if condition and condition.get("platformNames") and platform not in condition["platformNames"]:
                continue
            if value[0] in targets and value[0] not in found:
                found.append(value[0])
    return found

def _package_dependencies(dump):
    """The package's dependencies by the names a `.product(package:)` may use.

    Returns:
        A dict of name (identity, and the name the manifest gives it) to a
        struct with `kind` (`sourceControl`, `fileSystem` or `registry`),
        `identity` and `location`.
    """
    found = {}
    for dep in dump.get("dependencies", []):
        for kind, entries in dep.items():
            for entry in entries:
                location = ""
                remote = (entry.get("location") or {}).get("remote")
                if remote:
                    location = remote[0].get("urlString", "")
                info = struct(kind = kind, identity = entry.get("identity", ""), location = location or entry.get("path", ""))
                found[info.identity] = info
                name = entry.get("nameForTargetDependencyResolutionOnly")
                if name:
                    found[name] = info
                    found[name.lower()] = info
    return found

def _remote_products(target, targets, packages, platform, problems):
    """The products of remote packages `target` depends on for `platform`.

    A product of a package on the file system is the Flutter framework or a
    sibling plugin, which pubspec.yaml makes a dependency of the plugin.

    A dependency by name alone (`"Foo"`, `.byName(name: "Foo")`) is a target
    of the package when it has one of that name, and otherwise the product
    `Foo` of the package named `Foo`, as SwiftPM resolves it.

    Returns:
        A list of `(identity, product)`.
    """
    found = []
    for dep in target.get("dependencies", []):
        value = dep.get("product")
        by_name = dep.get("byName")
        if not value and by_name and by_name[0] not in targets:
            value = [by_name[0], by_name[0], by_name[-1]]
        if not value:
            continue
        product, package = value[0], value[1]
        condition = value[-1] if type(value[-1]) == "dict" else None
        if condition and condition.get("platformNames") and platform not in condition["platformNames"]:
            continue
        info = packages.get(package) or packages.get((package or "").lower())
        if info == None and by_name:
            problems.append("its target `{}` depends on `{}`, which is neither a target of the package nor a package it declares".format(target.get("name"), product))
        elif info == None:
            problems.append("its target `{}` depends on `{}` of the package `{}`, which it does not declare".format(target.get("name"), product, package))
        elif info.kind == "sourceControl":
            if (info.identity, product) not in found:
                found.append((info.identity, product))
        elif info.kind == "registry":
            problems.append("its target `{}` depends on `{}` of the registry package `{}`, and rules_flutter builds only packages from source repositories (`.package(url:)`)".format(target.get("name"), product, info.identity))
    return found

_SWIFT_LANGUAGE_MODES = ("5", "6")

def _swift_language_mode(dump, target_mode):
    """The Swift language mode SwiftPM compiles a target's Swift in.

    The target's `swiftLanguageMode` setting, else the newest of the package's
    `swiftLanguageModes` (`swiftLanguageVersions`), else the mode of its
    tools version: 6 from `swift-tools-version: 6.0`, 5 before.
    """
    if target_mode:
        return target_mode
    declared = dump.get("swiftLanguageVersions") or []
    if declared:
        return sorted(declared, key = _version_key)[-1]
    tools = (dump.get("toolsVersion") or {}).get("_version", "5.0.0")
    return "6" if _version_key(tools)[0] >= 6 else "5"

def _version_key(version):
    """`"5.10.1"` as `[5, 10, 1]`, for comparing."""
    return [int(p) if p.isdigit() else 0 for p in version.split(".")]

def _target_build(dump, target, deps, platform, manifest_dir, problems, defines):
    """How one regular target of the package is built; None after a problem."""
    name = target.get("name")
    count = len(problems)

    # An empty `path` or `publicHeadersPath` is the directory it is relative
    # to, as SwiftPM reads it; only a missing one takes the default.
    path = target.get("path")
    target_dir = _join(manifest_dir, "Sources/" + name if path == None else path)
    if target_dir == None or not (target_dir + "/").startswith(manifest_dir + "/"):
        problems.append("its target `{}` is outside the package".format(name))
        return None

    def within(path, what):
        joined = _join(target_dir, path)
        if joined == None or not (joined + "/").startswith(manifest_dir + "/"):
            problems.append("its target `{}` names {} `{}`, outside the package".format(name, what, path))
            return None
        return joined

    sources = [within(p, "the source") for p in (target.get("sources") or ["."])]
    exclude = [within(p, "the excluded path") for p in target.get("exclude", [])]
    public_headers_path = target.get("publicHeadersPath")
    public_headers = within("include" if public_headers_path == None else public_headers_path, "the public header path")

    # A build tool plugin runs code at build time (cargokit's builds a Rust
    # crate), which rules_flutter does not.
    for usage in target.get("pluginUsages") or []:
        problems.append("its target `{}` uses the SwiftPM build plugin {}, which rules_flutter does not run".format(name, json.encode(usage)))

    # Its resources, which SwiftPM puts in a bundle of their own.
    resources = []
    for resource in target.get("resources", []):
        rule = resource.get("rule") or {}
        path = within(resource.get("path", ""), "the resource")
        if "copy" in rule:
            resources.append(struct(path = path, copy = True))
        elif "process" in rule:
            resources.append(struct(path = path, copy = False))
        else:
            problems.append("its target `{}` has a resource rules_flutter does not bundle: {}".format(name, json.encode(resource)))

    settings = {attr: {c: [] for c in CONFIGURATIONS} for attr in _SETTING_ATTRS}
    target_mode = None

    # SwiftPM searches a target's public header directory for its own sources too.
    includes = [public_headers]
    for setting in target.get("settings", []):
        condition = setting.get("condition") or {}
        if condition.get("platformNames") and platform not in condition["platformNames"]:
            continue
        if condition.get("traits"):
            problems.append("a setting of its target `{}` depends on the package's traits".format(name))
            continue
        configuration = condition.get("config") or ""
        tool = setting.get("tool")
        kind = setting.get("kind") or {}
        if configuration not in CONFIGURATIONS:
            problems.append("a setting of its target `{}` depends on the configuration `{}`".format(name, configuration))
        elif "define" in kind:
            if not defines:
                continue

            # SwiftPM gathers a target's C and C++ defines into one list,
            # which every C-family compile of the target gets.
            attr = "swift_copts" if tool == "swift" else "clang_copts"
            define = "-D" + _setting_value(kind, "define")
            if define not in settings[attr][configuration]:
                settings[attr][configuration].append(define)
        elif "headerSearchPath" in kind:
            path = within(_setting_value(kind, "headerSearchPath"), "the header search path")
            if configuration:
                problems.append("a header search path of its target `{}` depends on the configuration".format(name))
            elif path:
                includes.append(path)
        elif "unsafeFlags" in kind:
            attr = {"c": "clang_copts", "cxx": "cxxopts", "swift": "swift_copts", "linker": "linkopts"}[tool]
            settings[attr][configuration].extend(_setting_value(kind, "unsafeFlags") or [])
        elif "linkedFramework" in kind:
            settings["sdk_frameworks"][configuration].append(_setting_value(kind, "linkedFramework"))
        elif "linkedLibrary" in kind:
            settings["sdk_dylibs"][configuration].append(_setting_value(kind, "linkedLibrary"))
        elif "enableUpcomingFeature" in kind:
            settings["swift_copts"][configuration].extend(["-enable-upcoming-feature", _setting_value(kind, "enableUpcomingFeature")])
        elif "swiftLanguageMode" in kind or "swiftLanguageVersion" in kind:
            target_mode = _setting_value(kind, "swiftLanguageMode") or _setting_value(kind, "swiftLanguageVersion")
        elif "enableExperimentalFeature" in kind:
            settings["swift_copts"][configuration].extend(["-enable-experimental-feature", _setting_value(kind, "enableExperimentalFeature")])
        else:
            problems.append("its target `{}` has a {} setting rules_flutter does not apply: {}".format(name, tool, json.encode(kind)))

    # The package's language standards hold for each of its targets.
    if dump.get("cLanguageStandard"):
        settings["conlyopts"][""].append("-std=" + dump["cLanguageStandard"])
    if dump.get("cxxLanguageStandard"):
        settings["cxxopts"][""].append("-std=" + dump["cxxLanguageStandard"])

    targets = [t.get("name") for t in dump.get("targets", [])]
    remote_products = _remote_products(target, targets, _package_dependencies(dump), platform, problems)
    swift_language_mode = _swift_language_mode(dump, target_mode)
    if swift_language_mode not in _SWIFT_LANGUAGE_MODES:
        problems.append("its target `{}` is Swift {}, and rules_flutter compiles Swift 5 and 6".format(name, swift_language_mode))

    if len(problems) > count:
        return None
    return struct(
        name = name,
        deps = deps,
        remote_products = remote_products,
        resources = resources,
        resource_bundle = "{}_{}".format(dump.get("name", ""), name),
        swift_language_mode = swift_language_mode,
        dir = target_dir,
        sources = sources,
        exclude = exclude,
        public_headers = public_headers,
        includes = includes,
        **settings
    )

def swift_package_targets(dump, package_name, platform, manifest_dir, defines = True):
    """What a plugin's `Package.swift` says its `platform` library is built from.

    Flutter links a plugin's Swift package through its library product named
    after the plugin, with `-` for `_` (`flutter-qjs-next`), and imports the
    module named after the plugin. rules_flutter builds the product's targets
    and the package's targets they depend on, each a module of its own. The
    product's target named after the plugin (or its only target) is the
    plugin's module, and depends on the product's other targets, which the
    product links with it.

    Args:
        dump: The manifest as `swift package dump-package` prints it, decoded.
        package_name: The plugin's package name.
        platform: `"ios"` or `"macos"`.
        manifest_dir: The directory holding the manifest, relative to the
            plugin's root (`ios/foo`); the paths returned are relative to the
            plugin's root too.
        defines: Whether the settings hold the manifest's defines. False
            for a manifest that decides them from the app, whose defines
            come from its evaluation for each app (`swiftpm_app_settings.bzl`).

    Returns:
        A struct with `problems`, what keeps rules_flutter from building the
        package as the manifest says (a list of strings, empty when there is
        nothing), and, when there are none: `main`, the name of the target
        that is the plugin's module; `dynamic`, whether the product is
        `.dynamic`; and `targets`, the targets to build,
        each after those it depends on. A target is a struct: `name`;
        `deps`, the names of the package's targets it depends on;
        `swift_language_mode`, `"5"` or `"6"`; `resources`, structs with
        `path` and `copy` (`.copy`, else `.process`); `resource_bundle`, the
        name of the bundle SwiftPM puts them in (`<package>_<target>`);
        `remote_products`, the `(identity, product)` of each product of a
        remote package (`.package(url:)`) it depends on; `dir`, its
        source directory; `sources`, the files and directories its sources
        are in (its whole directory when the manifest names none);
        `exclude`; `public_headers`, its public header directory;
        `includes`; and its settings, each a dict from configuration (a
        `CONFIGURATIONS` entry) to a list: `clang_copts` (C, Objective-C and
        C++ compiles), `cxxopts` (C++ compiles), `conlyopts` (C compiles),
        `swift_copts`, `linkopts`, `sdk_frameworks` and `sdk_dylibs`. A copt
        is as the compiler gets it: `shell_quote_copt` makes it a C-family
        `copts` entry.
    """
    product_name = package_name.replace("_", "-")
    products = [
        p
        for p in dump.get("products", [])
        if p.get("name") == product_name and "library" in (p.get("type") or {})
    ]
    if not products:
        return struct(problems = [
            "it has no library product named `{}`, which Flutter links a plugin's package by".format(product_name),
        ])
    targets = {t.get("name"): t for t in dump.get("targets", [])}
    product_targets = products[0].get("targets", [])
    dynamic = "dynamic" in products[0]["type"]["library"]
    for name in product_targets:
        if name not in targets:
            return struct(problems = ["its `{}` product names `{}`, no target of the package".format(product_name, name)])
    if len(product_targets) == 1:
        main = product_targets[0]
    elif package_name in product_targets:
        main = package_name
    else:
        return struct(problems = [
            "its `{}` product is the targets {}, none of them the module `{}` Flutter imports".format(
                product_name,
                ", ".join(["`{}`".format(t) for t in product_targets]),
                package_name,
            ),
        ])

    # The targets to build, each after the targets it depends on: a
    # depth-first walk from the plugin's module.
    deps = {}
    order = []
    stack = [(main, False)]
    for _ in range(4 * len(targets) + 4):
        if not stack:
            break
        name, expanded = stack.pop()
        if expanded:
            order.append(name)
            continue
        if name in deps:
            continue
        deps[name] = _local_dependencies(targets[name], targets, platform)
        if name == main:
            deps[name] += [t for t in product_targets if t != main and t not in deps[name]]
        stack.append((name, True))
        for dep in reversed(deps[name]):
            if dep not in deps:
                stack.append((dep, False))

    problems = []
    built = []
    for name in order:
        target = targets[name]
        if target.get("type") != "regular":
            problems.append("its target `{}` is a {} target, which rules_flutter does not build".format(name, target.get("type")))
            continue
        build = _target_build(dump, target, deps[name], platform, manifest_dir, problems, defines)
        if build:
            built.append(build)
    if problems:
        return struct(problems = problems)
    return struct(problems = [], main = main, targets = built, dynamic = dynamic)

def swift_package_message(package, version, platform, manifest, problems):
    """Why the `platform` build of an app linking `package` stops at its Package.swift.

    Args:
        package: The pub package's name.
        version: Its version.
        platform: `"ios"` or `"macos"`.
        manifest: The manifest, relative to the plugin's root.
        problems: What `swift_package_targets` found.

    Returns:
        The message.
    """
    return (
        "package:{pkg} {version} cannot be built for {platform} as its {manifest} says:\n    {problems}\n" +
        "Give {pkg} a plugin overlay (`flutter_pub.plugin_overlays` in MODULE.bazel) " +
        "that builds it with `flutter_apple_plugin_library`."
    ).format(
        pkg = package,
        version = version,
        manifest = manifest,
        problems = "\n    ".join(problems),
        platform = {"ios": "iOS", "macos": "macOS"}[platform],
    )
