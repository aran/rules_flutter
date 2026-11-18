"""The repository rule that holds downloaded engine artifacts.

Bazel's repository contents cache keys a repository by its attributes and the
`.bzl` files its rule loads. An engine artifact is tens to hundreds of MB (the
host tools some 800 MB), so a rule loading the rest of rules_flutter's Starlark
would store another copy for every edit to it, every worktree and every
override. Everything a repository holds besides its archives is therefore
computed by the function that declares it and passed here as attributes.

Keep this file's loads to `pinned.bzl`, which loads nothing: each one is part of
the key of every repository this rule makes.
"""

load("//flutter/private:pinned.bzl", "pinned")

visibility("//flutter/...")

def _flutter_archive_repo_impl(repository_ctx):
    attr = repository_ctx.attr
    for archive in json.decode(attr.archives):
        repository_ctx.download_and_extract(
            url = archive["url"],
            sha256 = pinned(archive["artifact"], archive["sha256"]),
            output = archive.get("output", ""),
            stripPrefix = archive.get("strip_prefix", ""),
            type = archive.get("type", ""),
        )

    # An archive inside an archive (the macOS engine's framework), extracted
    # in place of itself.
    for archive, output in attr.nested_archives.items():
        repository_ctx.extract(archive = archive, output = output)
        repository_ctx.delete(archive)

    for check in json.decode(attr.checks):
        path = repository_ctx.path(check["path"])
        if "content" not in check:
            if not path.exists:
                fail(check["message"])
        else:
            actual = repository_ctx.read(path).strip()
            if actual != check["content"]:
                fail(check["message"].format(actual = actual))

    for path, content in attr.files.items():
        repository_ctx.file(path, content)

    # Pinned downloads and files given as attributes, so Bazel keeps one copy
    # in its repository contents cache for every output base.
    return repository_ctx.repo_metadata(reproducible = True)

flutter_archive_repo = repository_rule(
    _flutter_archive_repo_impl,
    doc = "Downloads and extracts pinned archives, and writes the given files beside them.",
    attrs = {
        "archives": attr.string(
            doc = "A JSON list of the archives to extract, in order, each an object with " +
                  "`artifact` (its name, for messages), `url`, `sha256`, and optionally " +
                  "`output`, `strip_prefix` and `type`.",
            mandatory = True,
        ),
        "checks": attr.string(
            doc = "A JSON list of checks of the extracted files, each an object with `path` " +
                  "and `message`. With `content`, the file's stripped text must equal it, and " +
                  "`message` is formatted with `actual`; without, the path must exist.",
            default = "[]",
        ),
        "files": attr.string_dict(doc = "Path to the content of a file to write, after the archives."),
        "nested_archives": attr.string_dict(
            doc = "An archive in the repository to the directory to extract it into; it is deleted after.",
        ),
    },
)
