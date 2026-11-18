"""The one place a repository rule's download digest is checked.

An empty `sha256` is not an error to Bazel; it means "do not check". A digest it
cannot parse is only found after the whole archive has been fetched. Every
download in rules_flutter's repository rules therefore passes its digest
through `pinned`, which refuses a missing or malformed one before any request
is made, naming the artifact:

    repository_ctx.download_and_extract(
        url = ...,
        sha256 = pinned("sky_engine.zip", repository_ctx.attr.sha256),
    )

`//tools/download_guard` reads the sources and fails on a download whose digest
can still be empty.
"""

visibility("//flutter/...")

_HEX = "0123456789abcdef"

def digest_problem(sha256):
    """Why `sha256` cannot be a pinned digest, or None if it can.

    Args:
        sha256: The value a download would pass as its `sha256`.

    Returns:
        A short reason, or None for exactly 64 lowercase hex characters.
    """
    if type(sha256) != "string":
        return "it is not a string"
    if not sha256:
        return "it is empty"
    if len(sha256) != 64:
        return "it is {} characters, not 64".format(len(sha256))
    for c in sha256.elems():
        if c not in _HEX:
            return "it has a character that is not lowercase hex"
    return None

def pinned(artifact, sha256):
    """Returns `sha256` if it is a usable digest; otherwise fails the fetch.

    Args:
        artifact: What is being downloaded, for the message (an artifact path,
            a package name).
        sha256: The digest the caller has for it.

    Returns:
        `sha256`, unchanged.
    """
    problem = digest_problem(sha256)
    if problem:
        fail(("No usable sha256 is pinned for {artifact}: {problem} ({value}). " +
              "Every download is checked against a pinned 64-character lowercase hex " +
              "SHA-256, so this fetch is refused before any request is made.").format(
            artifact = artifact,
            problem = problem,
            value = repr(sha256),
        ))
    return sha256
