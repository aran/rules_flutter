"""Unit tests for mapping a lock's packages to workspace targets.

`flutter_pub.from_lock(resolve = {...})` names the target that builds each
`path` package of the lock, and may name the target that replaces any other.
These pure checks run when the lock is read, so every case here is a mistake
that must fail then, naming the lock, the package and the fix.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_lock")
load("//flutter/private:flutter_unsupported_package.bzl", "ignored_package_message")
load("//flutter/private:pub_resolve.bzl", "lock_directory", "path_package_dir", "path_package_directory", "published_here_targets", "resolve_errors", "resolve_failure", "resolved_targets")

_LOCK = Label("//apps/greeter:pubspec.lock")

def _path_entry(name, path, relative = "true", version = "1.0.0"):
    return """\
  {name}:
    dependency: "direct main"
    description:
      path: "{path}"
      relative: {relative}
    source: path
    version: "{version}"
""".format(name = name, path = path, relative = relative, version = version)

def _lock(entries):
    packages = "packages:\n" + "".join(entries) if entries else "packages: {}\n"
    return packages + "sdks:\n  dart: \">=3.0.0 <4.0.0\"\n"

def _errors(entries, resolve, lock = _LOCK, build_from_pubspec = [], ignored = {}):
    return resolve_errors(lock, parse_pubspec_lock(_lock(entries), str(lock)), resolve, build_from_pubspec, ignored)

def _mentions(env, text, fragments):
    for fragment in fragments:
        asserts.true(env, fragment in text, "{} not in {}".format(fragment, text))

def _resolves_paths_relative_to_the_lock_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "packages/greeting", path_package_dir("apps/greeter", "../../packages/greeting").dir)
    asserts.equals(env, "pkgs/foo", path_package_dir("", "pkgs/foo").dir)
    asserts.equals(env, "y", path_package_dir("", "./x/../y").dir)
    asserts.equals(env, "pkgs/foo", path_package_dir("app", "..\\pkgs\\foo").dir)
    asserts.equals(env, "apps/greeter", path_package_dir("apps/greeter", ".").dir)
    asserts.equals(env, "", path_package_dir("app", "..").dir)
    for r in [path_package_dir("app", "../.."), path_package_dir("", "..")]:
        asserts.equals(env, None, r.dir)
        asserts.true(env, r.error != None and r.error != "")

    return unittest.end(env)

def _a_lock_in_a_subdirectory_of_its_package_test_impl(ctx):
    """A lock's directory is the file's, which a label's name can reach below its package."""
    env = unittest.begin(ctx)
    asserts.equals(env, "apps/greeter", lock_directory(Label("//apps/greeter:pubspec.lock")))
    asserts.equals(env, "apps/greeter/lock", lock_directory(Label("//apps/greeter:lock/pubspec.lock")))
    asserts.equals(env, "", lock_directory(Label("//:pubspec.lock")))
    asserts.equals(env, "lock", lock_directory(Label("//:lock/pubspec.lock")))
    _mentions(env, "\n".join(_errors([_path_entry("greeting", "../packages/greeting")], {}, lock = Label("//apps/greeter:lock/pubspec.lock"))), [
        '"greeting": "//apps/greeter/packages/greeting:<target>"',
    ])
    return unittest.end(env)

def _an_exact_map_has_no_errors_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, [], _errors(
        [
            _path_entry("greeting", "../../packages/greeting"),
            # As YAML spells a Windows path in double quotes: each backslash doubled.
            _path_entry("tagline", "..\\\\..\\\\packages\\\\tagline"),
        ],
        {
            "greeting": Label("//packages/greeting"),
            "tagline": Label("//packages/tagline:tagline_lib"),
        },
    ))

    return unittest.end(env)

def _an_unmapped_path_package_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    errors = _errors([_path_entry("greeting", "../../packages/greeting")], {})
    asserts.equals(env, 1, len(errors))
    _mentions(env, errors[0], [
        "it lists `greeting` as a `path` package. Name each in exactly one of:",
        "resolve = {\"greeting\": \"//packages/greeting:<target>\"}",
        "build_from_pubspec = [\"greeting\"]",
        "ignored = {\"greeting\": \"<why>\"}",
    ])

    # The tag and the lock head the problems.
    _mentions(env, resolve_failure("deps", _LOCK, errors), [
        "flutter_pub.from_lock(name = \"deps\", lock = \"@@//apps/greeter:pubspec.lock\"):\n  - it lists",
    ])

    # The suggested target first: most `path` packages have one.
    asserts.true(env, errors[0].index("resolve =") < errors[0].index("build_from_pubspec ="))
    asserts.true(env, errors[0].index("build_from_pubspec =") < errors[0].index("ignored ="))

    return unittest.end(env)

def _a_lock_that_says_relative_false_is_not_relative_test_impl(ctx):
    """The lock reader gives `relative: false` as the string "False", which Starlark holds true."""
    env = unittest.begin(ctx)

    errors = _errors([_path_entry("greeting", "/abs/packages/greeting", relative = "false")], {})
    asserts.equals(env, 1, len(errors))
    _mentions(env, errors[0], ["resolve = {\"greeting\": \"//...\"}"])

    return unittest.end(env)

def _a_path_package_built_from_its_pubspec_or_ignored_is_named_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, [], _errors(
        [
            _path_entry("keyboard_android", "../keyboard_android"),
            _path_entry("release_tool", "tools/release", relative = "false"),
            _path_entry("greeting", "../../packages/greeting"),
        ],
        {"greeting": Label("//packages/greeting")},
        build_from_pubspec = ["keyboard_android"],
        ignored = {"release_tool": "run with dart run outside Bazel"},
    ))

    return unittest.end(env)

def _a_package_named_two_ways_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    errors = _errors(
        [_path_entry("greeting", "../../packages/greeting")],
        {"greeting": Label("//packages/greeting")},
        build_from_pubspec = ["greeting"],
        ignored = {"greeting": "why"},
    )
    asserts.equals(env, 1, len(errors))
    _mentions(env, errors[0], ["`greeting` is named in `resolve` and `build_from_pubspec` and `ignored`; name it in one."])

    return unittest.end(env)

def _only_path_packages_are_built_from_their_pubspec_or_ignored_test_impl(ctx):
    env = unittest.begin(ctx)

    hosted = """\
  meta:
    dependency: "direct main"
    description:
      name: meta
      sha256: "00"
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
"""
    for attrs in [dict(build_from_pubspec = ["meta"]), dict(ignored = {"meta": "why"})]:
        errors = _errors([hosted], {}, **attrs)
        asserts.equals(env, 1, len(errors))
        attr = attrs.keys()[0]
        _mentions(env, errors[0], ["`%s` names `meta`, which the lock does not list as `path`: it takes only path packages." % attr])

    for attrs in [dict(build_from_pubspec = ["ghost"]), dict(ignored = {"ghost": "why"})]:
        errors = _errors([], {}, **attrs)
        asserts.equals(env, 1, len(errors))
        _mentions(env, errors[0], ["`%s` names `ghost`, which the lock does not list. Remove it." % attrs.keys()[0]])

    return unittest.end(env)

def _a_path_resolves_against_the_lock_directory_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "/repo/keyboard_android", path_package_directory("/repo/keyboard", "../keyboard_android"))
    asserts.equals(env, "/repo/keyboard/pkgs/a", path_package_directory("/repo/keyboard", "./pkgs/x/../a"))
    asserts.equals(env, "/repo/a", path_package_directory("/repo/keyboard", "..\\a"))
    asserts.equals(env, "/elsewhere/a", path_package_directory("/repo/keyboard", "/elsewhere/a"))
    asserts.equals(env, "C:/src/a", path_package_directory("C:/src/app", "../a"))
    asserts.equals(env, "C:/a", path_package_directory("C:/src/app", "../../../a"))
    asserts.equals(env, "D:/a", path_package_directory("C:/src/app", "D:\\a"))
    asserts.equals(env, "/a", path_package_directory("/repo", "../../a"))

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

def _a_mapped_name_the_lock_lacks_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    errors = _errors([], {"ghost": Label("//packages/ghost")})
    asserts.equals(env, 1, len(errors))
    _mentions(env, errors[0], ["`resolve` maps `ghost`, which the lock does not list. Remove it."])

    return unittest.end(env)

def _hosted_git_and_sdk_entries_may_be_mapped_test_impl(ctx):
    """A mapped hosted, git or sdk entry replaces the locked package, with no path checks."""
    env = unittest.begin(ctx)

    entries = [
        """\
  meta:
    dependency: "direct main"
    description:
      name: meta
      sha256: "00"
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
""",
        """\
  forked:
    dependency: "direct main"
    description:
      path: "."
      ref: main
      resolved-ref: "0123456789012345678901234567890123456789"
      url: "https://example.invalid/forked.git"
    source: git
    version: "1.0.0"
""",
        """\
  flutter_test:
    dependency: "direct dev"
    description: flutter
    source: sdk
    version: "0.0.0"
""",
    ]

    # Any repository and Bazel package: the replacement is not at the lock's path.
    resolve = {
        "meta": Label("//third_party/meta"),
        "forked": Label("@@other+//fork:forked"),
        "flutter_test": Label("//anywhere:flutter_test"),
    }
    asserts.equals(env, [], _errors(entries, resolve))

    return unittest.end(env)

def _unmapped_hosted_entries_need_nothing_test_impl(ctx):
    env = unittest.begin(ctx)

    hosted = """\
  meta:
    dependency: "direct main"
    description:
      name: meta
      sha256: "00"
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
"""
    asserts.equals(env, [], _errors([hosted], {}))

    return unittest.end(env)

def _a_mapped_path_entry_may_point_anywhere_test_impl(ctx):
    env = unittest.begin(ctx)

    # The map says where Bazel gets the package: the path is pub's concern, so
    # an absolute path, one out of the repository, a target in another module
    # or in another package are all accepted.
    for entry, label in [
        (_path_entry("greeting", "/abs/packages/greeting", relative = "false"), "//packages/greeting"),
        (_path_entry("greeting", "../../../../elsewhere/greeting"), "@@other+//:greeting"),
        (_path_entry("greeting", "../../packages/greeting"), "@@other+//packages/greeting"),
        (_path_entry("greeting", "../../packages/greeting"), "//packages/other:greeting"),
    ]:
        asserts.equals(env, [], _errors([entry], {"greeting": Label(label)}))

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

def _every_mistake_is_reported_test_impl(ctx):
    env = unittest.begin(ctx)

    errors = _errors(
        [
            _path_entry("alpha", "../../packages/alpha"),
            _path_entry("beta", "../../packages/beta"),
        ],
        {"ghost": Label("//packages/ghost")},
    )
    asserts.equals(env, 2, len(errors))
    _mentions(env, errors[0], ["`ghost`"])
    _mentions(env, errors[1], ["`alpha`, `beta` as `path` packages", "\"alpha\": \"//packages/alpha:<target>\", \"beta\": \"//packages/beta:<target>\""])

    return unittest.end(env)

_resolves_paths_relative_to_the_lock_test = unittest.make(_resolves_paths_relative_to_the_lock_test_impl)
_a_lock_in_a_subdirectory_of_its_package_test = unittest.make(_a_lock_in_a_subdirectory_of_its_package_test_impl)
_an_exact_map_has_no_errors_test = unittest.make(_an_exact_map_has_no_errors_test_impl)
_an_unmapped_path_package_is_refused_test = unittest.make(_an_unmapped_path_package_is_refused_test_impl)
_a_lock_that_says_relative_false_is_not_relative_test = unittest.make(_a_lock_that_says_relative_false_is_not_relative_test_impl)
_a_mapped_name_the_lock_lacks_is_refused_test = unittest.make(_a_mapped_name_the_lock_lacks_is_refused_test_impl)
_hosted_git_and_sdk_entries_may_be_mapped_test = unittest.make(_hosted_git_and_sdk_entries_may_be_mapped_test_impl)

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

_unmapped_hosted_entries_need_nothing_test = unittest.make(_unmapped_hosted_entries_need_nothing_test_impl)
_a_mapped_path_entry_may_point_anywhere_test = unittest.make(_a_mapped_path_entry_may_point_anywhere_test_impl)
_every_mistake_is_reported_test = unittest.make(_every_mistake_is_reported_test_impl)
_a_path_package_built_from_its_pubspec_or_ignored_is_named_test = unittest.make(_a_path_package_built_from_its_pubspec_or_ignored_is_named_test_impl)
_a_package_named_two_ways_is_refused_test = unittest.make(_a_package_named_two_ways_is_refused_test_impl)
_only_path_packages_are_built_from_their_pubspec_or_ignored_test = unittest.make(_only_path_packages_are_built_from_their_pubspec_or_ignored_test_impl)
_a_path_resolves_against_the_lock_directory_test = unittest.make(_a_path_resolves_against_the_lock_directory_test_impl)
_an_ignored_package_fails_with_its_reason_test = unittest.make(_an_ignored_package_fails_with_its_reason_test_impl)

def pub_resolve_test_suite(name):
    unittest.suite(
        name,
        _resolves_paths_relative_to_the_lock_test,
        _a_lock_in_a_subdirectory_of_its_package_test,
        _an_exact_map_has_no_errors_test,
        _an_unmapped_path_package_is_refused_test,
        _a_lock_that_says_relative_false_is_not_relative_test,
        _a_mapped_name_the_lock_lacks_is_refused_test,
        _hosted_git_and_sdk_entries_may_be_mapped_test,
        _unmapped_hosted_entries_need_nothing_test,
        _a_mapped_path_entry_may_point_anywhere_test,
        _every_mistake_is_reported_test,
        _a_path_package_built_from_its_pubspec_or_ignored_is_named_test,
        _a_package_named_two_ways_is_refused_test,
        _only_path_packages_are_built_from_their_pubspec_or_ignored_test,
        _a_path_resolves_against_the_lock_directory_test,
        _an_ignored_package_fails_with_its_reason_test,
        a_package_mapped_to_one_target_is_one_mapping_test,
        a_package_mapped_to_two_targets_is_refused_test,
        _pub_dev_runfiles_is_rules_dart_s_test,
        _a_resolve_of_runfiles_wins_test,
        _runfiles_from_elsewhere_stays_separate_test,
    )
