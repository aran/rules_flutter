"""A repository holding one Flutter SDK package's files, and nothing generated.

A Flutter SDK package other than `package:flutter` (`flutter_test`,
`integration_test`, ...) is `packages/<name>` of the pinned Flutter source. Its
source repository (`flutter_pub_package`) generates its build from
rules_flutter's and rules_dart's Starlark, so the cache key Bazel stores that
repository under changes with every edit to that Starlark. Were the package's
files stored in it, Bazel's repository contents cache would keep another copy
of them for each. So they are extracted into a repository of their own, defined
here with only the fetching code loaded, which the source repository links in
with rules_dart's `link_pub_files`, as it does a hosted or git package's
(`pub_archive_files`, `pub_git_files`).

Keep this file's loads to the fetching code: each `.bzl` it loads is part of
the key of every such package's files.
"""

load("@rules_dart//dart/pub:pub_files_root.bzl", "write_pub_files_root")
load("//flutter/private:artifact_urls.bzl", "flutter_source_tarball_url")
load("//flutter/private:pinned.bzl", "pinned")

visibility("//flutter/...")

def missing_sdk_package_message(name, version):
    """What a build of a Flutter release says of a lock's SDK package the release does not have."""
    return (
        "pubspec.lock lists `{name}` from the Flutter SDK, but Flutter {version}'s " +
        "source has no packages/{name}; re-resolve the lock with the pinned " +
        "toolchain (`bazel run @rules_flutter//flutter/pub -- get`)."
    ).format(name = name, version = version)

def _flutter_source_files_impl(rctx):
    # The tarball is the one every consumer of the framework source fetches,
    # pinned to the same digest, so Bazel's repository cache serves it to all
    # of them from one download. Only the one package is extracted, straight
    # to the root. Extracting a prefix the archive lacks fails with a message
    # about archive prefixes that names neither the package nor the lock, and
    # a failed extraction cannot be caught, so the package is first looked up
    # in `packages`, the release's own list of them.
    name = rctx.attr.package_name
    version = rctx.attr.flutter_version
    if not rctx.attr.packages:
        fail((
            "flutter_source_files `{name}` has `flutter_version` {version} " +
            "but no `packages`, so it cannot tell whether the source has packages/{name}."
        ).format(name = name, version = version))
    if name not in rctx.attr.packages:
        # The pub extension declares no files repository for a package its
        # SDK does not have, so that only a build of that SDK fails.
        fail(missing_sdk_package_message(name, version))
    rctx.download_and_extract(
        url = flutter_source_tarball_url(version),
        sha256 = pinned(version + ".tar.gz", rctx.attr.sha256),
        stripPrefix = "flutter-{}/packages/{}".format(version, name),
    )

    # The root's marker and the file whose load `link_pub_files` returns, so
    # Bazel sets this repository up before the links are read through, as in
    # a vendored build.
    write_pub_files_root(rctx)
    return rctx.repo_metadata(reproducible = True)

flutter_source_files = repository_rule(
    implementation = _flutter_source_files_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The package under `packages/` of the Flutter source.",
            mandatory = True,
        ),
        "flutter_version": attr.string(
            doc = "The Flutter version whose pinned source tarball holds the package.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "The recorded digest of that tarball (`flutter_source_sha256`).",
            mandatory = True,
        ),
        "packages": attr.string_list(
            doc = "The packages under `packages/` of that source (`flutter_sdk_packages`). A `package_name` " +
                  "not among them fails the fetch, before anything is downloaded, saying to re-resolve the lock.",
            mandatory = True,
        ),
    },
    doc = "Extracts `packages/<package_name>` of the pinned Flutter source, for `flutter_pub_package` to link in.",
)
