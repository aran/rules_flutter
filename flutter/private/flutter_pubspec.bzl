"""Project a pub package's `flutter:` block to the shapes rules_flutter consumes.

Reading the pubspec is rules_dart's `read_pubspec`, which loads it as pub does
and refuses what pub refuses. Its `fields` (the whole document as JSON values)
are what these functions take:

- `flutter_plugin_block` — `flutter.plugin` for plugin-spoke emission.
- `flutter_assets_block` — `flutter.{fonts,assets,shaders,uses-material-design}`
  for the asset-bundling pipeline.
- `flutter_licenses_block` — `flutter.licenses`, the files `NOTICES` appends.

Schema reference (Flutter's pubspec):

    flutter:
      uses-material-design: bool
      fonts:
        - family: <name>
          fonts:
            - asset: <path>
              weight: <int>          # optional
              style: <italic|normal> # optional
      assets:
        - <path>                     # string form
        - path: <path>               # map form (modern)
          flavors: [<flavor>, ...]
          platforms: [<platform>, ...]
          transformers:              # refused: rules_flutter does not run them
            - package: <name>
      shaders:
        - <path>                     # string form
        - path: <path>               # map form
          flavors: [<flavor>, ...]
          platforms: [<platform>, ...]
          transformers:              # refused, as an asset's are
            - package: <name>
      licenses:
        - <path>                     # a file of the package, appended to NOTICES
      plugin:
        implements: <umbrella>
        platforms:
          <platform>:
            pluginClass: <Class>
            ...
"""

def flutter_block(fields):
    """Return the `flutter:` sub-dict, or empty dict when absent.

    Args:
        fields: A pubspec's `fields`, as `read_pubspec` returns them.

    Returns:
        The `flutter:` mapping, or `{}` when the pubspec has none (or has a
        `flutter:` that is not a mapping).
    """
    flutter = fields.get("flutter")
    return flutter if type(flutter) == "dict" else {}

# ---------------------------------------------------------------------------
# flutter.plugin
# ---------------------------------------------------------------------------

def _coerce_plugin_value(v):
    # Booleans stay booleans; everything else stringifies. None → empty string.
    if type(v) == "bool":
        return v
    if v == None:
        return ""
    return str(v)

def _version_key(text):
    # A semantic version's order (`2.11.0-0` before `2.11.0`), or None for
    # text that is not one.
    core = text.split("+")[0]
    pre = ""
    if "-" in core:
        core, pre = core.split("-", 1)
    parts = core.split(".")
    if len(parts) != 3 or not all([p.isdigit() for p in parts]):
        return None
    return (int(parts[0]), int(parts[1]), int(parts[2]), 0 if pre else 1)

def _constraint_min(constraint):
    """The lower bound of a pub version constraint, as a `_version_key`; None when it has none.

    What pub_semver's `VersionRange.min` is: of `^2.11.0`, `>=2.11.0 <4.0.0`,
    `>2.11.0` or `2.11.0` it is 2.11.0. `any`, an upper bound alone and a
    union (`||`) have none.
    """
    if type(constraint) != "string" or "||" in constraint:
        return None
    text = constraint.replace(">= ", ">=").replace("> ", ">").replace("<= ", "<=").replace("< ", "<")
    lowest = None
    for comparator in [c for c in text.split(" ") if c]:
        if comparator.startswith("^"):
            bound = comparator[1:]
        elif comparator.startswith(">="):
            bound = comparator[2:]
        elif comparator.startswith(">"):
            bound = comparator[1:]
        elif comparator.startswith("<") or comparator == "any":
            continue
        else:
            bound = comparator
        key = _version_key(bound)
        if key == None:
            return None
        if lowest == None or key > lowest:
            lowest = key
    return lowest

# Flutter 2.11, from which flutter_tools takes an app-facing package's own
# Dart implementation on a desktop platform as its implementation.
_DESKTOP_DART_SELF_IMPLEMENTATION = (2, 11, 0, 1)

def _drops_desktop_dart_class(fields):
    # flutter_tools' `_isEligibleDartSelfImpl`: desktop platforms once took no
    # package's own `dartPluginClass` as its implementation, and to keep
    # published plugins working still do not unless the package requires
    # Flutter 2.11 or later.
    environment = fields.get("environment")
    flutter = environment.get("flutter") if type(environment) == "dict" else None
    lowest = _constraint_min(flutter)
    return lowest == None or lowest < _DESKTOP_DART_SELF_IMPLEMENTATION

def flutter_plugin_block(fields):
    """Project `flutter.plugin` out of a pubspec's fields.

    The platforms are as flutter_tools reads them for registering: on Linux,
    macOS and Windows, the `dartPluginClass` (and `dartFileName`) of a package
    that implements no other and names no `default_package` there is left out
    unless its `environment: flutter:` requires Flutter 2.11 or later, as
    flutter_tools registers no Dart class of such a package.

    Args:
        fields: A pubspec's `fields`, as `read_pubspec` returns them.

    Returns:
        A struct with:
            present: bool — True iff a `flutter.plugin` block exists.
            platforms: dict of `<platform> -> dict[key, value]`. Empty dict
                when no `platforms:` key is present.
            implements: str — value of `flutter.plugin.implements` or `""`.
            ffi_plugin: bool — value of `flutter.plugin.ffiPlugin` or False.
    """
    flutter = flutter_block(fields)
    plugin = flutter.get("plugin")
    if type(plugin) != "dict":
        return struct(
            present = False,
            platforms = {},
            implements = "",
            ffi_plugin = False,
        )

    platforms_raw = plugin.get("platforms", {})
    platforms = {}
    if type(platforms_raw) == "dict":
        for name, info in platforms_raw.items():
            if type(info) == "dict":
                platforms[name] = {k: _coerce_plugin_value(v) for k, v in info.items()}

    implements_raw = plugin.get("implements", "")
    implements = str(implements_raw) if implements_raw != None else ""

    if not implements and _drops_desktop_dart_class(fields):
        for name in ("linux", "macos", "windows"):
            info = platforms.get(name)
            if info != None and "dartPluginClass" in info and not info.get("default_package"):
                platforms[name] = {k: v for k, v in info.items() if k not in ("dartPluginClass", "dartFileName")}

    ffi_raw = plugin.get("ffiPlugin", False)
    ffi_plugin = ffi_raw if type(ffi_raw) == "bool" else False

    return struct(
        present = True,
        platforms = platforms,
        implements = implements,
        ffi_plugin = ffi_plugin,
    )

# ---------------------------------------------------------------------------
# flutter.fonts / flutter.assets / flutter.shaders / flutter.uses-material-design
# ---------------------------------------------------------------------------

def _project_fonts(raw):
    if type(raw) != "list":
        return []
    out = []
    for entry in raw:
        if type(entry) != "dict":
            continue
        family = entry.get("family")
        if type(family) != "string":
            continue
        fonts_raw = entry.get("fonts", [])
        if type(fonts_raw) != "list":
            fonts_raw = []
        fonts = []
        for f in fonts_raw:
            if type(f) != "dict":
                continue
            asset = f.get("asset")
            if type(asset) != "string":
                continue
            weight = f.get("weight")
            style = f.get("style")
            fonts.append(struct(
                asset = asset,
                weight = weight if type(weight) == "int" else None,
                style = style if type(style) == "string" else None,
            ))
        out.append(struct(family = family, fonts = fonts))
    return out

def _project_entries(raw):
    """Project `flutter.assets` or `flutter.shaders`, whose entries have one shape.

    flutter_tools reads both lists as `AssetsEntry`s: a path, or a map with a
    `path` and optional `flavors`, `platforms` and `transformers`. It runs a
    shader's transformers on its source before compiling it, as it runs an
    asset's before bundling it.
    """
    if type(raw) != "list":
        return []
    out = []
    for entry in raw:
        if type(entry) == "string":
            out.append(struct(path = entry, flavors = [], platforms = [], transformers = []))
            continue
        if type(entry) != "dict":
            continue
        path = entry.get("path")
        if type(path) != "string":
            continue
        flavors_raw = entry.get("flavors", [])
        platforms_raw = entry.get("platforms", [])
        transformers_raw = entry.get("transformers", [])
        out.append(struct(
            path = path,
            flavors = [str(f) for f in flavors_raw] if type(flavors_raw) == "list" else [],
            platforms = [str(p) for p in platforms_raw] if type(platforms_raw) == "list" else [],
            transformers = transformers_raw if type(transformers_raw) == "list" else ([transformers_raw] if transformers_raw else []),
        ))
    return out

def flutter_assets_block(fields):
    """Project `flutter.fonts`, `flutter.assets`, `flutter.shaders`, and `flutter.uses-material-design`.

    Args:
        fields: A pubspec's `fields`, as `read_pubspec` returns them.

    Returns:
        struct(
            fonts:    list[struct(family, fonts=list[struct(asset, weight, style)])],
            assets:   list[struct(path, flavors, platforms, transformers)],
            shaders:  list[struct(path, flavors, platforms, transformers)],
            uses_material_design: bool,
        )

    `weight` and `style` on a font are None when unset. `flavors`/`platforms`
    are captured from modern-shape asset and shader entries; `flutter_pub_package`
    acts on them.
    """
    flutter = flutter_block(fields)
    umd_raw = flutter.get("uses-material-design", False)
    return struct(
        fonts = _project_fonts(flutter.get("fonts")),
        assets = _project_entries(flutter.get("assets")),
        shaders = _project_entries(flutter.get("shaders")),
        uses_material_design = umd_raw if type(umd_raw) == "bool" else False,
    )

# ---------------------------------------------------------------------------
# What `flutter build` refuses in fonts / assets / shaders
# ---------------------------------------------------------------------------
#
# flutter_tools validates a pubspec's `flutter:` block (`_validate` in
# flutter_manifest.dart) and refuses a manifest that fails. The projections
# above read leniently; this is the check that makes a package flutter_tools
# would refuse fail the fetch instead of losing the entry. Its messages follow
# flutter_tools', each placed by where the entry is in the pubspec.

_FONT_WEIGHTS = [100, 200, 300, 400, 500, 600, 700, 800, 900]
_PLATFORMS = ["android", "ios", "web", "windows", "linux", "macos"]
_DART_TYPES = {
    "string": "String",
    "int": "int",
    "float": "double",
    "bool": "bool",
    "list": "YamlList",
    "dict": "YamlMap",
    "NoneType": "Null",
}

def _dart_type(v):
    return _DART_TYPES[type(v)]

def _show(v):
    # A YAML value as text: `null`, `true`, a collection as JSON.
    if v == None:
        return "null"
    if type(v) in ["list", "dict"]:
        return json.encode(v)
    if type(v) == "bool":
        return "true" if v else "false"
    return str(v)

def _list_of_errors(value, context, alias, is_item):
    # flutter_tools' `_parseList<T>`: a list whose items all are a T.
    if type(value) != "list":
        return ["Expected {} to be a list of {}, but got {} ({}).".format(context, alias, _show(value), _dart_type(value))]
    return [
        "Expected {} to be a list of {}, but element at index {} was a {}.".format(context, alias, i, _dart_type(item))
        for i, item in enumerate(value)
        if not is_item(item)
    ]

def _is_string(v):
    return type(v) == "string"

def _is_map(v):
    return type(v) == "dict"

def _transformer_errors(entry):
    package = entry.get("package")
    if type(package) != "string" or not package:
        return ['Expected "package" to be a String. Found {} instead.'.format(_dart_type(package))]
    args = entry.get("args")
    if args == None:
        return []
    return [
        'In args section of transformer using package "{}": {}'.format(package, e)
        for e in _list_of_errors(args, "args", "String", _is_string)
    ]

_ALPHA = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
_SCHEME_CHARS = _ALPHA + "0123456789+-."

def _parses_as_uri(text):
    # Whether Dart's `Uri.parse` accepts `text`. It accepts nearly anything (a
    # space, a bare `%`, non-ASCII); what it throws on is a malformed scheme,
    # port or host, which this checks, and not the finer shape of an IPv6
    # address.
    rest = text
    first_segment_end = len(text)
    for i in range(len(text)):
        if text[i] in "/?#":
            first_segment_end = i
            break
    colon = text.find(":", 0, first_segment_end)
    if colon >= 0:
        scheme = text[:colon]
        if not scheme or scheme[0] not in _ALPHA:
            return False
        for c in scheme.elems():
            if c not in _SCHEME_CHARS:
                return False
        rest = text[colon + 1:]
    if not rest.startswith("//"):
        return True
    authority = rest[2:]
    for i in range(len(authority)):
        if authority[i] in "/?#":
            authority = authority[:i]
            break
    if authority.count("@") > 1:
        return False
    host = authority[authority.rfind("@") + 1:]
    if host.startswith("["):
        close = host.find("]")
        if close < 0:
            return False
        port = host[close + 1:]
        if port and not port.startswith(":"):
            return False
        port = port[1:]
    elif "]" in host:
        return False
    else:
        port = host[host.rfind(":") + 1:] if ":" in host else ""
    port = port[1:] if port.startswith("+") else port
    return not port or port.isdigit()

def _asset_entry_errors(entry):
    if entry == None or entry == "":
        return ["Asset manifest contains a null or empty uri."]
    if type(entry) == "string":
        return [] if _parses_as_uri(entry) else ["Asset manifest contains invalid uri: {}.".format(entry)]
    if type(entry) != "dict":
        return ["Assets entry had unexpected shape. Expected a string or an object. Got {} instead.".format(_dart_type(entry))]
    if not entry:
        return []
    path = entry.get("path")
    if type(path) != "string":
        return [(
            "Asset manifest entry is malformed. Expected asset entry to be either a string or a map " +
            'containing a "path" entry. Got {} instead.'
        ).format(_dart_type(path))]
    sections = []
    flavors = entry.get("flavors")
    if flavors != None:
        sections.append(("flavors", _list_of_errors(flavors, "flavors", "String", _is_string)))
    platforms = entry.get("platforms")
    if platforms != None:
        errors = _list_of_errors(platforms, "platforms", "String", _is_string)
        if not errors:
            invalid = []
            for platform in platforms:
                if platform not in _PLATFORMS and platform not in invalid:
                    invalid.append(platform)
            if invalid:
                errors = ['Invalid platform(s): "{}". Supported platforms are: "{}".'.format(", ".join(invalid), ", ".join(_PLATFORMS))]
        sections.append(("platforms", errors))
    transformers = entry.get("transformers")
    if transformers != None:
        errors = _list_of_errors(transformers, "transformers list", "Map", _is_map)
        if not errors:
            errors = [e for item in transformers for e in _transformer_errors(item)]
        sections.append(("transformers", errors))
    return [
        'In {} section of asset "{}": {}'.format(section, path, e)
        for section, errors in sections
        for e in errors
    ]

def _assets_errors(section, raw):
    # `_validateAssets`: `assets` and `shaders` are checked alike.
    if raw == None:
        return []
    if type(raw) != "list":
        return ['flutter.{}: Expected "{}" to be a list, but got {} ({}).'.format(section, section, _show(raw), _dart_type(raw))]
    return [
        "flutter.{}[{}]: {}".format(section, i, e)
        for i, entry in enumerate(raw)
        for e in _asset_entry_errors(entry)
    ]

def _font_family_errors(family):
    if type(family) != "dict":
        return ['Unexpected child "{}" found under "fonts". Expected a map.'.format(_show(family))]
    errors = [
        'Unexpected child "{}" found under "fonts".'.format(key)
        for key in family
        if key != "family" and key != "fonts"
    ]
    if family.get("family") != None and type(family["family"]) != "string":
        errors.append("Font family must either be null or a String.")
    files = family.get("fonts")
    if files == None:
        return errors
    if type(files) != "list":
        errors.append('Expected "fonts" to either be null or a list.')
        return errors
    for i, font in enumerate(files):
        where = "fonts[{}]: ".format(i)
        if type(font) != "dict":
            errors.append(where + 'Expected "fonts" to be a list of maps.')
            continue
        for key, value in font.items():
            shown = "{} (({}))".format(_show(value), _dart_type(value))
            if key == "asset":
                if type(value) != "string":
                    errors.append(where + "Expected font asset {} to be a string.".format(shown))
            elif key == "weight":
                if type(value) != "int" or value not in _FONT_WEIGHTS:
                    errors.append(where + "Invalid value {} for font -> weight.".format(shown))
            elif key == "style":
                if value != "normal" and value != "italic":
                    errors.append(where + "Invalid value {} for font -> style.".format(shown))
            else:
                errors.append(where + "Unexpected key {} under font.".format(key + " (" + _dart_type(value) + ")"))
    return errors

def _fonts_errors(flutter):
    if "fonts" not in flutter:
        return []
    raw = flutter["fonts"]
    if type(raw) != "list":
        return ['flutter.fonts: Expected "fonts" to be a list, but got {} ({}).'.format(_show(raw), _dart_type(raw))]
    if not raw:
        return []
    if type(raw[0]) != "dict":
        return ['flutter.fonts: Expected "fonts" to contain maps, but the first element is {} ({}).'.format(_show(raw[0]), _dart_type(raw[0]))]
    return [
        "flutter.fonts[{}]: {}".format(i, e)
        for i, family in enumerate(raw)
        for e in _font_family_errors(family)
    ]

_FLUTTER_KEYS = [
    "uses-material-design",
    "assets",
    "shaders",
    "fonts",
    "licenses",
    "module",
    "plugin",
    "generate",
    "config",
    "deferred-components",
    "default-flavor",
]

def _flutter_keys_errors(flutter):
    errors = []
    for key, value in flutter.items():
        if key == "uses-material-design":
            if type(value) != "bool":
                errors.append('flutter.{}: Expected "{}" to be a bool, but got {} ({}).'.format(key, key, _show(value), _dart_type(value)))
        elif key == "licenses":
            for e in _list_of_errors(value, '"licenses"', "files", _is_string):
                errors.append("flutter.licenses: " + e)
        elif key == "disable-swift-package-manager":
            errors.append(
                'flutter.{}: The "{}" configuration has moved. Set `config: enable-swift-package-manager: false` under `flutter:`.'.format(key, key),
            )
        elif key not in _FLUTTER_KEYS:
            errors.append('flutter.{}: Unexpected child "{}" found under "flutter".'.format(key, key))
    return errors

def flutter_manifest_errors(fields):
    """The entries of a pubspec's `flutter:` block that flutter_tools refuses.

    `flutter build` reads a pubspec with `FlutterManifest`, which refuses a
    manifest whose `flutter:` block has a key it does not know, or whose
    `uses-material-design`, `licenses`, `assets`, `shaders` or `fonts` are
    shaped wrongly. This finds the same entries, so that rules_flutter does
    not build a package that flutter_tools would not. (For a dependency
    flutter_tools reports the error and skips the package; failing is the
    safer reading of the same fact.)

    Args:
        fields: A pubspec's `fields`, as `read_pubspec` returns them.

    Returns:
        A list of strings, one per refusal, each leading with where the entry
        is (`flutter.assets[2]`) and then saying what flutter_tools says. Empty
        when flutter_tools accepts them.
    """
    raw = fields.get("flutter")
    if raw != None and type(raw) != "dict":
        return ['flutter: Expected "flutter" section to be an object or null, but got {}.'.format(_show(raw))]
    flutter = flutter_block(fields)
    return (
        _flutter_keys_errors(flutter) +
        _assets_errors("assets", flutter.get("assets")) +
        _assets_errors("shaders", flutter.get("shaders")) +
        _fonts_errors(flutter)
    )

def flutter_licenses_block(fields):
    """Project `flutter.licenses`, the licence files a package adds to `NOTICES`.

    Args:
        fields: A pubspec's `fields`, as `read_pubspec` returns them.

    Returns:
        The paths, relative to the package, in the order listed. A `licenses:`
        that is not a list of strings names none (`flutter_manifest_errors`
        refuses it before this is asked).
    """
    raw = flutter_block(fields).get("licenses")
    if type(raw) != "list":
        return []
    return [str(item) for item in raw]
