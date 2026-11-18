"""Tests of what a pub package repository `flutter_pub_package` writes says it was fetched as.

A package's fetched identity is on the package metadata its targets name, as
rules_dart's `pub` states it for the same lock entry: a hosted or git
package's `pkg:pub` purl, or the directory a path package is built from. A
program reaching both fetchers' copies of one archive, commit or directory
takes them for one package. A purl is also stated through Bazel's supply-chain
metadata, as rules_dart's repositories state it: a `package_metadata` target,
which the repository's `REPO.bazel` attaches to every target in it. The unit
tests show what the BUILD files it writes contain; the analysis test, that a
program reaching both fetchers' copies of packages really fetched builds. That
a fetched package carries the purl of its lock entry in its `package_metadata`
is `fetched_purls_test`'s (`purls.bzl`).
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "make_package_metadata_content", "pub_git_identity", "pub_git_purl", "pub_hosted_purl", "pub_package_identity", "pub_path_identity")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "make_dart_member_build_content",
    "make_flutter_member_build_content",
    "package_fetched",
)

_SHA = "d0481093c50b1da8910eb0bb301626d4d8eb7284aa739614d2b394ee09e3ea04"
_COMMIT = "0123456789abcdef0123456789abcdef01234567"

def _identity_target(purl):
    return '''
package_metadata(
    name = "package-metadata",
    purl = "%s",
    visibility = ["//visibility:public"],
)
''' % purl

def _members_state_their_purl_test_impl(ctx):
    env = unittest.begin(ctx)
    purls = [
        pub_hosted_purl("args", "2.7.0", _SHA),
        pub_git_purl("args", "2.7.0", "https://example.com/args.git", _COMMIT, "pkgs/args"),
    ]
    for purl in purls:
        dart = make_dart_member_build_content("args", "3.4", [], "", version = "2.7.0", fetched_identity = purl)
        flutter = make_flutter_member_build_content("args", "3.4", [], "", version = "2.7.0", fetched_identity = purl, plugin_platforms = {"web": {"pluginClass": "WebPlugin"}})
        for content in [dart, flutter]:
            asserts.true(env, _identity_target(purl) in content, content)

            # Every load comes before the first target.
            asserts.true(env, content.rfind("\nload(") < content.find("\npackage_metadata("), content)
    asserts.equals(env, 'repo(default_package_metadata = ["//:package-metadata"])\n', pub_package_identity(purls[0]).repo_file)
    return unittest.end(env)

def _members_are_fetched_as_rules_dart_states_it_test_impl(ctx):
    """A member's package metadata is rules_dart's for the same lock entry."""
    env = unittest.begin(ctx)
    for identity in [
        pub_hosted_purl("args", "2.7.0", _SHA),
        pub_git_purl("args", "2.7.0", "https://example.com/args.git", _COMMIT, "pkgs/args"),
        pub_path_identity(Label("//app:pubspec.lock"), "../packages/args"),
    ]:
        # What rules_dart's `pub` declares the package with, fetched alike.
        stated = make_package_metadata_content("args", "3.4", version = "2.7.0", fetched_identity = identity)
        asserts.true(env, ('fetched_identity = "%s",' % identity) in stated, stated)
        dart = make_dart_member_build_content("args", "3.4", [], "", version = "2.7.0", fetched_identity = identity)
        flutter = make_flutter_member_build_content("args", "3.4", [], "", version = "2.7.0", fetched_identity = identity, plugin_platforms = {"web": {"pluginClass": "WebPlugin"}})
        for content in [dart, flutter]:
            asserts.true(env, stated in content, content)
            asserts.true(env, "dart_package_metadata(" not in content, content)
            asserts.true(env, pub_package_identity(identity).loads in content, content)
    return unittest.end(env)

def _path_members_state_no_purl_test_impl(ctx):
    """A directory is no purl: a path member states no `package_metadata`, as rules_dart's do."""
    env = unittest.begin(ctx)
    identity = pub_path_identity(Label("//app:pubspec.lock"), "../packages/args")
    asserts.equals(env, "@@//packages/args", identity)
    asserts.equals(env, "", pub_package_identity(identity).repo_file)
    for content in [
        make_dart_member_build_content("args", "3.4", [], "", version = "2.7.0", fetched_identity = identity),
        make_flutter_member_build_content("args", "3.4", [], "", version = "2.7.0", fetched_identity = identity),
    ]:
        asserts.true(env, "\npackage_metadata(" not in content and "rules/package_metadata.bzl" not in content, content)
    return unittest.end(env)

def _fetched_identity_follows_what_was_fetched_test_impl(ctx):
    """A package repository states what its files repository fetched, or for a path package its directory."""
    env = unittest.begin(ctx)

    def attr(**kwargs):
        fields = dict(package_name = "args", version = "", directory = "", path_identity = "")
        fields.update(kwargs)
        return struct(**fields)

    # A hosted or git package: what `pub_files_fetched` read, never facts
    # passed beside the files.
    hosted = struct(package_name = "args", version = "2.7.0", fetched_identity = pub_hosted_purl("args", "2.7.0", _SHA), purl = "")
    package = package_fetched(attr(), hosted)
    asserts.equals(env, "2.7.0", package.version)
    asserts.equals(env, hosted.fetched_identity, package.fetched_identity)
    asserts.equals(env, "", package.purl)
    lock = Label("//app:pubspec.lock")
    relative = struct(
        package_name = "args",
        version = "2.7.0",
        fetched_identity = pub_git_identity("args", "2.7.0", "../shared", _COMMIT, "pkgs/args", lock),
        purl = pub_git_purl("args", "2.7.0", "../shared", _COMMIT, "pkgs/args"),
    )
    package = package_fetched(attr(), relative)
    asserts.equals(env, relative.fetched_identity, package.fetched_identity)
    asserts.equals(env, relative.purl, package.purl)

    # A path package: the directory it is built from, at the lock's version.
    package = package_fetched(attr(version = "2.7.0", directory = "/abs/packages/args", path_identity = "@@//packages/args"), None)
    asserts.equals(env, struct(version = "2.7.0", fetched_identity = "@@//packages/args", purl = ""), package)

    # A Flutter SDK package, whose files repository records nothing:
    # rules_dart's `pub` never fetches one.
    asserts.equals(env, struct(version = "0.0.0", fetched_identity = "", purl = ""), package_fetched(attr(version = "0.0.0"), None))
    return unittest.end(env)

def _members_without_an_identity_state_none_test_impl(ctx):
    """A member no fetcher states (a Flutter SDK package's) is a plain `dart_package_metadata`."""
    env = unittest.begin(ctx)
    for content in [
        make_dart_member_build_content("args", "3.4", [], "", version = "2.7.0"),
        make_flutter_member_build_content("args", "3.4", [], "", version = "2.7.0"),
    ]:
        asserts.true(env, "\npackage_metadata(" not in content and "package_metadata.bzl" not in content, content)
        asserts.true(env, "fetched_identity" not in content and "\ndart_package_metadata(" in content, content)
    return unittest.end(env)

# `path` 1.9.1, as both the root lock and go_router_builder's record it.
_PATH_PURL = pub_hosted_purl("path", "1.9.1", "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5")

# `two_fetchers_local`, built from its directory by both fetchers.
_LOCAL_IDENTITY = pub_path_identity(Label("//flutter/tests/two_fetchers_fixture/lock:pubspec.lock"), "../local")

def _both_fetchers_copies_are_one_package_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, "@@//flutter/tests/two_fetchers_fixture/local", _LOCAL_IDENTITY)
    for name, identity in [("path", _PATH_PURL), ("two_fetchers_local", _LOCAL_IDENTITY)]:
        copies = [
            p
            for p in ctx.attr.library[DartInfo].transitive_packages.to_list()
            if p.package_name == name
        ]
        roots = sorted({p.package_root: True for p in copies}.keys())

        # A copy from each fetcher's repository, each fetched as the archive
        # or the directory.
        asserts.equals(env, 2, len(roots), roots)
        for p in copies:
            asserts.equals(env, identity, p.fetched_identity, p.package_root)
    return analysistest.end(env)

_both_fetchers_copies_are_one_package_test = analysistest.make(
    _both_fetchers_copies_are_one_package_test_impl,
    attrs = {"library": attr.label(providers = [DartInfo])},
)

_members_state_their_purl_test = unittest.make(_members_state_their_purl_test_impl)

def _relative_git_members_state_their_purl_test_impl(ctx):
    """A git package locked by a relative url is fetched as its repository and listed by its purl."""
    env = unittest.begin(ctx)
    lock = Label("//app:pubspec.lock")
    identity = pub_git_identity("args", "2.7.0", "../shared", _COMMIT, "pkgs/args", lock)
    purl = pub_git_purl("args", "2.7.0", "../shared", _COMMIT, "pkgs/args")
    for content in [
        make_dart_member_build_content("args", "3.4", [], "", version = "2.7.0", fetched_identity = identity, purl = purl),
        make_flutter_member_build_content("args", "3.4", [], "", version = "2.7.0", fetched_identity = identity, purl = purl, plugin_platforms = {"web": {"pluginClass": "WebPlugin"}}),
    ]:
        asserts.true(env, _identity_target(purl) in content, content)
        asserts.true(env, identity in content, content)
    return unittest.end(env)

_members_are_fetched_as_rules_dart_states_it_test = unittest.make(_members_are_fetched_as_rules_dart_states_it_test_impl)
_path_members_state_no_purl_test = unittest.make(_path_members_state_no_purl_test_impl)
_fetched_identity_follows_what_was_fetched_test = unittest.make(_fetched_identity_follows_what_was_fetched_test_impl)
_relative_git_members_state_their_purl_test = unittest.make(_relative_git_members_state_their_purl_test_impl)
_members_without_an_identity_state_none_test = unittest.make(_members_without_an_identity_state_none_test_impl)

def package_identity_test_suite(name):
    """Registers the package identity unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """

    # The program over both copies builds: a copy fetched as nothing, or
    # fetched differently, fails its analysis.
    _both_fetchers_copies_are_one_package_test(
        name = name + "_both_fetchers",
        target_under_test = "//flutter/tests/two_fetchers_fixture:two_fetchers_bin",
        library = "//flutter/tests/two_fetchers_fixture:two_fetchers",
    )
    unittest.suite(
        name + "_unit",
        _members_state_their_purl_test,
        _members_are_fetched_as_rules_dart_states_it_test,
        _path_members_state_no_purl_test,
        _fetched_identity_follows_what_was_fetched_test,
        _relative_git_members_state_their_purl_test,
        _members_without_an_identity_state_none_test,
    )
    native.test_suite(name = name, tests = [name + "_unit", name + "_both_fetchers"])
