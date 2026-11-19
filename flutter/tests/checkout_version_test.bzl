"""Unit tests for what flutter_tools reports of a checkout, from its git history.

Each case is one of flutter_tools' own (`version_test.dart`): a tag, a
candidate branch's tag, commits past either, and what is not a version.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:checkout_version.bzl", "USER_BRANCH", "checkout_channel", "checkout_framework_version", "checkout_repository_url", "framework_version_for", "parse_git_tag_version")

_HASH = "abcdef0123456789abcdef0123456789abcdef01"

def _version(text, revision = _HASH):
    return framework_version_for(parse_git_tag_version(text), revision)

def _versions_are_flutter_tools_test_impl(ctx):
    env = unittest.begin(ctx)

    # At a tag, the tag.
    asserts.equals(env, "1.2.3", _version("1.2.3"))
    asserts.equals(env, "1.2.3-4.5.pre", _version("1.2.3-4.5.pre"))

    # Past a release, the next patch's pre-release; past a candidate branch's
    # tag, the next candidate branch's.
    asserts.equals(env, "1.2.4-0.0.pre-13", _version("1.2.3-13"))
    asserts.equals(env, "1.2.0-5.0.pre-13", _version("1.2.3-4.5.pre-13"))
    asserts.equals(env, "1.2.4-0.0.pre-13", _version("1.2.3-13-gabcdef"))
    asserts.equals(env, "1.2.4-0.0.pre-13", _version("1.2.3.13"))

    # A hash that is not the commit's says nothing.
    asserts.equals(env, "0.0.0-unknown", _version("1.2.3-13-g0123", revision = "abcd"))

    # Not a version.
    for text in ["", "-", "-13", "1.2", "x.y.z", "1.2.3-beta", "1.2.3-4.5.pre-13-gxyz", "1.2.3+hotfix.1"]:
        asserts.equals(env, None, parse_git_tag_version(text), text)
        asserts.equals(env, "0.0.0-unknown", _version(text), text)

    return unittest.end(env)

versions_are_flutter_tools_test = unittest.make(_versions_are_flutter_tools_test_impl)

def _git(answers):
    """A git that answers each command (its arguments joined by spaces) as given, and fails any other."""

    def run(args):
        key = " ".join(args)
        if key in answers:
            return struct(ok = True, stdout = answers[key] + "\n")
        return struct(ok = False, stdout = "")

    return run

def _the_checkout_is_read_as_flutter_tools_reads_it_test_impl(ctx):
    env = unittest.begin(ctx)

    # A release tag at the commit wins over a candidate branch's tag.
    at_tags = _git({"tag --points-at " + _HASH: "3.50.0\n3.50.0-0.3.pre"})
    asserts.equals(env, "3.50.0", checkout_framework_version(at_tags, _HASH))

    # Past the newest tag: the commits since the commit it shares with it.
    past = _git({
        "tag --points-at " + _HASH: "",
        "for-each-ref --sort=-v:refname --count=1 --format=%(refname:short) refs/tags/[0-9]*.*.*": "3.51.0-0.1.pre",
        "merge-base {} 3.51.0-0.1.pre".format(_HASH): "1111",
        "rev-list --count 1111..{}".format(_HASH): "7",
    })
    asserts.equals(env, "3.51.0-1.0.pre-7", checkout_framework_version(past, _HASH))

    # No tags at all.
    asserts.equals(env, "0.0.0-unknown", checkout_framework_version(_git({}), _HASH))

    # The channel is a channel's branch, and any other branch, or none, is redacted.
    asserts.equals(env, "main", checkout_channel(_git({"symbolic-ref --short HEAD": "main"})))
    asserts.equals(env, "dev", checkout_channel(_git({"symbolic-ref --short HEAD": "dev"})))
    asserts.equals(env, USER_BRANCH, checkout_channel(_git({"symbolic-ref --short HEAD": "my-feature"})))
    asserts.equals(env, USER_BRANCH, checkout_channel(_git({})))

    # The repository is the remote the branch tracks, else origin's.
    tracking = _git({
        "rev-parse --abbrev-ref --symbolic @{upstream}": "upstream/main",
        "ls-remote --get-url upstream": "https://github.com/flutter/flutter.git",
        "remote get-url origin": "git@github.com:me/flutter.git",
    })
    asserts.equals(env, "https://github.com/flutter/flutter.git", checkout_repository_url(tracking))
    origin = _git({"remote get-url origin": "git@github.com:me/flutter.git"})
    asserts.equals(env, "git@github.com:me/flutter.git", checkout_repository_url(origin))
    asserts.equals(env, None, checkout_repository_url(_git({})))

    return unittest.end(env)

the_checkout_is_read_as_flutter_tools_reads_it_test = unittest.make(_the_checkout_is_read_as_flutter_tools_reads_it_test_impl)

def checkout_version_test_suite(name):
    unittest.suite(
        name,
        versions_are_flutter_tools_test,
        the_checkout_is_read_as_flutter_tools_reads_it_test,
    )
