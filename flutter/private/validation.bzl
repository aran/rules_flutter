"""Shared validation and sanitization helpers for Flutter rules."""

load("//flutter/private:sdk_defines.bzl", "VERSION_DEFINE_KEYS")

visibility("//flutter/...")

def validate_bundle_id(bundle_id):
    """Validate that a bundle_id is a well-formed reverse-DNS identifier.

    Requires at least 2 dot-separated segments, no leading/trailing dots,
    no consecutive dots, and only alphanumeric, '.', and '-' characters.

    Args:
        bundle_id: The bundle identifier string to validate.
    """
    if not is_valid_bundle_id(bundle_id):
        fail(
            ("Invalid bundle_id %r: must have ≥2 dot-separated segments, " +
             "no leading/trailing/consecutive dots, and only alphanumeric, '.', '-' characters") % bundle_id,
        )

def is_valid_bundle_id(bundle_id):
    """Check if a bundle_id is a well-formed reverse-DNS identifier.

    Requires at least 2 dot-separated segments, no leading/trailing dots,
    no consecutive dots, and only alphanumeric, '.', and '-' characters.

    Args:
        bundle_id: The bundle identifier string to check.

    Returns:
        True if the bundle_id is valid, False otherwise.
    """
    if len(bundle_id) == 0:
        return False
    if bundle_id[0] == "." or bundle_id[-1] == ".":
        return False
    if ".." in bundle_id:
        return False
    if "." not in bundle_id:
        return False
    for c in bundle_id.elems():
        if not (c.isalpha() or c.isdigit() or c in ".-"):
            return False
    return True

# Swift keywords that cannot be used bare as a module name. `import <keyword>`
# and `<keyword>.SomeClass` both fail to parse, so a target so named would
# produce a runner that cannot be imported or referenced from an Info.plist.
_SWIFT_RESERVED_MODULE_NAMES = (
    "associatedtype",
    "class",
    "deinit",
    "enum",
    "extension",
    "fileprivate",
    "func",
    "import",
    "init",
    "inout",
    "internal",
    "let",
    "open",
    "operator",
    "private",
    "precedencegroup",
    "protocol",
    "public",
    "rethrows",
    "static",
    "struct",
    "subscript",
    "typealias",
    "var",
    "break",
    "case",
    "catch",
    "continue",
    "default",
    "defer",
    "do",
    "else",
    "fallthrough",
    "for",
    "guard",
    "if",
    "in",
    "repeat",
    "return",
    "throw",
    "switch",
    "where",
    "while",
    "as",
    "Any",
    "false",
    "is",
    "nil",
    "self",
    "Self",
    "super",
    "throws",
    "true",
    "try",
)

def validate_swift_module_name(module_name, what):
    """Validate that a string can be used verbatim as a Swift module name.

    Args:
        module_name: The candidate module name.
        what: Description of where the name came from, used in the failure
            message (e.g. "flutter_macos_app(name = ...)").
    """
    if not is_valid_swift_module_name(module_name):
        fail(
            ("%s: %r cannot be used as a Swift module name. Apple's NIB and " +
             "Info.plist class lookups spell classes as <module>.<Class>, so " +
             "the module name must be a bare Swift identifier: a letter or " +
             "'_' followed by letters, digits or '_', and not a Swift " +
             "keyword. Rename the target.") % (what, module_name),
        )

def is_valid_swift_module_name(module_name):
    """Check if a string is a bare Swift identifier usable as a module name.

    Args:
        module_name: The candidate module name.

    Returns:
        True if the name is a valid Swift module name, False otherwise.
    """
    if len(module_name) == 0:
        return False
    if module_name in _SWIFT_RESERVED_MODULE_NAMES:
        return False
    first = module_name[0]
    if not (first.isalpha() or first == "_"):
        return False
    for c in module_name.elems():
        if not (c.isalpha() or c.isdigit() or c == "_"):
            return False
    return True

_VALID_WEB_COMPILER_RENDERER = {
    "dart2wasm": ["skwasm", "canvaskit"],
    "dart2js": ["canvaskit"],
}

def web_renderer(compiler, renderer):
    """The renderer a web target uses: the one it names, else its compiler's.

    dart2js can only render with CanvasKit, so naming it is not required;
    dart2wasm defaults to skwasm, as `flutter build web --wasm` does.

    Args:
        compiler: Web compiler ("dart2wasm" or "dart2js").
        renderer: The `renderer` attribute; empty when unset.

    Returns:
        "skwasm" or "canvaskit".
    """
    if renderer:
        return renderer
    return "canvaskit" if compiler == "dart2js" else "skwasm"

def validate_web_compiler_renderer(compiler, renderer):
    """Validate that a web compiler+renderer combination is supported.

    Args:
        compiler: Web compiler ("dart2wasm" or "dart2js").
        renderer: Web renderer ("skwasm" or "canvaskit").
    """
    if not is_valid_web_compiler_renderer(compiler, renderer):
        fail("Invalid web compiler+renderer combination: %s+%s. skwasm requires dart2wasm." % (compiler, renderer))

def validate_web_wasm_only_attrs(compiler, set_attrs, what):
    """Refuse wasm-only settings on a target that runs no wasm compile.

    `compiler = "dart2js"` runs no wasm compile at all, so a wasm-only setting
    there would be accepted and reach nothing.

    Args:
        compiler: The target's `compiler` attr value.
        set_attrs: Names of wasm-only attrs the target set away from their
            defaults. Determined by the caller, which is where the values are.
        what: Label named in the failure message.
    """
    if compiler != "dart2js" or not set_attrs:
        return
    fail(
        "%s: %s only affect%s the WASM compile, and `compiler = \"dart2js\"` " % (
            what,
            ", ".join(sorted(set_attrs)),
            "" if len(set_attrs) > 1 else "s",
        ) +
        "runs none. Drop the setting, or switch to `compiler = \"dart2wasm\"`.",
    )

def validate_web_js_only_attrs(compiler, js_fallback, set_attrs, what):
    """Refuse dart2js-only settings on a target that runs no dart2js compile.

    `compiler = "dart2wasm"` runs dart2js for the fallback build unless
    `js_fallback = False` turns it off, and then a dart2js-only setting reaches
    nothing: it would be accepted and silently ignored.

    Args:
        compiler: The target's `compiler` attr value.
        js_fallback: The target's `js_fallback` attr value.
        set_attrs: Names of dart2js-only attrs the target set away from their
            defaults. Determined by the caller, which is where the values are.
        what: Label named in the failure message.
    """
    if compiler == "dart2js" or js_fallback or not set_attrs:
        return
    fail(
        "%s: %s only affect%s the dart2js compile, and `compiler = \"dart2wasm\"` " % (
            what,
            ", ".join(sorted(set_attrs)),
            "" if len(set_attrs) > 1 else "s",
        ) +
        "with `js_fallback = False` runs none. Drop the setting, drop " +
        "`js_fallback = False`, or switch to `compiler = \"dart2js\"`.",
    )

def validate_web_js_fallback(compiler, js_fallback, what):
    """Refuse `js_fallback = False` where the whole build is JavaScript.

    `js_fallback` defaults to True, so it can only be told apart from unset
    when it is False. `compiler = "dart2js"` has no WASM build for a JS one to
    back up, and asking for no JS build beside it contradicts it.

    Args:
        compiler: The target's `compiler` attr value.
        js_fallback: The target's `js_fallback` attr value.
        what: Label named in the failure message.
    """
    if compiler == "dart2js" and not js_fallback:
        fail(
            "%s: `js_fallback = False` asks for no JavaScript build beside the WASM " % what +
            "one, and `compiler = \"dart2js\"` is JavaScript alone. Drop `js_fallback`, " +
            "or switch to `compiler = \"dart2wasm\"`.",
        )

# The browser engines flutter.js knows, as its `BrowserEngine` type names them
# (`flutter_js/src/types.d.ts`) and as its `wasmAllowList` is keyed. `blink` is
# Chromium (Chrome, Edge), `gecko` Firefox, `webkit` Safari; `unknown` is what
# an engine flutter.js cannot classify reports.
WASM_BROWSER_ENGINES = ["blink", "gecko", "webkit", "unknown"]

def validate_wasm_browsers(wasm_browsers, compiler, renderer, has_own_bootstrap, what):
    """Validate the `wasm_browsers` allow-list against the target it is set on.

    Args:
        wasm_browsers: The target's `wasm_browsers` attr value.
        compiler: The target's compiler ("dart2wasm" or "dart2js").
        renderer: The renderer the target resolves to ("skwasm" or "canvaskit").
        has_own_bootstrap: Whether the target supplies its own `bootstrap_js`.
        what: Label named in the failure message.
    """
    if not wasm_browsers:
        return
    unknown = [b for b in wasm_browsers if b not in WASM_BROWSER_ENGINES]
    if unknown:
        fail("%s: wasm_browsers names %s, which flutter.js does not know. Its engines are %s." % (
            what,
            ", ".join([repr(b) for b in unknown]),
            ", ".join(WASM_BROWSER_ENGINES),
        ))
    if compiler != "dart2wasm" or renderer != "skwasm":
        fail(
            "%s: wasm_browsers decides which browser engines may run the skwasm " % what +
            "renderer, and this target (compiler = %r, renderer = %r) has none, " % (compiler, renderer) +
            "so the setting would reach nothing. Drop it.",
        )
    if has_own_bootstrap:
        fail(
            "%s: wasm_browsers is written into the generated flutter_bootstrap.js, and this " % what +
            "target supplies its own `bootstrap_js`, which calls `_flutter.loader.load` itself. " +
            "Drop the attr and pass `config: {wasmAllowList: {...}}` there.",
        )

def wasm_allow_list_property(wasm_browsers):
    """The `config` property of the `_flutter.loader.load` argument.

    Every engine flutter.js knows is stated, so the allow-list is exactly the
    engines named: one left out is refused, even where Flutter's own default
    would have allowed it.

    Args:
        wasm_browsers: Engines allowed to run skwasm; empty for Flutter's default.

    Returns:
        A JS object property, or the empty string when nothing is set.
    """
    if not wasm_browsers:
        return ""
    allow_list = {engine: engine in wasm_browsers for engine in WASM_BROWSER_ENGINES}
    return "config: {\n        wasmAllowList: %s\n      }" % json.encode(allow_list)

# The renderer files flutter.js loads for each renderer, by path under the web
# SDK's `canvaskit/`. A skwasm build loads `skwasm.*`, `skwasm_heavy.*` (a
# browser without image codecs or Chromium's break iterators) and `wimp.*`
# (`enableWimp`), single-threaded or not: there is no skwasm-to-CanvasKit
# fallback in the loader. A CanvasKit build loads `canvaskit.*` and the
# `chromium/` and `webparagraph/` variants beside it.
_SKWASM_FILE_PREFIXES = ["skwasm", "wimp."]
_CANVASKIT_FILE_PREFIXES = ["canvaskit.", "chromium/", "webparagraph/"]

def renderer_file_needed(rel, renderers):
    """Whether a file under the web SDK's `canvaskit/` serves any of `renderers`.

    A file this does not recognise is kept: shipping an extra one costs bytes,
    dropping a needed one is a blank page.

    Args:
        rel: Path relative to the `canvaskit/` directory.
        renderers: Renderers the bundle's builds (and dev loop) render with.

    Returns:
        True when the file should be bundled.
    """
    for prefix in _SKWASM_FILE_PREFIXES:
        if rel.startswith(prefix):
            return "skwasm" in renderers
    for prefix in _CANVASKIT_FILE_PREFIXES:
        if rel.startswith(prefix):
            return "canvaskit" in renderers
    return True

def validate_base_href(base_href, what):
    """Validate a web `<base href>` value.

    Same rule `flutter build web --base-href` enforces: relative URLs on the
    page resolve against everything up to the last `/`, so a value missing
    either slash silently resolves assets somewhere other than the deploy root
    — a page that works when served from `/` and breaks on a deep link.

    Args:
        base_href: The value to check.
        what: Label or attr named in the failure message.
    """
    if not base_href.startswith("/") or not base_href.endswith("/"):
        fail("%s: base_href must start and end with '/', got %r" % (what, base_href))

def validate_static_assets_url(static_assets_url, what):
    """Validate a web `$FLUTTER_STATIC_ASSETS_URL` value.

    Same rule `flutter build web --static-assets-url` enforces: only a trailing
    slash, because the value is a URL prefix that may legitimately name another
    origin.

    Args:
        static_assets_url: The value to check.
        what: Label or attr named in the failure message.
    """
    if not static_assets_url.endswith("/"):
        fail("%s: static_assets_url must end with '/', got %r" % (what, static_assets_url))

def is_valid_web_compiler_renderer(compiler, renderer):
    """Check if a web compiler+renderer combination is supported.

    Args:
        compiler: Web compiler ("dart2wasm" or "dart2js").
        renderer: Web renderer ("skwasm" or "canvaskit").

    Returns:
        True if the combination is valid, False otherwise.
    """
    allowed = _VALID_WEB_COMPILER_RENDERER.get(compiler)
    if allowed == None:
        return False
    return renderer in allowed

# Define keys the ruleset sets itself: the dart.vm.* mode keys come from the
# compilation mode (see flutter_compile_kernel and the web compile actions),
# flutter.dart_plugin_registrant names the generated registrant library the
# engine invokes before main(), and FLUTTER_APP_FLAVOR is what `appFlavor`
# reads, set from the target's `flavor`, and FLUTTER_BUILD_NAME,
# FLUTTER_BUILD_NUMBER and the FlutterVersion keys (`VERSION_DEFINE_KEYS`) are
# what `appBuildName` and `FlutterVersion` read, set from the target's
# `build_name` and `build_number` and the toolchain's release. User-supplied
# values would silently corrupt mode semantics, break plugin registration or
# disagree with the target, so they are rejected up front — matching
# flutter_tools' own --dart-define policy.
RESERVED_DART_DEFINE_KEYS = ("dart.vm.profile", "dart.vm.product", "flutter.dart_plugin_registrant", "FLUTTER_APP_FLAVOR") + VERSION_DEFINE_KEYS

def validate_dart_defines(defines, what):
    """Validate a list of Dart environment defines (KEY=VALUE strings).

    Args:
        defines: List of define strings to validate.
        what: Description of where the defines came from, used in the
            failure message (e.g. a target label or a flag name).
    """
    for define in defines:
        if not is_valid_dart_define(define):
            fail(
                ("Invalid Dart define %r in %s: defines must be non-empty " +
                 "and must not set the reserved keys %s (the build sets " +
                 "these itself: the dart.vm.* keys from the compilation mode, " +
                 "FLUTTER_APP_FLAVOR from `flavor`, FLUTTER_BUILD_NAME and " +
                 "FLUTTER_BUILD_NUMBER from `build_name` and `build_number`, the " +
                 "FlutterVersion ones from the Flutter release, and " +
                 "flutter.dart_plugin_registrant for the plugin registrant)") % (define, what, ", ".join(RESERVED_DART_DEFINE_KEYS)),
            )

def is_valid_dart_define(define):
    """Check if a Dart environment define is acceptable.

    Args:
        define: A define string, normally KEY=VALUE (a bare KEY is treated
            as a key with no value, matching frontend_server -D semantics).

    Returns:
        True if the define is valid, False otherwise.
    """
    if len(define) == 0:
        return False
    return define.split("=", 1)[0] not in RESERVED_DART_DEFINE_KEYS

def escape_html(text):
    """Escape HTML special characters in a string.

    Args:
        text: The text string to escape.

    Returns:
        The escaped string safe for use in HTML attributes and content.
    """
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

def validate_minimum_os_version(macro, name, value, floor, platform):
    """Fail when a deployment target is below what the vended engine can serve.

    The engine is a prebuilt framework with a minimum of its own, and a bundle
    cannot honour one below it — the link warns, and the app is left claiming
    an OS the engine it loads was never built to run on. Failing here names the
    rule, the attribute and the floor, where the linker's warning names none of
    them and arrives once per consumer forever.

    Args:
        macro: The macro's name, for the message.
        name: The target's name, for the message.
        value: The caller's `minimum_os_version`.
        floor: The vended engine's own minimum — see `constants.bzl`.
        platform: "iOS" or "macOS", for the message.
    """
    if not minimum_os_version_is_below(value, floor):
        return
    fail(
        ("%s(name = %r): minimum_os_version = %r is below %s %s, which is " +
         "what the prebuilt engine these rules vend is built for. A lower " +
         "deployment target does not widen the audience — the bundle would " +
         "claim an OS the engine cannot run on. Pass %r or higher.") % (
            macro,
            name,
            value,
            platform,
            floor,
            floor,
        ),
    )

def minimum_os_version_is_below(value, floor):
    """Whether deployment target [value] is lower than [floor].

    Compared segment by segment rather than as text: "10.9" is above "10.14"
    by string order and below it by version order, and macOS spent years in
    exactly that range.

    Args:
        value: A version like "15.0".
        floor: A version like "15.0".

    Returns:
        True if [value] is below [floor].
    """
    return _version_parts(value) < _version_parts(floor)

def _version_parts(value):
    """`"15.0"` as a comparable list. Fails on anything that is not a version."""
    numbers = []
    for part in value.split("."):
        if not part.isdigit():
            fail("%r is not a version, so it cannot be a deployment target." % value)
        numbers.append(int(part))

    # Padded so "15" and "15.0" compare equal rather than by length.
    return numbers + [0] * (3 - len(numbers))
