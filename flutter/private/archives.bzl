"""Declares a `flutter_archive_repo` from Starlark values.

The rule takes only plain attributes, so that its cache key does not move with
the Starlark that computes them (`archive_repo.bzl`). This is the side that may
load anything.
"""

load(":archive_repo.bzl", "flutter_archive_repo")

visibility("//flutter/...")

def archive(artifact, url, sha256, output = "", strip_prefix = "", type = ""):
    """One archive for `archive_repo` to extract.

    Args:
        artifact: The archive's name, for the message when `sha256` is unusable.
        url: Where to download it.
        sha256: Its pinned digest, checked when the repository is fetched.
        output: The directory to extract it into.
        strip_prefix: A directory prefix to strip.
        type: The archive's type, when its URL does not say.

    Returns:
        A dict for `archive_repo`'s `archives`.
    """
    entry = {"artifact": artifact, "url": url, "sha256": sha256}
    if output:
        entry["output"] = output
    if strip_prefix:
        entry["strip_prefix"] = strip_prefix
    if type:
        entry["type"] = type
    return entry

def archive_repo(name, archives, files, nested_archives = {}, checks = []):
    """Declares a repository of extracted archives and the files beside them.

    Args:
        name: The repository's name.
        archives: The archives to extract, in order, each from `archive`.
        files: Path to content of each file to write after the archives.
        nested_archives: An archive in the repository to the directory to
            extract it into, in place of itself.
        checks: Checks of what was extracted, each a dict with `path` and
            `message`, and with `content` (the file's stripped text, which
            `message` may name as `{actual}`) or without (the path must exist).
    """
    flutter_archive_repo(
        name = name,
        archives = json.encode(archives),
        checks = json.encode(checks),
        files = files,
        nested_archives = nested_archives,
    )
