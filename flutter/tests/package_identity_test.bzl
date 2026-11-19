"""Tests of what a pub package repository `flutter_pub_package` writes says it was fetched as.

A package's source is on the package metadata its targets name, as rules_dart's
`pub` states it for the same lock entry: a hosted or git package's `pkg:pub`
purl, a git repository a lock names relative to itself, or the directory a
path package is built from. A program reaching both fetchers' copies of one
archive, commit or directory takes them for one package. A purl is also stated
through Bazel's supply-chain metadata, as rules_dart's repositories state it: a
`package_metadata` target, which the repository's `REPO.bazel` attaches to
every target in it. The unit tests show what the BUILD files it writes
contain; the analysis test, that a program reaching both fetchers' copies of
packages really fetched builds. That a fetched package carries the purl of its
lock entry in its `package_metadata` is `fetched_purls_test`'s (`purls.bzl`).
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "make_package_metadata_content", "pub_git_source", "pub_hosted_source", "pub_package_identity", "pub_path_source")
load("//flutter/private:flutter_framework_package.bzl", "make_flutter_framework_build_content")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "make_dart_member_build_content",
    "make_flutter_member_build_content",
    "package_fetched",
)

_SHA = "d0481093c50b1da8910eb0bb301626d4d8eb7284aa739614d2b394ee09e3ea04"
_COMMIT = "0123456789abcdef0123456789abcdef01234567"
_LOCK = Label("//app:pubspec.lock")

_HOSTED = pub_hosted_source("args", "2.7.0", _SHA)
_GIT = pub_git_source("args", "2.7.0", "https://example.com/args.git", _COMMIT, "pkgs/args")
_LOCAL_GIT = pub_git_source("args", "2.7.0", "../shared", _COMMIT, "pkgs/args", _LOCK)
_PATH = pub_path_source(_LOCK, "../packages/args")

# A git repository the lock names outside its own repository: nothing names
# what it was fetched as, and its purl still lists it.
_OUTSIDE_GIT = pub_git_source("args", "2.7.0", "../../shared", _COMMIT, "pkgs/args", _LOCK)

# What a BUILD file loads `dart_package_metadata` with.
_DART_PACKAGE_METADATA_LOAD = 'load("@rules_dart//dart:defs.bzl", "dart_package_metadata")\n'

def _members(source):
    return [
        make_dart_member_build_content("args", "3.4", [], "", version = "2.7.0", source = source),
        make_flutter_member_build_content("args", "3.4", [], "", version = "2.7.0", source = source, plugin_platforms = {"web": {"pluginClass": "WebPlugin"}}),
    ]

def _identity_target(purl):
    return '''
package_metadata(
    name = "package-metadata",
    purl = "%s",
    visibility = ["//visibility:public"],
)
''' % purl

def _sources_are_rules_dart_s_test_impl(ctx):
    """What each kind of lock entry is fetched as."""
    env = unittest.begin(ctx)
    asserts.equals(env, struct(kind = "purl", purl = _HOSTED.purl), _HOSTED.identity)
    asserts.equals(env, struct(kind = "purl", purl = _GIT.purl), _GIT.identity)
    asserts.equals(env, struct(kind = "local_git", repository = "", directory = "shared", commit = _COMMIT, package_path = "pkgs/args"), _LOCAL_GIT.identity)
    asserts.equals(env, struct(identity = struct(kind = "directory", repository = "", directory = "packages/args"), purl = ""), _PATH)
    asserts.equals(env, None, _OUTSIDE_GIT.identity)
    asserts.true(env, _OUTSIDE_GIT.purl.startswith("pkg:pub/args@2.7.0"), _OUTSIDE_GIT.purl)

    # A path leaving the lock's repository, or absolute, names no directory in it.
    asserts.equals(env, None, pub_path_source(_LOCK, "../../elsewhere"))
    asserts.equals(env, None, pub_path_source(_LOCK, "/abs/args"))
    return unittest.end(env)

def _members_state_their_purl_test_impl(ctx):
    env = unittest.begin(ctx)
    for source in [_HOSTED, _GIT, _LOCAL_GIT, _OUTSIDE_GIT]:
        for content in _members(source):
            asserts.true(env, _identity_target(source.purl) in content, content)

            # Every load comes before the first target.
            asserts.true(env, content.rfind("\nload(") < content.find("\npackage_metadata("), content)
    asserts.equals(env, 'repo(default_package_metadata = ["//:package-metadata"])\n', pub_package_identity(_HOSTED).repo_file)
    return unittest.end(env)

def _members_are_fetched_as_rules_dart_states_it_test_impl(ctx):
    """A member's package metadata is rules_dart's for the same lock entry."""
    env = unittest.begin(ctx)
    for source, rule in [
        (_HOSTED, "fetched_package_metadata"),
        (_GIT, "fetched_package_metadata"),
        (_LOCAL_GIT, "fetched_local_git_package_metadata"),
        (_PATH, "fetched_path_package_metadata"),
    ]:
        # What rules_dart's `pub` declares the package with, fetched alike.
        stated = make_package_metadata_content("args", "3.4", version = "2.7.0", source = source)
        asserts.true(env, stated.lstrip("\n").startswith(rule + "("), stated)
        for content in _members(source):
            asserts.true(env, stated in content, content)
            asserts.true(env, "dart_package_metadata(" not in content, content)
            asserts.true(env, pub_package_identity(source).loads in content, content)
    return unittest.end(env)

def _path_members_state_no_purl_test_impl(ctx):
    """A directory is no purl: a path member states no `package_metadata`, as rules_dart's do."""
    env = unittest.begin(ctx)
    asserts.equals(env, "", pub_package_identity(_PATH).repo_file)
    for content in _members(_PATH):
        asserts.true(env, "\npackage_metadata(" not in content and "//rules:package_metadata.bzl" not in content, content)
    return unittest.end(env)

def _source_follows_what_was_fetched_test_impl(ctx):
    """A package repository states what its files repository fetched, or for a path package its directory."""
    env = unittest.begin(ctx)

    def attr(**kwargs):
        fields = dict(package_name = "args", version = "", lock = None, path = "")
        fields.update(kwargs)
        return struct(**fields)

    # A hosted or git package: what `pub_files_fetched` read, never facts
    # passed beside the files.
    for source in [_HOSTED, _LOCAL_GIT]:
        fetched = struct(package_name = "args", version = "2.7.0", source = source)
        asserts.equals(env, struct(version = "2.7.0", source = source), package_fetched(struct(attr = attr()), fetched))

    # A path package: the directory it is built from, named by its lock and
    # the lock's path to it, at the lock's version.
    # One the lock names outside its repository is named by where it is on
    # the machine, which a repository's context finds (rules_dart's
    # `pub_lock_path_source`, tested there and by the path package e2e).
    package = package_fetched(struct(attr = attr(version = "2.7.0", lock = _LOCK, path = "../packages/args")), None)
    asserts.equals(env, struct(version = "2.7.0", source = _PATH), package)

    # A Flutter SDK package, whose files repository records nothing:
    # rules_dart's `pub` never fetches one.
    asserts.equals(env, struct(version = "0.0.0", source = None), package_fetched(struct(attr = attr(version = "0.0.0")), None))
    return unittest.end(env)

def _members_without_an_identity_load_their_declaration_test_impl(ctx):
    """A member nothing says was fetched (a Flutter SDK package's, or a git one from outside the lock's repository) is a `dart_package_metadata`, loaded."""
    env = unittest.begin(ctx)
    for source in [None, _OUTSIDE_GIT]:
        for content in _members(source):
            asserts.true(env, "fetched_" not in content and "\ndart_package_metadata(" in content, content)
            asserts.true(env, _DART_PACKAGE_METADATA_LOAD in content, content)
    for content in _members(None):
        asserts.true(env, "\npackage_metadata(" not in content and "//rules:package_metadata.bzl" not in content, content)

    # `package:flutter`, built from the SDK's framework.
    framework = make_flutter_framework_build_content([], "3.8")
    asserts.true(env, _DART_PACKAGE_METADATA_LOAD in framework and "\ndart_package_metadata(" in framework, framework)
    return unittest.end(env)

# `path` 1.9.1, as both the root lock and go_router_builder's record it.
_PATH_IDENTITY = pub_hosted_source("path", "1.9.1", "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5").identity

# `two_fetchers_local`, built from its directory by both fetchers.
_LOCAL_IDENTITY = pub_path_source(Label("//flutter/tests/two_fetchers_fixture/lock:pubspec.lock"), "../local").identity

def _both_fetchers_copies_are_one_package_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, struct(kind = "directory", repository = "", directory = "flutter/tests/two_fetchers_fixture/local"), _LOCAL_IDENTITY)
    for name, identity in [("path", _PATH_IDENTITY), ("two_fetchers_local", _LOCAL_IDENTITY)]:
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

_sources_are_rules_dart_s_test = unittest.make(_sources_are_rules_dart_s_test_impl)
_members_state_their_purl_test = unittest.make(_members_state_their_purl_test_impl)
_members_are_fetched_as_rules_dart_states_it_test = unittest.make(_members_are_fetched_as_rules_dart_states_it_test_impl)
_path_members_state_no_purl_test = unittest.make(_path_members_state_no_purl_test_impl)
_source_follows_what_was_fetched_test = unittest.make(_source_follows_what_was_fetched_test_impl)
_members_without_an_identity_load_their_declaration_test = unittest.make(_members_without_an_identity_load_their_declaration_test_impl)

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
        _sources_are_rules_dart_s_test,
        _members_state_their_purl_test,
        _members_are_fetched_as_rules_dart_states_it_test,
        _path_members_state_no_purl_test,
        _source_follows_what_was_fetched_test,
        _members_without_an_identity_load_their_declaration_test,
    )
    native.test_suite(name = name, tests = [name + "_unit", name + "_both_fetchers"])
