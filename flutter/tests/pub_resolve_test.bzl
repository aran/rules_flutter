"""Unit tests for mapping a lock's packages to workspace targets.

`flutter_pub.from_lock(resolve = {...})` names the target that builds each
`path` package of the lock, and may name the target that replaces any other.
How one tag names its lock's packages is rules_dart's `pub_lock_mapping_error`,
tested there; these are how the maps of every tag combine, checked when the
locks are read, so every mistake fails then, naming the lock, the package and
the fix.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_unsupported_package.bzl", "ignored_package_message")
load("//flutter/private:pub_resolve.bzl", "lock_directory", "published_here_targets", "resolved_targets")

def _mentions(env, text, fragments):
    for fragment in fragments:
        asserts.true(env, fragment in text, "{} not in {}".format(fragment, text))

def _a_lock_in_a_subdirectory_of_its_package_test_impl(ctx):
    """A lock's directory is the file's, which a label's name can reach below its package."""
    env = unittest.begin(ctx)
    asserts.equals(env, "apps/greeter", lock_directory(Label("//apps/greeter:pubspec.lock")))
    asserts.equals(env, "apps/greeter/lock", lock_directory(Label("//apps/greeter:lock/pubspec.lock")))
    asserts.equals(env, "", lock_directory(Label("//:pubspec.lock")))
    asserts.equals(env, "lock", lock_directory(Label("//:lock/pubspec.lock")))
    return unittest.end(env)

def _an_ignored_package_fails_with_its_reason_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "flutter_pub.from_lock(): package `release_tool` (in //:pubspec.lock) is ignored: run with dart run " +
        "outside Bazel. Something depends on it; remove that dependency, or build the package: name it in " +
        "`resolve` or `build_from_pubspec` instead of `ignored`.",
        ignored_package_message("release_tool", [struct(lock_label = "//:pubspec.lock", reason = "run with dart run outside Bazel")]),
    )

    # Every lock that ignores it, each with its reason, once.
    asserts.equals(
        env,
        "flutter_pub.from_lock(): package `t` (in //a:pubspec.lock) is ignored: one.\n" +
        "package `t` (in //b:pubspec.lock) is ignored: two. Something depends on it; remove that " +
        "dependency, or build the package: name it in `resolve` or `build_from_pubspec` instead of `ignored`.",
        ignored_package_message("t", [
            struct(lock_label = "//b:pubspec.lock", reason = "two"),
            struct(lock_label = "//a:pubspec.lock", reason = "one"),
            struct(lock_label = "//a:pubspec.lock", reason = "one"),
        ]),
    )

    return unittest.end(env)

def _map(lock, hub, resolve):
    return struct(lock = Label(lock), hub = hub, resolve = {k: Label(v) for k, v in resolve.items()})

def _a_package_mapped_to_one_target_is_one_mapping_test_impl(ctx):
    """Two tags may map a package to the same target: it is one repository."""
    env = unittest.begin(ctx)

    r = resolved_targets([
        _map("//a:pubspec.lock", "a", {"intl": "//third_party/intl", "x": "//x"}),
        _map("//b:pubspec.lock", "b", {"intl": "//third_party/intl"}),
    ])
    asserts.equals(env, [], r.errors)
    asserts.equals(env, ["intl", "x"], sorted(r.targets.keys()))
    asserts.equals(env, "a", r.targets["intl"].hub)

    return unittest.end(env)

a_package_mapped_to_one_target_is_one_mapping_test = unittest.make(_a_package_mapped_to_one_target_is_one_mapping_test_impl)

def _a_package_mapped_to_two_targets_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    r = resolved_targets([
        _map("//apps/a:pubspec.lock", "a", {"intl": "//third_party/intl"}),
        _map("//apps/b:pubspec.lock", "b", {"intl": "//other/intl"}),
    ])
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], [
        "\"intl\" is mapped to different targets",
        "//third_party/intl:intl",
        "//other/intl:intl",
        "//apps/a:pubspec.lock",
        "//apps/b:pubspec.lock",
        "hub \"a\"",
        "hub \"b\"",
        "one copy of each package",
    ])

    return unittest.end(env)

a_package_mapped_to_two_targets_is_refused_test = unittest.make(_a_package_mapped_to_two_targets_is_refused_test_impl)

_a_lock_in_a_subdirectory_of_its_package_test = unittest.make(_a_lock_in_a_subdirectory_of_its_package_test_impl)

def _hosted(url = None):
    desc = {"name": "runfiles", "sha256": "ab", "url": url} if url else {"name": "runfiles", "sha256": "ab"}
    return {"source": "hosted", "version": "0.4.10", "description": desc}

def _listing(lock, hub, packages):
    return struct(lock = Label(lock), hub = hub, packages = packages)

_RULES_DART_RUNFILES = str(Label("@rules_dart//dart/runfiles"))

def _pub_dev_runfiles_is_rules_dart_s_test_impl(ctx):
    env = unittest.begin(ctx)

    for url in [None, "https://pub.dev", "https://pub.dartlang.org/"]:
        got = published_here_targets([_listing("//a:pubspec.lock", "a", {"runfiles": _hosted(url)})], {})
        asserts.equals(env, ["runfiles"], got.keys())
        asserts.equals(env, _RULES_DART_RUNFILES, got["runfiles"].target)
        asserts.equals(env, str(Label("//a:pubspec.lock")), got["runfiles"].lock)

    # Every lock listing it from pub.dev is one mapping.
    both = published_here_targets([
        _listing("//a:pubspec.lock", "a", {"runfiles": _hosted()}),
        _listing("//b:pubspec.lock", "b", {"runfiles": _hosted("https://pub.dev")}),
    ], {})
    asserts.equals(env, "a", both["runfiles"].hub)

    # A build no lock of which lists it maps nothing.
    asserts.equals(env, {}, published_here_targets([_listing("//a:pubspec.lock", "a", {"args": _hosted()})], {}))

    return unittest.end(env)

def _a_resolve_of_runfiles_wins_test_impl(ctx):
    env = unittest.begin(ctx)

    own = resolved_targets([_map("//a:pubspec.lock", "a", {"runfiles": "//fork/runfiles"})])
    got = published_here_targets([_listing("//a:pubspec.lock", "a", {"runfiles": _hosted()})], own.targets)
    asserts.equals(env, {}, got)

    return unittest.end(env)

def _runfiles_from_elsewhere_stays_separate_test_impl(ctx):
    env = unittest.begin(ctx)

    others = [
        _hosted("https://pub.example.com"),
        {"source": "git", "version": "0.4.10", "description": {"url": "https://example.com/runfiles.git", "ref": "main", "resolved-ref": "0123", "path": "."}},
        {"source": "path", "version": "0.4.10", "description": {"path": "../runfiles", "relative": True}},
    ]
    for other in others:
        asserts.equals(env, {}, published_here_targets([_listing("//a:pubspec.lock", "a", {"runfiles": other})], {}))

        # Any lock's other package of the name keeps every lock's unmapped.
        asserts.equals(env, {}, published_here_targets([
            _listing("//a:pubspec.lock", "a", {"runfiles": _hosted()}),
            _listing("//b:pubspec.lock", "b", {"runfiles": other}),
        ], {}))

    return unittest.end(env)

_pub_dev_runfiles_is_rules_dart_s_test = unittest.make(_pub_dev_runfiles_is_rules_dart_s_test_impl)
_a_resolve_of_runfiles_wins_test = unittest.make(_a_resolve_of_runfiles_wins_test_impl)
_runfiles_from_elsewhere_stays_separate_test = unittest.make(_runfiles_from_elsewhere_stays_separate_test_impl)

_an_ignored_package_fails_with_its_reason_test = unittest.make(_an_ignored_package_fails_with_its_reason_test_impl)

def pub_resolve_test_suite(name):
    unittest.suite(
        name,
        _a_lock_in_a_subdirectory_of_its_package_test,
        _an_ignored_package_fails_with_its_reason_test,
        a_package_mapped_to_one_target_is_one_mapping_test,
        a_package_mapped_to_two_targets_is_refused_test,
        _pub_dev_runfiles_is_rules_dart_s_test,
        _a_resolve_of_runfiles_wins_test,
        _runfiles_from_elsewhere_stays_separate_test,
    )
