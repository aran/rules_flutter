"""Parse pub package pubspec.yaml `flutter:` block metadata.

YAML parsing itself delegates to `@yaml.bzl//:yaml.bzl`. This module projects
the parsed value down to the shapes rules_flutter consumes:

- `parse_flutter_plugin_block` — `flutter.plugin` for plugin-spoke emission.
- `parse_flutter_assets_block` — `flutter.{fonts,assets,shaders,uses-material-design}`
  for the asset-bundling pipeline.

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
      shaders:
        - <path>
      plugin:
        implements: <umbrella>
        platforms:
          <platform>:
            pluginClass: <Class>
            ...
"""

load("@yaml.bzl//:yaml.bzl", "yaml")

def parse_pubspec(content):
    """Parse pubspec.yaml content into a Starlark dict.

    Args:
        content: Full pubspec.yaml content as a string.

    Returns:
        Native dict (possibly empty) of the parsed pubspec, or empty dict on
        non-mapping root / parser errors. Errors are not surfaced — callers
        that need strict behavior should validate fields themselves.
    """
    if not content.strip():
        return {}
    doc = yaml.parse(content)
    if yaml.has_errors(doc):
        return {}
    data = yaml.get_value(doc)
    return data if type(data) == "dict" else {}

def parse_flutter_block(content):
    """Return the `flutter:` sub-dict, or empty dict when absent."""
    pubspec = parse_pubspec(content)
    flutter = pubspec.get("flutter")
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

def parse_flutter_plugin_block(content):
    """Parse `flutter.plugin` out of a pubspec.yaml string.

    Args:
        content: Full pubspec.yaml content as a string.

    Returns:
        A struct with:
            present: bool — True iff a `flutter.plugin` block exists.
            platforms: dict of `<platform> -> dict[key, value]`. Empty dict
                when no `platforms:` key is present.
            implements: str — value of `flutter.plugin.implements` or `""`.
            ffi_plugin: bool — value of `flutter.plugin.ffiPlugin` or False.
    """
    flutter = parse_flutter_block(content)
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

def _parse_fonts(raw):
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

def _parse_assets(raw):
    if type(raw) != "list":
        return []
    out = []
    for entry in raw:
        if type(entry) == "string":
            out.append(struct(path = entry, flavors = [], platforms = []))
            continue
        if type(entry) != "dict":
            continue
        path = entry.get("path")
        if type(path) != "string":
            continue
        flavors_raw = entry.get("flavors", [])
        platforms_raw = entry.get("platforms", [])
        out.append(struct(
            path = path,
            flavors = [str(f) for f in flavors_raw] if type(flavors_raw) == "list" else [],
            platforms = [str(p) for p in platforms_raw] if type(platforms_raw) == "list" else [],
        ))
    return out

def _parse_shaders(raw):
    if type(raw) != "list":
        return []
    out = []
    for entry in raw:
        if type(entry) == "string":
            out.append(struct(path = entry))
            continue
        if type(entry) == "dict":
            path = entry.get("path")
            if type(path) == "string":
                out.append(struct(path = path))
    return out

def parse_flutter_assets_block(content):
    """Parse `flutter.fonts`, `flutter.assets`, `flutter.shaders`, and `flutter.uses-material-design`.

    Args:
        content: Full pubspec.yaml content as a string.

    Returns:
        struct(
            fonts:    list[struct(family, fonts=list[struct(asset, weight, style)])],
            assets:   list[struct(path, flavors, platforms)],
            shaders:  list[struct(path)],
            uses_material_design: bool,
        )

    `weight` and `style` on a font are None when unset. `flavors`/`platforms`
    are captured from modern-shape asset entries but are not yet acted on by
    the asset bundler — they are out-of-scope for v1.
    """
    flutter = parse_flutter_block(content)
    umd_raw = flutter.get("uses-material-design", False)
    return struct(
        fonts = _parse_fonts(flutter.get("fonts")),
        assets = _parse_assets(flutter.get("assets")),
        shaders = _parse_shaders(flutter.get("shaders")),
        uses_material_design = umd_raw if type(umd_raw) == "bool" else False,
    )
