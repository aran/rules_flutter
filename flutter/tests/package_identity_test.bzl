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
load("@rules_dart//dart/pub:pub_lock_package.bzl", "make_package_metadata_content", "pub_git_purl", "pub_hosted_purl", "pub_package_identity", "pub_path_identity")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "make_dart_member_build_content",
    "make_flutter_member_build_content",
    "package_fetched_identity",
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

def _fetched_identity_follows_the_lock_entry_test_impl(ctx):
    """A package repository states what rules_dart computes from the same lock entry's fields."""
    env = unittest.begin(ctx)
    none = dict(git_url = "", resolved_ref = "", git_path = ".", sha256 = "", base_url = "https://pub.dev", directory = "", path_identity = "")

    def attr(**kwargs):
        fields = dict(none, package_name = "args", version = "2.7.0")
        fields.update(kwargs)
        return struct(**fields)

    asserts.equals(env, pub_hosted_purl("args", "2.7.0", _SHA), package_fetched_identity(attr(sha256 = _SHA)))
    asserts.equals(
        env,
        pub_hosted_purl("args", "2.7.0", _SHA, "https://pub.example.com/"),
        package_fetched_identity(attr(sha256 = _SHA, base_url = "https://pub.example.com/")),
    )
    asserts.equals(
        env,
        pub_git_purl("args", "2.7.0", "../args.git", _COMMIT, "pkgs/args"),
        package_fetched_identity(attr(git_url = "../args.git", resolved_ref = _COMMIT, git_path = "pkgs/args")),
    )
    asserts.equals(env, "@@//packages/args", package_fetched_identity(attr(directory = "/abs/packages/args", path_identity = "@@//packages/args")))

    # A Flutter SDK package: rules_dart's `pub` never fetches one.
    asserts.equals(env, "", package_fetched_identity(attr()))
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

def _purls_follow_the_lock_entry_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "pkg:pub/args@2.7.0?checksum=sha256:" + _SHA, pub_hosted_purl("args", "2.7.0", _SHA))
    asserts.equals(
        env,
        "pkg:pub/args@2.7.0?vcs_url=git%2Bhttps:%2F%2Fexample.com%2Fargs.git%40" + _COMMIT + "%23pkgs%2Fargs",
        pub_git_purl("args", "2.7.0", "https://example.com/args.git", _COMMIT, "pkgs/args"),
    )
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
_members_are_fetched_as_rules_dart_states_it_test = unittest.make(_members_are_fetched_as_rules_dart_states_it_test_impl)
_path_members_state_no_purl_test = unittest.make(_path_members_state_no_purl_test_impl)
_fetched_identity_follows_the_lock_entry_test = unittest.make(_fetched_identity_follows_the_lock_entry_test_impl)
_members_without_an_identity_state_none_test = unittest.make(_members_without_an_identity_state_none_test_impl)
_purls_follow_the_lock_entry_test = unittest.make(_purls_follow_the_lock_entry_test_impl)

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
        _fetched_identity_follows_the_lock_entry_test,
        _members_without_an_identity_state_none_test,
        _purls_follow_the_lock_entry_test,
    )
    native.test_suite(name = name, tests = [name + "_unit", name + "_both_fetchers"])
