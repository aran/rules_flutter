"""Red-path repo rules exercising the pinned-download helpers offline.

Each rule fetches one committed fixture file through a `file://` URL — no
network — via `pinned_download` / `pinned_download_and_extract`. The
offline digest red paths (e2e/digest_mismatch) instantiate one repo per
digest shape (correct, empty, malformed, conditionally blanked, wrong);
CI fetches each separately and greps the exact failure message (or the
fetched bytes, for the correct digests).
"""

load(":download.bzl", "pinned_download", "pinned_download_and_extract")

def _fixture_url(repository_ctx):
    return "file://" + str(repository_ctx.path(repository_ctx.attr.fixture))

def _digest_download_impl(repository_ctx):
    pinned_download(
        repository_ctx,
        url = _fixture_url(repository_ctx),
        sha256 = repository_ctx.attr.sha256,
        output = "fetched.bin",
    )
    repository_ctx.file("BUILD.bazel", 'exports_files(["fetched.bin"])\n')

digest_download = repository_rule(
    implementation = _digest_download_impl,
    attrs = {
        "fixture": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Fixture file to fetch through a file:// URL.",
        ),
        "sha256": attr.string(
            mandatory = True,
            doc = "Expected digest; empty or malformed values must fail the fetch.",
        ),
    },
)

def _digest_extract_impl(repository_ctx):
    pinned_download_and_extract(
        repository_ctx,
        url = _fixture_url(repository_ctx),
        sha256 = repository_ctx.attr.sha256,
    )
    repository_ctx.file("BUILD.bazel", 'exports_files(glob(["**"]))\n')

digest_extract = repository_rule(
    implementation = _digest_extract_impl,
    attrs = {
        "fixture": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Fixture archive to fetch through a file:// URL.",
        ),
        "sha256": attr.string(
            mandatory = True,
            doc = "Expected digest; empty or malformed values must fail the fetch.",
        ),
    },
)
