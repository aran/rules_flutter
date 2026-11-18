"""Font families, as targets: what a pubspec's `flutter: fonts:` declares.

    flutter_font(name = "inter_bold", src = "fonts/Inter-Bold.ttf", weight = 700)
    flutter_font_family(
        name = "inter",
        family = "Inter",
        fonts = [":inter_bold", "fonts/Inter-Regular.ttf"],
    )
    flutter_library(name = "ui", fonts = [":inter"], ...)

A `flutter_font_family` is one entry of `fonts:`, and each of its `fonts` one
`asset:` of it. A plain file stands for a font with no weight and no style; a
`flutter_font` gives one either. The library, plugin or pub package that lists
the family bundles its fonts, keyed by their path from that package's root as
every other asset of the package is.
"""

load("//flutter:providers.bzl", "FlutterFontFamilyInfo", "FlutterFontInfo")

visibility("//flutter/...")

# What flutter_tools accepts for `weight:` and `style:` (flutter_manifest.dart).
_WEIGHTS = [100, 200, 300, 400, 500, 600, 700, 800, 900]
_STYLES = ["normal", "italic"]

def _other_package_asset(label, asset):
    """`asset` checked as `packages/<package>/<path>`, or None when it is empty."""
    if not asset:
        return None
    parts = asset.split("/", 2)
    if len(parts) < 3 or parts[0] != "packages" or not parts[1] or not parts[2]:
        fail("%s: `asset` is %s; it names a font of another package as `packages/<package>/<path>`." % (label, repr(asset)))
    return asset

def _flutter_font_impl(ctx):
    return [
        DefaultInfo(files = depset([ctx.file.src])),
        FlutterFontInfo(
            file = ctx.file.src,
            weight = ctx.attr.weight or None,
            style = ctx.attr.style or None,
            asset = _other_package_asset(ctx.label, ctx.attr.asset),
        ),
    ]

flutter_font = rule(
    implementation = _flutter_font_impl,
    attrs = {
        "src": attr.label(
            doc = "The font file: `asset:` of a pubspec's font.",
            allow_single_file = True,
            mandatory = True,
        ),
        "weight": attr.int(
            doc = "`weight:`: 100 to 900, in steps of 100. 0, the default, gives the font none.",
            values = [0] + _WEIGHTS,
        ),
        "style": attr.string(
            doc = "`style:`: `normal` or `italic`. Empty, the default, gives the font none.",
            values = [""] + _STYLES,
        ),
        "asset": attr.string(
            doc = "For a font of another Dart package, the `packages/<package>/<path>` a pubspec's `asset:` names it by: `src` is the file `<path>` of that package's `lib/`, as flutter_tools reads it, and every program bundles it at this path, the family's own package included. Unset, `src` is a file of the package that lists the family, keyed by its path from that package's root.",
        ),
    },
    doc = "A font file of a `flutter_font_family`, with its weight and style.",
)

def _flutter_font_family_impl(ctx):
    fonts = []
    for target in ctx.attr.fonts:
        if FlutterFontInfo in target:
            fonts.append(target[FlutterFontInfo])
            continue
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("%s: `fonts` entry %s is %d files; a font is one file, or a `flutter_font`." % (ctx.label, target.label, len(files)))
        fonts.append(FlutterFontInfo(file = files[0], weight = None, style = None, asset = None))
    return [
        DefaultInfo(files = depset([font.file for font in fonts])),
        FlutterFontFamilyInfo(family = ctx.attr.family or ctx.label.name, fonts = tuple(fonts)),
    ]

flutter_font_family = rule(
    implementation = _flutter_font_family_impl,
    attrs = {
        "family": attr.string(
            doc = "`family:`, the name `TextStyle.fontFamily` selects it by. Defaults to the target's name.",
        ),
        "fonts": attr.label_list(
            doc = "Its fonts, in order: `flutter_font` targets, or font files, each of which is a font with no weight and no style.",
            allow_files = True,
            allow_empty = False,
            mandatory = True,
        ),
    },
    doc = "A font family, as an entry of a pubspec's `flutter: fonts:` declares it. List it in the `fonts` of the `flutter_library` or `flutter_plugin` whose package it is.",
)

FONTS_ATTR = attr.label_list(
    doc = "The package's font families (`flutter_font_family`), as its pubspec's `flutter: fonts:` declares them. A program of another package bundles each family as `packages/<package_name>/<family>` and each font at `packages/<package_name>/<path>`, its path from the package root; a program of this package (its own `flutter_test`, or the application whose code this is) keeps both bare, as `flutter build` does. A font of another package keeps its `asset` path in every program.",
    providers = [FlutterFontFamilyInfo],
)
