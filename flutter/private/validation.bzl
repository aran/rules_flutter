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

def escape_html(text):
    """Escape HTML special characters in a string.

    Args:
        text: The text string to escape.

    Returns:
        The escaped string safe for use in HTML attributes and content.
    """
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
