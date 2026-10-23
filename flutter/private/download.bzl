"""Fail-closed download helpers: every fetch in flutter/** runs through these.

A repository rule or module extension calls `pinned_download` /
`pinned_download_and_extract` exactly like `ctx.download` /
`ctx.download_and_extract` (same keyword arguments, same return value),
except the digest is mandatory and validated twice:

1. The call fails before any fetch unless `sha256` is exactly 64 lowercase
   hex characters. An empty, malformed, or conditionally-blanked digest
   (`sha256 = x if cond else ""`) therefore fails closed with a message that
   names the URL, instead of fetching unverified bytes.
2. The digest is passed to Bazel, whose own checksum comparison fails the
   fetch when the bytes hash differently. `pinned_download` additionally
   compares the digest Bazel reports for the fetched bytes against `sha256`,
   so a scheme Bazel does not verify (today every scheme is verified, but
   that is Bazel's choice) still fails closed here.

`kwargs` may not smuggle `sha256` or `integrity` past the check: either key
fails the fetch. Do not special-case call sites; keep this file small.
"""

_HEX_DIGITS = "0123456789abcdef"

def _describe_url(kwargs):
    url = kwargs.get("url", "")
    if type(url) == "list":
        url = ", ".join([str(u) for u in url])
    return str(url)

def _check_pinned_sha256(sha256, url, what):
    """Fails unless `sha256` is exactly 64 lowercase hex characters."""
    if type(sha256) == "string" and len(sha256) == 64:
        valid = True
        for c in sha256.elems():
            if c not in _HEX_DIGITS:
                valid = False
                break
        if valid:
            return
    fail((
        "{what}: refusing to fetch '{url}': sha256 must be exactly 64 " +
        "lowercase hex characters, got '{got}'"
    ).format(what = what, url = url, got = sha256))

def _check_no_smuggled_digest(kwargs, url, what):
    for key in ["sha256", "integrity"]:
        if key in kwargs:
            fail((
                "{what}: refusing to fetch '{url}': pass the digest as " +
                "sha256 = ..., not as '{key}' inside extra arguments"
            ).format(what = what, url = url, key = key))

def pinned_download(ctx, *, sha256, **kwargs):
    """Fetches one file like `ctx.download`, failing closed on a bad digest.

    Args:
        ctx: A repository_ctx or module_ctx to fetch with.
        sha256: The expected SHA-256 hex digest; must be exactly 64
            lowercase hex characters.
        **kwargs: Passed through to `ctx.download` (`url`, `output`, ...).

    Returns:
        Whatever `ctx.download` returns.
    """
    url = _describe_url(kwargs)
    _check_no_smuggled_digest(kwargs, url, "pinned_download")
    _check_pinned_sha256(sha256, url, "pinned_download")
    result = ctx.download(sha256 = sha256, **kwargs)
    if result.sha256 != sha256:
        fail((
            "pinned_download: checksum mismatch fetching '{url}': " +
            "checksum was {actual} but wanted {want}"
        ).format(url = url, actual = result.sha256, want = sha256))
    return result

def pinned_download_and_extract(ctx, *, sha256, **kwargs):
    """Fetches and extracts an archive like `ctx.download_and_extract`.

    Args:
        ctx: A repository_ctx or module_ctx to fetch with.
        sha256: The expected SHA-256 hex digest; must be exactly 64
            lowercase hex characters.
        **kwargs: Passed through to `ctx.download_and_extract` (`url`,
            `output`, `stripPrefix`, `type`, ...).

    Returns:
        Whatever `ctx.download_and_extract` returns.
    """
    url = _describe_url(kwargs)
    _check_no_smuggled_digest(kwargs, url, "pinned_download_and_extract")
    _check_pinned_sha256(sha256, url, "pinned_download_and_extract")
    return ctx.download_and_extract(sha256 = sha256, **kwargs)
