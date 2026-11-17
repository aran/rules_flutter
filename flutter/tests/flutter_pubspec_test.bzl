"""Unit tests for the projection of a pubspec's `flutter:` block (flutter_pubspec.bzl).

The inputs are `fields` dicts, as rules_dart's `read_pubspec` returns them:
the pubspec document as JSON values. Reading a pubspec (YAML, and pub's own
refusals) is `read_pubspec`'s, and is tested where a repository rule runs it:
`tools/dev_tool/test/e2e/pubspec_reading_e2e_test.dart`.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pubspec.bzl",
    "flutter_assets_block",
    "flutter_block",
    "flutter_licenses_block",
    "flutter_manifest_errors",
    "flutter_plugin_block",
)

# Federated umbrella: only default_package per platform, no plugin classes
# (path_provider).
_PATH_PROVIDER = {
    "name": "path_provider",
    "version": "2.1.5",
    "environment": {"sdk": "^3.0.0"},
    "flutter": {
        "plugin": {
            "platforms": {
                "android": {"default_package": "path_provider_android"},
                "ios": {"default_package": "path_provider_foundation"},
                "linux": {"default_package": "path_provider_linux"},
                "macos": {"default_package": "path_provider_foundation"},
                "windows": {"default_package": "path_provider_windows"},
            },
        },
    },
    "dependencies": {"flutter": {"sdk": "flutter"}},
}

# Federated implementation: implements + dartPluginClass on its platform
# (path_provider_foundation).
_PATH_PROVIDER_FOUNDATION = {
    "name": "path_provider_foundation",
    "flutter": {
        "plugin": {
            "implements": "path_provider",
            "platforms": {
                "ios": {"dartPluginClass": "PathProviderFoundation"},
                "macos": {"dartPluginClass": "PathProviderFoundation"},
            },
        },
    },
    "dependencies": {"flutter": {"sdk": "flutter"}},
}

# Monolithic plugin: direct platforms with pluginClass / dartPluginClass /
# package / fileName, no implements/default_package (package_info_plus).
_PACKAGE_INFO_PLUS = {
    "name": "package_info_plus",
    "environment": {"sdk": ">=3.4.0 <4.0.0", "flutter": ">=3.22.0"},
    "flutter": {
        "plugin": {
            "platforms": {
                "android": {
                    "package": "dev.fluttercommunity.plus.packageinfo",
                    "pluginClass": "PackageInfoPlugin",
                },
                "ios": {"pluginClass": "FPPPackageInfoPlusPlugin"},
                "linux": {"dartPluginClass": "PackageInfoPlusLinuxPlugin"},
                "macos": {"pluginClass": "FPPPackageInfoPlusPlugin"},
                "web": {
                    "pluginClass": "PackageInfoPlusWebPlugin",
                    "fileName": "src/package_info_plus_web.dart",
                },
                "windows": {"dartPluginClass": "PackageInfoPlusWindowsPlugin"},
            },
        },
    },
}

# Federated impl with both pluginClass and dartPluginClass + fileName
# (url_launcher_macos).
_URL_LAUNCHER_MACOS = {
    "name": "url_launcher_macos",
    "flutter": {
        "plugin": {
            "implements": "url_launcher",
            "platforms": {
                "macos": {
                    "pluginClass": "UrlLauncherPlugin",
                    "fileName": "url_launcher_macos.dart",
                    "dartPluginClass": "UrlLauncherMacOS",
                },
            },
        },
    },
}

# Non-plugin package (path_provider_platform_interface).
_NO_PLUGIN = {
    "name": "path_provider_platform_interface",
    "dependencies": {
        "flutter": {"sdk": "flutter"},
        "plugin_platform_interface": "^2.1.0",
    },
}

# cupertino_icons: flutter.fonts only.
_CUPERTINO_ICONS = {
    "name": "cupertino_icons",
    "version": "1.0.9",
    "flutter": {
        "fonts": [{
            "family": "CupertinoIcons",
            "fonts": [{"asset": "assets/CupertinoIcons.ttf"}],
        }],
    },
}

# Hypothetical font with weight + style attributes.
_FONT_WITH_VARIANTS = {
    "name": "example",
    "flutter": {
        "fonts": [{
            "family": "Roboto",
            "fonts": [
                {"asset": "fonts/Roboto-Regular.ttf"},
                {"asset": "fonts/Roboto-Bold.ttf", "weight": 700},
                {"asset": "fonts/Roboto-Italic.ttf", "weight": 400, "style": "italic"},
            ],
        }],
    },
}

# Asset-shipping package (flutter_localized_locales-style).
_LOCALES = {
    "name": "flutter_localized_locales",
    "flutter": {"assets": ["data/"]},
}

# Modern map-form assets with flavors + platforms.
_MAP_FORM_ASSETS = {
    "name": "example",
    "flutter": {
        "assets": [
            {
                "path": "assets/foo.png",
                "flavors": ["prod"],
                "platforms": ["ios", "android"],
            },
            "assets/bar.png",
        ],
    },
}

# Shaders + material design flag.
_MATERIAL_AND_SHADERS = {
    "name": "example",
    "flutter": {
        "uses-material-design": True,
        "shaders": [
            "shaders/ink_sparkle.frag",
            {"path": "shaders/web_only.frag", "platforms": ["web"]},
            {"path": "shaders/paid.frag", "flavors": ["paid", "premium"]},
        ],
    },
}

# ---------------------------------------------------------------------------
# flutter_plugin_block
# ---------------------------------------------------------------------------

def _umbrella_default_package_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block(_PATH_PROVIDER)
    asserts.true(env, result.present)
    asserts.equals(env, "", result.implements)
    asserts.equals(env, False, result.ffi_plugin)
    asserts.equals(env, 5, len(result.platforms))
    asserts.equals(env, "path_provider_android", result.platforms["android"]["default_package"])
    asserts.equals(env, "path_provider_foundation", result.platforms["macos"]["default_package"])
    asserts.equals(env, "path_provider_windows", result.platforms["windows"]["default_package"])

    asserts.true(env, "pluginClass" not in result.platforms["macos"])
    asserts.true(env, "dartPluginClass" not in result.platforms["macos"])
    return unittest.end(env)

def _federated_impl_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block(_PATH_PROVIDER_FOUNDATION)
    asserts.true(env, result.present)
    asserts.equals(env, "path_provider", result.implements)
    asserts.equals(env, 2, len(result.platforms))
    asserts.equals(env, "PathProviderFoundation", result.platforms["macos"]["dartPluginClass"])
    asserts.equals(env, "PathProviderFoundation", result.platforms["ios"]["dartPluginClass"])

    asserts.true(env, "default_package" not in result.platforms["macos"])
    return unittest.end(env)

def _monolithic_plugin_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block(_PACKAGE_INFO_PLUS)
    asserts.true(env, result.present)
    asserts.equals(env, "", result.implements)
    asserts.equals(env, 6, len(result.platforms))

    asserts.equals(env, "dev.fluttercommunity.plus.packageinfo", result.platforms["android"]["package"])
    asserts.equals(env, "PackageInfoPlugin", result.platforms["android"]["pluginClass"])

    asserts.equals(env, "FPPPackageInfoPlusPlugin", result.platforms["ios"]["pluginClass"])

    asserts.equals(env, "PackageInfoPlusLinuxPlugin", result.platforms["linux"]["dartPluginClass"])
    asserts.equals(env, "PackageInfoPlusWindowsPlugin", result.platforms["windows"]["dartPluginClass"])

    asserts.equals(env, "PackageInfoPlusWebPlugin", result.platforms["web"]["pluginClass"])
    asserts.equals(env, "src/package_info_plus_web.dart", result.platforms["web"]["fileName"])
    return unittest.end(env)

def _impl_with_filename_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block(_URL_LAUNCHER_MACOS)
    asserts.true(env, result.present)
    asserts.equals(env, "url_launcher", result.implements)
    macos = result.platforms["macos"]
    asserts.equals(env, "UrlLauncherPlugin", macos["pluginClass"])
    asserts.equals(env, "url_launcher_macos.dart", macos["fileName"])
    asserts.equals(env, "UrlLauncherMacOS", macos["dartPluginClass"])
    return unittest.end(env)

def _no_plugin_block_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block(_NO_PLUGIN)
    asserts.equals(env, False, result.present)
    asserts.equals(env, 0, len(result.platforms))
    asserts.equals(env, "", result.implements)
    return unittest.end(env)

def _empty_pubspec_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block({})
    asserts.equals(env, False, result.present)
    asserts.equals(env, 0, len(result.platforms))
    return unittest.end(env)

# ---------------------------------------------------------------------------
# flutter_assets_block
# ---------------------------------------------------------------------------

def _cupertino_fonts_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block(_CUPERTINO_ICONS)
    asserts.equals(env, 1, len(result.fonts))
    asserts.equals(env, "CupertinoIcons", result.fonts[0].family)
    asserts.equals(env, 1, len(result.fonts[0].fonts))
    asserts.equals(env, "assets/CupertinoIcons.ttf", result.fonts[0].fonts[0].asset)
    asserts.equals(env, None, result.fonts[0].fonts[0].weight)
    asserts.equals(env, None, result.fonts[0].fonts[0].style)
    asserts.equals(env, [], result.assets)
    asserts.equals(env, [], result.shaders)
    asserts.equals(env, False, result.uses_material_design)
    return unittest.end(env)

def _font_variants_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block(_FONT_WITH_VARIANTS)
    asserts.equals(env, 1, len(result.fonts))
    family = result.fonts[0]
    asserts.equals(env, "Roboto", family.family)
    asserts.equals(env, 3, len(family.fonts))

    asserts.equals(env, "fonts/Roboto-Regular.ttf", family.fonts[0].asset)
    asserts.equals(env, None, family.fonts[0].weight)
    asserts.equals(env, None, family.fonts[0].style)

    asserts.equals(env, "fonts/Roboto-Bold.ttf", family.fonts[1].asset)
    asserts.equals(env, 700, family.fonts[1].weight)
    asserts.equals(env, None, family.fonts[1].style)

    asserts.equals(env, "fonts/Roboto-Italic.ttf", family.fonts[2].asset)
    asserts.equals(env, 400, family.fonts[2].weight)
    asserts.equals(env, "italic", family.fonts[2].style)
    return unittest.end(env)

def _string_assets_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block(_LOCALES)
    asserts.equals(env, 1, len(result.assets))
    asserts.equals(env, "data/", result.assets[0].path)
    asserts.equals(env, [], result.assets[0].flavors)
    asserts.equals(env, [], result.assets[0].platforms)
    return unittest.end(env)

def _map_assets_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block(_MAP_FORM_ASSETS)
    asserts.equals(env, 2, len(result.assets))

    asserts.equals(env, "assets/foo.png", result.assets[0].path)
    asserts.equals(env, ["prod"], result.assets[0].flavors)
    asserts.equals(env, ["ios", "android"], result.assets[0].platforms)

    asserts.equals(env, "assets/bar.png", result.assets[1].path)
    asserts.equals(env, [], result.assets[1].flavors)
    asserts.equals(env, [], result.assets[1].platforms)
    return unittest.end(env)

def _shaders_and_material_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block(_MATERIAL_AND_SHADERS)
    asserts.equals(env, True, result.uses_material_design)
    asserts.equals(env, 3, len(result.shaders))
    asserts.equals(env, "shaders/ink_sparkle.frag", result.shaders[0].path)
    asserts.equals(env, [], result.shaders[0].platforms)
    asserts.equals(env, [], result.shaders[0].flavors)

    # The map form carries the restrictions flutter_tools applies to a shader
    # as it does to an asset.
    asserts.equals(env, ["web"], result.shaders[1].platforms)
    asserts.equals(env, ["paid", "premium"], result.shaders[2].flavors)
    return unittest.end(env)

def _empty_flutter_block_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block({"name": "foo"})
    asserts.equals(env, [], result.fonts)
    asserts.equals(env, [], result.assets)
    asserts.equals(env, [], result.shaders)
    asserts.equals(env, False, result.uses_material_design)
    return unittest.end(env)

# ---------------------------------------------------------------------------
# flutter_block
# ---------------------------------------------------------------------------

def _flutter_block_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, "plugin" in flutter_block(_PATH_PROVIDER))
    asserts.equals(env, {}, flutter_block({}))
    asserts.equals(env, {}, flutter_block(_NO_PLUGIN))

    # A `flutter:` that is not a mapping is no block.
    asserts.equals(env, {}, flutter_block({"flutter": None}))
    asserts.equals(env, {}, flutter_block({"flutter": ["plugin"]}))
    return unittest.end(env)

_t0_test = unittest.make(_umbrella_default_package_test_impl)
_t1_test = unittest.make(_federated_impl_test_impl)
_t2_test = unittest.make(_monolithic_plugin_test_impl)
_t3_test = unittest.make(_impl_with_filename_test_impl)
_t4_test = unittest.make(_no_plugin_block_test_impl)
_t5_test = unittest.make(_empty_pubspec_test_impl)
_t6_test = unittest.make(_cupertino_fonts_test_impl)
_t7_test = unittest.make(_font_variants_test_impl)
_t8_test = unittest.make(_string_assets_test_impl)
_t9_test = unittest.make(_map_assets_test_impl)
_t10_test = unittest.make(_shaders_and_material_test_impl)
_t11_test = unittest.make(_empty_flutter_block_test_impl)
_t12_test = unittest.make(_flutter_block_test_impl)

def _asset_transformers_test_impl(ctx):
    env = unittest.begin(ctx)
    assets = flutter_assets_block({
        "name": "p",
        "flutter": {
            "assets": [
                "assets/plain.txt",
                {"path": "assets/map.txt"},
                {
                    "path": "assets/svg.svg",
                    "transformers": [{
                        "package": "vector_graphics_compiler",
                        "args": ["--tessellate"],
                    }],
                },
            ],
        },
    }).assets
    asserts.equals(env, [False, False, True], [bool(a.transformers) for a in assets])

    # flutter_tools runs a shader's transformers on its source before compiling
    # it, so a shader entry's are read too, for the fetch to refuse.
    shaders = flutter_assets_block({
        "name": "p",
        "flutter": {
            "shaders": [
                "shaders/plain.frag",
                {"path": "shaders/map.frag"},
                {"path": "shaders/t.frag", "transformers": [{"package": "shader_preprocessor"}]},
            ],
        },
    }).shaders
    asserts.equals(env, [False, False, True], [bool(s.transformers) for s in shaders])
    return unittest.end(env)

_asset_transformers_test = unittest.make(_asset_transformers_test_impl)

# ---------------------------------------------------------------------------
# flutter_licenses_block
# ---------------------------------------------------------------------------

# A pubspec whose `flutter:` block has the `licenses:` key set to `value`. The
# key is pubspec's, not an attribute of a rule, which the linter takes it for.
def _pubspec_with_licenses(value):
    # buildifier: disable=attr-licenses
    return {"flutter": {"licenses": value}}

def _licenses_listed_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["THIRD_PARTY.txt", "licenses/other"],
        flutter_licenses_block(_pubspec_with_licenses(["THIRD_PARTY.txt", "licenses/other"])),
    )

    return unittest.end(env)

_licenses_listed_test = unittest.make(_licenses_listed_test_impl)

def _licenses_absent_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], flutter_licenses_block({"name": "foo"}))
    asserts.equals(env, [], flutter_licenses_block({"flutter": {}}))
    asserts.equals(env, [], flutter_licenses_block(_pubspec_with_licenses("LICENSE")))
    return unittest.end(env)

_licenses_absent_test = unittest.make(_licenses_absent_test_impl)

# ---------------------------------------------------------------------------
# flutter_manifest_errors: what flutter_tools' manifest validation refuses
# ---------------------------------------------------------------------------

def _flutter(**section):
    return {"flutter": section}

# One input per refusal in flutter_manifest.dart's `_validate` for `assets`,
# `shaders` and `fonts`, with a phrase flutter_tools' message has.
_REFUSED = [
    ("assets not a list", _flutter(assets = "a.txt"), 'Expected "assets" to be a list'),
    ("shaders not a list", _flutter(shaders = {"path": "a.frag"}), 'Expected "shaders" to be a list'),
    ("null asset entry", _flutter(assets = [None]), "null or empty uri"),
    ("empty asset entry", _flutter(assets = [""]), "null or empty uri"),
    ("number asset entry", _flutter(assets = [7]), "unexpected shape"),
    ("list asset entry", _flutter(assets = [["a"]]), "unexpected shape"),
    ("bool shader entry", _flutter(shaders = [True]), "unexpected shape"),
    ("asset map without path", _flutter(assets = [{"flavors": ["x"]}]), 'containing a "path" entry'),
    ("asset map with a non-string path", _flutter(assets = [{"path": 3}]), 'containing a "path" entry'),
    ("shader map without path", _flutter(shaders = [{"platforms": ["ios"]}]), 'containing a "path" entry'),
    ("flavors not a list", _flutter(assets = [{"path": "a", "flavors": "x"}]), 'In flavors section of asset "a"'),
    ("flavor not a string", _flutter(assets = [{"path": "a", "flavors": [1]}]), "element at index 0 was a int"),
    ("platforms not a list", _flutter(assets = [{"path": "a", "platforms": "ios"}]), 'In platforms section of asset "a"'),
    ("platform not a string", _flutter(shaders = [{"path": "a", "platforms": [None]}]), "element at index 0 was a Null"),
    ("unknown platform", _flutter(assets = [{"path": "a", "platforms": ["ios", "fuchsia"]}]), 'Invalid platform(s): "fuchsia"'),
    ("transformers not a list", _flutter(assets = [{"path": "a", "transformers": {"package": "t"}}]), "transformers list to be a list of Map"),
    ("transformer not a map", _flutter(assets = [{"path": "a", "transformers": ["t"]}]), "element at index 0 was a String"),
    ("transformer without package", _flutter(assets = [{"path": "a", "transformers": [{"args": []}]}]), 'Expected "package" to be a String'),
    ("transformer with an empty package", _flutter(assets = [{"path": "a", "transformers": [{"package": ""}]}]), 'Expected "package" to be a String'),
    ("transformer args not a list", _flutter(assets = [{"path": "a", "transformers": [{"package": "t", "args": "x"}]}]), 'In args section of transformer using package "t"'),
    ("transformer arg not a string", _flutter(assets = [{"path": "a", "transformers": [{"package": "t", "args": [1]}]}]), "element at index 0 was a int"),
    ("fonts not a list", _flutter(fonts = {"family": "F"}), 'Expected "fonts" to be a list'),
    ("fonts null", _flutter(fonts = None), 'Expected "fonts" to be a list'),
    ("fonts starting with a non-map", _flutter(fonts = ["F"]), "to contain maps"),
    ("a later family that is not a map", _flutter(fonts = [{"family": "F"}, "G"]), 'Unexpected child "G" found under "fonts"'),
    ("a family key flutter does not know", _flutter(fonts = [{"family": "F", "style": "italic"}]), 'Unexpected child "style" found under "fonts"'),
    ("a family that is not a string", _flutter(fonts = [{"family": 3}]), "Font family must either be null or a String"),
    ("a family's fonts not a list", _flutter(fonts = [{"family": "F", "fonts": "f.ttf"}]), 'Expected "fonts" to either be null or a list'),
    ("a font that is not a map", _flutter(fonts = [{"family": "F", "fonts": ["f.ttf"]}]), 'Expected "fonts" to be a list of maps'),
    ("a font asset that is not a string", _flutter(fonts = [{"family": "F", "fonts": [{"asset": 3}]}]), "Expected font asset 3"),
    ("a font asset that is null", _flutter(fonts = [{"family": "F", "fonts": [{"asset": None}]}]), "Expected font asset null"),
    ("a weight that is not a CSS weight", _flutter(fonts = [{"family": "F", "fonts": [{"asset": "f", "weight": 450}]}]), "Invalid value 450"),
    ("a weight that is a string", _flutter(fonts = [{"family": "F", "fonts": [{"asset": "f", "weight": "bold"}]}]), "for font -> weight"),
    ("a style that is not normal or italic", _flutter(fonts = [{"family": "F", "fonts": [{"asset": "f", "style": "oblique"}]}]), "for font -> style"),
    ("a font key flutter does not know", _flutter(fonts = [{"family": "F", "fonts": [{"asset": "f", "size": 1}]}]), "Unexpected key size"),
    ("uses-material-design a string", _flutter(**{"uses-material-design": "yes"}), 'Expected "uses-material-design" to be a bool'),
    ("uses-material-design null", _flutter(**{"uses-material-design": None}), 'Expected "uses-material-design" to be a bool'),
    ("licenses a string", _flutter(licenses = "LICENSE"), 'Expected "licenses" to be a list of files'),
    ("licenses null", _flutter(licenses = None), 'Expected "licenses" to be a list of files'),
    ("a license that is not a string", _flutter(licenses = ["LICENSE", 7]), "element at index 1 was a int"),
    ("a key under flutter flutter does not know", _flutter(colour = "red"), 'Unexpected child "colour" found under "flutter"'),
    ("disable-swift-package-manager", _flutter(**{"disable-swift-package-manager": True}), "has moved"),
    ("flutter that is not a map", {"flutter": ["assets"]}, 'Expected "flutter" section to be an object or null'),
    ("asset uri with a scheme that starts with a digit", _flutter(assets = ["1a:b"]), "invalid uri: 1a:b"),
    ("asset uri with an empty scheme", _flutter(assets = [":a"]), "invalid uri"),
    ("asset uri with an illegal scheme character", _flutter(assets = ["a b:c"]), "invalid uri"),
    ("asset uri with a bad port", _flutter(assets = ["http://h:xx/"]), "invalid uri"),
    ("asset uri with an unclosed host bracket", _flutter(shaders = ["http://[::1/"]), "invalid uri"),
    ("asset uri with two userinfo separators", _flutter(assets = ["//a@b@c/"]), "invalid uri"),
]

def _assets_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    for name, fields, mention in _REFUSED:
        errors = flutter_manifest_errors(fields)
        asserts.true(env, len(errors) > 0, "{} should be refused".format(name))
        asserts.true(
            env,
            any([mention in e for e in errors]),
            "{}: expected an error with {}, got {}".format(name, repr(mention), errors),
        )
    return unittest.end(env)

_assets_refused_test = unittest.make(_assets_refused_test_impl)

def _assets_error_places_the_entry_test_impl(ctx):
    env = unittest.begin(ctx)
    errors = flutter_manifest_errors(_flutter(assets = ["ok.txt", {"path": "b", "platforms": ["beos"]}]))
    asserts.equals(env, 1, len(errors))
    asserts.true(env, errors[0].startswith("flutter.assets[1]: "), errors[0])
    errors = flutter_manifest_errors(_flutter(fonts = [{"family": "F", "fonts": [{"asset": "a"}, {"asset": "b", "weight": 1}]}]))
    asserts.true(env, errors[0].startswith("flutter.fonts[0]: fonts[1]: "), errors[0])
    return unittest.end(env)

_assets_error_places_the_entry_test = unittest.make(_assets_error_places_the_entry_test_impl)

# Every form flutter_tools accepts, including the odd ones.
_ACCEPTED = [
    ("no flutter block", {"name": "p"}),
    ("a flutter block that is null", {"flutter": None}),
    ("empty sections", _flutter(assets = None, shaders = None, fonts = [])),
    ("string assets", _flutter(assets = ["a.txt", "dir/"], shaders = ["s.frag"])),
    # buildifier: disable=attr-licenses
    ("every key flutter knows", _flutter(**{
        "uses-material-design": True,
        "licenses": ["LICENSE"],
        "generate": True,
        "config": {"x": 1},
        "default-flavor": "f",
        "module": {"androidX": True},
        "plugin": {"platforms": {}},
        "deferred-components": [],
    })),
    ("uris Dart parses", _flutter(
        assets = ["a b", "%zz", "a:b", "a/b:c", "assets/a?b#c", "x://", "http://h:80/x", "//[::1]:80/", "//u:p@h/", "é.png"],
    )),
    ("an empty map asset", _flutter(assets = [{}], shaders = [{}])),
    ("map assets with every key", _flutter(assets = [{
        "path": "a",
        "flavors": ["x"],
        "platforms": ["android", "ios", "web", "windows", "linux", "macos"],
        "transformers": [{"package": "t"}, {"package": "u", "args": ["--x"]}],
    }], shaders = [{"path": "s", "flavors": [], "platforms": ["ios"]}])),
    ("a family with no fonts", _flutter(fonts = [{"family": "F"}, {"family": "G", "fonts": None}])),
    ("a family that is null", _flutter(fonts = [{"fonts": [{"asset": "f"}]}, {"family": None}])),
    ("a font with no asset", _flutter(fonts = [{"family": "F", "fonts": [{"weight": 400}]}])),
    ("every weight and style", _flutter(fonts = [{"family": "F", "fonts": [
        {"asset": "f%d" % w, "weight": w, "style": style}
        for w in [100, 200, 300, 400, 500, 600, 700, 800, 900]
        for style in ["normal", "italic"]
    ]}])),
]

def _assets_accepted_test_impl(ctx):
    env = unittest.begin(ctx)
    for name, fields in _ACCEPTED:
        asserts.equals(env, [], flutter_manifest_errors(fields), name)
    return unittest.end(env)

_assets_accepted_test = unittest.make(_assets_accepted_test_impl)

# ---------------------------------------------------------------------------
# A desktop Dart class flutter_tools does not register
# ---------------------------------------------------------------------------

def _self_implementing(flutter_constraint = None, implements = None, default_package = None):
    macos = {"dartPluginClass": "SelfMacOS", "dartFileName": "src/self_macos.dart", "pluginClass": "SelfPlugin"}
    if default_package:
        macos["default_package"] = default_package
    plugin = {"platforms": {
        "android": {"dartPluginClass": "SelfAndroid"},
        "macos": macos,
        "linux": {"dartPluginClass": "SelfLinux"},
    }}
    if implements:
        plugin["implements"] = implements
    fields = {"name": "self", "flutter": {"plugin": plugin}}
    if flutter_constraint != None:
        fields["environment"] = {"sdk": "^3.0.0", "flutter": flutter_constraint}
    return fields

def _desktop_dart_self_implementation_test_impl(ctx):
    """flutter_tools takes a package's own desktop Dart class only when it requires Flutter 2.11 or later (`_isEligibleDartSelfImpl`)."""
    env = unittest.begin(ctx)
    for constraint in [None, "any", "<4.0.0", ">=2.10.0", ">=2.11.0-0", "^1.20.0", ">=2.11.0 || >=3.0.0", "not a constraint"]:
        platforms = flutter_plugin_block(_self_implementing(constraint)).platforms
        asserts.equals(env, {"pluginClass": "SelfPlugin"}, platforms["macos"], "macOS's Dart class is not taken under %r" % constraint)
        asserts.equals(env, {}, platforms["linux"], "nor Linux's, under %r" % constraint)
        asserts.equals(env, "SelfAndroid", platforms["android"]["dartPluginClass"], "a mobile platform's is, under %r" % constraint)
    for constraint in [">=2.11.0", "^3.0.0", ">2.11.0", ">= 3.0.0 <4.0.0", "3.22.0", ">=2.11.0+1"]:
        platforms = flutter_plugin_block(_self_implementing(constraint)).platforms
        asserts.equals(env, "SelfMacOS", platforms["macos"]["dartPluginClass"], "macOS's Dart class is taken under %r" % constraint)
        asserts.equals(env, "src/self_macos.dart", platforms["macos"]["dartFileName"])
        asserts.equals(env, "SelfLinux", platforms["linux"]["dartPluginClass"], "and Linux's, under %r" % constraint)

    # A package that implements another is that one's implementation, however
    # old the Flutter it requires.
    platforms = flutter_plugin_block(_self_implementing(implements = "other")).platforms
    asserts.equals(env, "SelfMacOS", platforms["macos"]["dartPluginClass"])

    # Beside a `default_package` the class stays, for flutter_tools to refuse.
    platforms = flutter_plugin_block(_self_implementing(default_package = "self_macos")).platforms
    asserts.equals(env, "SelfMacOS", platforms["macos"]["dartPluginClass"])
    return unittest.end(env)

_desktop_dart_self_implementation_test = unittest.make(_desktop_dart_self_implementation_test_impl)

def flutter_pubspec_test_suite(name):
    unittest.suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
        _t12_test,
        _asset_transformers_test,
        _licenses_listed_test,
        _licenses_absent_test,
        _assets_refused_test,
        _assets_error_places_the_entry_test,
        _assets_accepted_test,
        _desktop_dart_self_implementation_test,
    )
