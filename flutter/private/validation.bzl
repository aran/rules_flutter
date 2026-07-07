"""Shared validation and sanitization helpers for Flutter rules."""

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

_VALID_WEB_COMPILER_RENDERER = {
    "dart2wasm": ["skwasm", "canvaskit"],
    "dart2js": ["canvaskit"],
}

def validate_web_compiler_renderer(compiler, renderer):
    """Validate that a web compiler+renderer combination is supported.

    Args:
        compiler: Web compiler ("dart2wasm" or "dart2js").
        renderer: Web renderer ("skwasm" or "canvaskit").
    """
    if not is_valid_web_compiler_renderer(compiler, renderer):
        fail("Invalid web compiler+renderer combination: %s+%s. skwasm requires dart2wasm." % (compiler, renderer))

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
# and flutter.dart_plugin_registrant names the generated registrant library
# the engine invokes before main(). User-supplied values would silently
# corrupt mode semantics or break plugin registration, so they are rejected
# up front — matching flutter_tools' own --dart-define policy.
RESERVED_DART_DEFINE_KEYS = ("dart.vm.profile", "dart.vm.product", "flutter.dart_plugin_registrant")

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
                 "these from the compilation mode)") % (define, what, ", ".join(RESERVED_DART_DEFINE_KEYS)),
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
