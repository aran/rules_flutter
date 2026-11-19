"""A local Maven repository for a Gradle build that runs offline.

Downloads every file a lock names, each checked against its SHA-256, into the
Maven layout Gradle reads from a `maven { url = ... }` repository. The lock is
written by a run of the same Gradle build against the remote repositories (see
`//:record_gradle_host_repository`), so it holds exactly what that build
resolves: POMs, Gradle module metadata, jars and AARs.
"""

def _gradle_offline_repository_impl(rctx):
    lock = json.decode(rctx.read(rctx.attr.lock))
    pending = [
        rctx.download(
            url = entry["url"],
            output = path,
            sha256 = entry["sha256"],
            block = False,
        )
        for path, entry in lock["files"].items()
    ]
    for download in pending:
        download.wait()
    rctx.file("REPO.bazel", "")
    rctx.file("BUILD.bazel", """\
# The repository's files, at their Maven paths under this repository's root.
filegroup(
    name = "files",
    srcs = glob(["**"], exclude = ["BUILD.bazel", "REPO.bazel"]),
    visibility = ["//visibility:public"],
)
""")

gradle_offline_repository = repository_rule(
    implementation = _gradle_offline_repository_impl,
    attrs = {
        "lock": attr.label(
            mandatory = True,
            allow_single_file = [".json"],
            doc = "A JSON object whose `files` maps each Maven path to its `url` and `sha256`.",
        ),
    },
    doc = "Downloads the files of a lock into a local Maven repository, `:files`.",
)
