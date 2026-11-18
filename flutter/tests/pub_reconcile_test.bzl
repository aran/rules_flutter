"""Unit tests for reconciling a package that several `flutter_pub.from_lock()` locks list.

There is one repository per package for the whole build, so locks that list the
same package must agree on it: a disagreement fails when the module is read,
naming both locks and what to do. Hosted versions may differ, the highest
winning, and a raised lock of the root module is reported at the root's level.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:lock_entry_kind.bzl", "FLUTTER_SOURCE", "GIT", "HOSTED", "IGNORED", "LOCAL", "UNSUPPORTED")
load("//flutter/private:pub_reconcile.bzl", "pub_command", "reconcile_package", "unsupported_locks")

def _dir(lock):
    return lock.split("//")[1].split(":")[0]

def _hosted(version, hub = "deps", lock = "//app:pubspec.lock", sha256 = "aa", url = "https://pub.dev", module = "", is_root = True):
    return struct(kind = HOSTED, version = version, sha256 = sha256, url = url, hub = hub, lock_label = lock, lock_dir = _dir(lock), module = module, is_root = is_root)

def _tools(version, sha256 = "aa"):
    """rules_flutter's own tool lock, as a consumer's build sees it."""
    return _hosted(version, hub = "dev_tool_deps", lock = "@@rules_flutter+//:pubspec.lock", sha256 = sha256, module = "rules_flutter", is_root = False)

def _git(ref, hub = "deps", lock = "//app:pubspec.lock", url = "https://github.com/x/foo.git", path = ".", git_lock = ""):
    return struct(kind = GIT, version = "1.0.0", git_url = url, resolved_ref = ref, git_path = path, git_lock = git_lock, hub = hub, lock_label = lock)

def _local(directory, hub = "deps", lock = "//app:pubspec.lock"):
    return struct(kind = LOCAL, version = "1.0.0", directory = directory, hub = hub, lock_label = lock)

def _mentions(env, text, fragments):
    for fragment in fragments:
        asserts.true(env, fragment in text, "{} not in {}".format(fragment, text))

def _one_lock_is_its_own_entry_test_impl(ctx):
    env = unittest.begin(ctx)

    entry = _hosted("1.2.0")
    r = reconcile_package("meta", [entry])
    asserts.equals(env, [], r.errors)
    asserts.equals(env, entry, r.entry)

    return unittest.end(env)

one_lock_is_its_own_entry_test = unittest.make(_one_lock_is_its_own_entry_test_impl)

def _locks_that_agree_share_the_package_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("meta", [
        _hosted("1.2.0"),
        _hosted("1.2.0", hub = "tools", lock = "@rules_flutter//:pubspec.lock"),
    ])
    asserts.equals(env, [], r.errors)
    asserts.equals(env, "1.2.0", r.entry.version)

    pinned = "0123456789abcdef0123456789abcdef01234567"
    r = reconcile_package("foo", [_git(pinned), _git(pinned, hub = "tools", lock = "//tools:pubspec.lock")])
    asserts.equals(env, [], r.errors)

    return unittest.end(env)

locks_that_agree_share_the_package_test = unittest.make(_locks_that_agree_share_the_package_test_impl)

def _the_runner_command_names_the_lock_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "bazel run @rules_flutter//flutter/pub -- get", pub_command("get", ""))
    asserts.equals(env, "bazel run @rules_flutter//flutter/pub -- get --directory=apps/a", pub_command("get", "apps/a"))
    asserts.equals(env, "bazel run @rules_flutter//flutter/pub -- upgrade --directory=a meta intl", pub_command("upgrade", "a", ["meta", "intl"]))
    return unittest.end(env)

the_runner_command_names_the_lock_test = unittest.make(_the_runner_command_names_the_lock_test_impl)

def _the_highest_version_wins_test_impl(ctx):
    env = unittest.begin(ctx)

    low = _hosted("1.18.0", lock = "@@//app:pubspec.lock")
    high = _tools("1.19.0")
    for entries in [[low, high], [high, low]]:
        r = reconcile_package("meta", entries, "off")
        asserts.equals(env, [], r.errors)
        asserts.equals(env, high, r.entry)

    # Versions compare as versions, not as text; a release outranks its prerelease.
    r = reconcile_package("meta", [_tools("1.9.0"), _hosted("1.10.0")])
    asserts.equals(env, "1.10.0", r.entry.version)
    r = reconcile_package("meta", [_tools("2.0.0-dev.1"), _hosted("2.0.0")])
    asserts.equals(env, "2.0.0", r.entry.version)

    return unittest.end(env)

the_highest_version_wins_test = unittest.make(_the_highest_version_wins_test_impl)

def _raising_another_modules_lock_says_nothing_test_impl(ctx):
    env = unittest.begin(ctx)

    # The root's lock above rules_flutter's own tool lock: a minimum raised is
    # what it asks for, at every level.
    for check in ["off", "warning", "error"]:
        r = reconcile_package("meta", [_tools("1.18.0"), _hosted("1.19.0")], check)
        asserts.equals(env, [], r.errors)
        asserts.equals(env, [], r.warnings)
        asserts.equals(env, "1.19.0", r.entry.version)

    return unittest.end(env)

raising_another_modules_lock_says_nothing_test = unittest.make(_raising_another_modules_lock_says_nothing_test_impl)

def _a_raised_root_lock_warns_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("meta", [_hosted("1.18.0", lock = "@@//app:pubspec.lock"), _tools("1.19.0")])
    asserts.equals(env, [], r.errors)
    asserts.equals(env, "1.19.0", r.entry.version)
    asserts.equals(env, 1, len(r.warnings))
    _mentions(env, r.warnings[0], [
        "\"meta\" is built at 1.19.0, newer than the root module asks for",
        "  - 1.18.0, from the lock `//app:pubspec.lock`\n",
        "  - 1.19.0, from the lock `//:pubspec.lock` in module `rules_flutter`",
        "\n  bazel run @rules_flutter//flutter/pub -- upgrade --directory=app meta\n",
        "`flutter_pub.settings(check_direct_dependencies = \"off\")`",
    ])

    # A root lock raised by another of the root's is the root's own too; one at
    # the workspace root needs no directory.
    r = reconcile_package("meta", [_hosted("1.18.0", lock = "//:pubspec.lock"), _hosted("1.19.0", hub = "b", lock = "//b:pubspec.lock")])
    asserts.equals(env, 1, len(r.warnings))
    _mentions(env, r.warnings[0], ["\n  bazel run @rules_flutter//flutter/pub -- upgrade meta\n"])

    r = reconcile_package("meta", [_hosted("1.18.0"), _tools("1.19.0")], "off")
    asserts.equals(env, [], r.warnings)
    asserts.equals(env, [], r.errors)

    return unittest.end(env)

a_raised_root_lock_warns_test = unittest.make(_a_raised_root_lock_warns_test_impl)

def _a_raised_root_lock_fails_at_error_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("meta", [_hosted("1.18.0"), _tools("1.19.0")], "error")
    asserts.equals(env, None, r.entry)
    asserts.equals(env, [], r.warnings)
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], [
        "newer than the root module asks for",
        "upgrade --directory=app meta",
    ])

    return unittest.end(env)

a_raised_root_lock_fails_at_error_test = unittest.make(_a_raised_root_lock_fails_at_error_test_impl)

def _same_version_different_digest_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    # Whatever the level, and though another version is higher.
    for check in ["off", "warning"]:
        r = reconcile_package("meta", [_hosted("1.2.0", sha256 = "aa"), _tools("1.2.0", sha256 = "bb"), _hosted("1.3.0", hub = "b", lock = "//b:pubspec.lock")], check)
        asserts.equals(env, None, r.entry)
        asserts.equals(env, 1, len(r.errors))
        _mentions(env, r.errors[0], [
            "conflicting sha256 digests",
            "aa",
            "bb",
            "//app:pubspec.lock",
            "in module `rules_flutter`",
            "bazel run @rules_flutter//flutter/pub -- get --directory=app",
        ])

    return unittest.end(env)

same_version_different_digest_is_refused_test = unittest.make(_same_version_different_digest_is_refused_test_impl)

def _different_registries_are_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("meta", [_hosted("1.2.0"), _hosted("1.3.0", hub = "b", lock = "//b:pubspec.lock", url = "https://pub.example.com")], "off")
    asserts.equals(env, None, r.entry)
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], ["different registries", "https://pub.dev", "https://pub.example.com", "//b:pubspec.lock"])

    return unittest.end(env)

different_registries_are_refused_test = unittest.make(_different_registries_are_refused_test_impl)

def _different_sources_are_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    sdk = struct(kind = FLUTTER_SOURCE, version = "0.0.0", hub = "c", lock_label = "//c:pubspec.lock")
    for other in [_git("0123abc", hub = "tools", lock = "@rules_flutter//:pubspec.lock"), sdk]:
        r = reconcile_package("foo", [_hosted("1.2.0"), other])
        asserts.equals(env, 1, len(r.errors))
        _mentions(env, r.errors[0], ["\"foo\" comes from different sources", "hosted 1.2.0", "//app:pubspec.lock", other.lock_label, "`resolve`"])

    return unittest.end(env)

different_sources_are_refused_test = unittest.make(_different_sources_are_refused_test_impl)

def _different_commits_are_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("foo", [_git("0123abc"), _git("4567def", hub = "tools", lock = "//tools:pubspec.lock")])
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], ["\"foo\" is pinned to different git sources", "0123abc", "4567def", "//tools:pubspec.lock"])

    # The same commit of a different path is a different package source.
    r = reconcile_package("foo", [_git("0123abc"), _git("0123abc", path = "pkgs/foo")])
    asserts.equals(env, 1, len(r.errors))

    return unittest.end(env)

different_commits_are_refused_test = unittest.make(_different_commits_are_refused_test_impl)

def _unsupported_entries_name_every_lock_test_impl(ctx):
    env = unittest.begin(ctx)

    entries = [
        struct(kind = UNSUPPORTED, hub = "a", lock_label = "//b:pubspec.lock"),
        struct(kind = UNSUPPORTED, hub = "b", lock_label = "//a:pubspec.lock"),
    ]
    asserts.equals(env, [], reconcile_package("odd", entries).errors)
    asserts.equals(env, "//a:pubspec.lock, //b:pubspec.lock", unsupported_locks(entries))

    return unittest.end(env)

unsupported_entries_name_every_lock_test = unittest.make(_unsupported_entries_name_every_lock_test_impl)

def _one_directory_is_one_package_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("kb", [_local("/src/kb"), _local("/src/kb", hub = "b", lock = "//b:pubspec.lock")])
    asserts.equals(env, [], r.errors)
    asserts.equals(env, "/src/kb", r.entry.directory)

    return unittest.end(env)

one_directory_is_one_package_test = unittest.make(_one_directory_is_one_package_test_impl)

def _two_directories_are_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("kb", [_local("/src/kb"), _local("/other/kb", hub = "b", lock = "//b:pubspec.lock")])
    asserts.equals(env, None, r.entry)
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], ["\"kb\"", "/src/kb", "/other/kb", "//app:pubspec.lock", "//b:pubspec.lock", "different directories"])

    # Built in one lock and ignored in another is two sources.
    r = reconcile_package("kb", [_local("/src/kb"), struct(kind = IGNORED, reason = "why", hub = "b", lock_label = "//b:pubspec.lock")])
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], ["different sources", "built from its pubspec at /src/kb", "ignored (hub \"b\", //b:pubspec.lock)"])

    return unittest.end(env)

two_directories_are_refused_test = unittest.make(_two_directories_are_refused_test_impl)

def pub_reconcile_test_suite(name):
    unittest.suite(
        name,
        one_lock_is_its_own_entry_test,
        locks_that_agree_share_the_package_test,
        the_runner_command_names_the_lock_test,
        the_highest_version_wins_test,
        raising_another_modules_lock_says_nothing_test,
        a_raised_root_lock_warns_test,
        a_raised_root_lock_fails_at_error_test,
        same_version_different_digest_is_refused_test,
        different_registries_are_refused_test,
        different_sources_are_refused_test,
        different_commits_are_refused_test,
        unsupported_entries_name_every_lock_test,
        one_directory_is_one_package_test,
        two_directories_are_refused_test,
    )
