"""Unit tests for the Flutter toolchain version selection in the `flutter` extension."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//flutter/private:toolchain_selection.bzl", "select_toolchain_source", "select_toolchain_version")

def _req(version, is_root = False, module = ""):
    return struct(version = version, is_root = is_root, module = module)

def _src(version = "", local_path = "", is_root = False):
    return struct(version = version, local_path = local_path, is_root = is_root)

def _single_request_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.47.7", is_root = True)])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _latest_wins_numerically_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.44.0"), _req("3.47.7"), _req("3.44.8")])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _root_older_than_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.44.8", is_root = True), _req("3.47.7")])
    asserts.equals(env, "3.44.8", selection.version)
    asserts.true(env, selection.note != None)
    return unittest.end(env)

def _root_newer_than_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.47.7", is_root = True), _req("3.44.8")])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _root_equal_to_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.47.7", is_root = True), _req("3.47.7")])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _no_root_request_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.44.8"), _req("3.47.7")])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _several_root_tags_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.44.8", is_root = True), _req("3.47.7", is_root = True)])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _several_toolchain_names_test_impl(ctx):
    env = unittest.begin(ctx)
    selection_sdk = select_toolchain_version("sdk", [_req("3.44.8", is_root = True)])
    selection_foo = select_toolchain_version("foo", [_req("3.41.2")])
    asserts.equals(env, "3.44.8", selection_sdk.version)
    asserts.equals(env, "3.41.2", selection_foo.version)
    return unittest.end(env)

def _prerelease_sorts_below_release_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.44.1-acme"), _req("3.44.1")])
    asserts.equals(env, "3.44.1", selection.version)
    return unittest.end(env)

def _prerelease_core_decides_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.45.0-0.1.pre"), _req("3.44.8")])
    asserts.equals(env, "3.45.0-0.1.pre", selection.version)
    return unittest.end(env)

def _build_metadata_ignored_test_impl(ctx):
    env = unittest.begin(ctx)

    # Build metadata never decides: a stamped version still loses to a
    # higher core, and a lone stamped request selects as-is.
    selection = select_toolchain_version("sdk", [_req("3.44.1+corp.7"), _req("3.44.8")])
    asserts.equals(env, "3.44.8", selection.version)
    selection = select_toolchain_version("sdk", [_req("3.44.1+corp.7")])
    asserts.equals(env, "3.44.1+corp.7", selection.version)

    # The same version spelled twice is one request, not a tie.
    selection = select_toolchain_version("sdk", [_req("3.44.1"), _req("3.44.1")])
    asserts.equals(env, "3.44.1", selection.version)
    return unittest.end(env)

def _enterprise_prerelease_root_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.44.1-acme", is_root = True), _req("3.47.7")])
    asserts.equals(env, "3.44.1-acme", selection.version)
    asserts.true(env, selection.note != None)
    return unittest.end(env)

def _root_local_overrides_dep_download_test_impl(ctx):
    env = unittest.begin(ctx)
    source = select_toolchain_source("flutter", [
        _src(version = "3.47.7"),
        _src(local_path = "/some/sdk", is_root = True),
    ])
    asserts.equals(env, "/some/sdk", source.local_path)
    asserts.equals(env, "", source.version)
    asserts.true(env, source.note != None)
    return unittest.end(env)

def _root_local_alone_test_impl(ctx):
    env = unittest.begin(ctx)
    source = select_toolchain_source("flutter", [_src(local_path = "/some/sdk", is_root = True)])
    asserts.equals(env, "/some/sdk", source.local_path)
    asserts.equals(env, None, source.note)
    return unittest.end(env)

def _root_download_uses_selection_test_impl(ctx):
    env = unittest.begin(ctx)
    source = select_toolchain_source("flutter", [
        _src(version = "3.47.7"),
        _src(version = "3.44.8", is_root = True),
    ])
    asserts.equals(env, "", source.local_path)
    asserts.equals(env, "3.44.8", source.version)
    return unittest.end(env)

def _source_probe_impl(ctx):
    select_toolchain_source("flutter", [
        struct(version = ctx.attr.version, local_path = ctx.attr.local_path, is_root = ctx.attr.is_root),
        struct(version = ctx.attr.version2, local_path = ctx.attr.local_path2, is_root = ctx.attr.is_root2),
    ])
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "ok")
    return [DefaultInfo(files = depset([out]))]

_source_probe = rule(
    implementation = _source_probe_impl,
    attrs = {
        "version": attr.string(default = ""),
        "local_path": attr.string(default = ""),
        "is_root": attr.bool(default = True),
        "version2": attr.string(default = ""),
        "local_path2": attr.string(default = ""),
        "is_root2": attr.bool(default = False),
    },
)

def _malformed_version_probe_impl(ctx):
    select_toolchain_version("sdk", [_req(ctx.attr.version)])
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "ok")
    return [DefaultInfo(files = depset([out]))]

_malformed_version_probe = rule(
    implementation = _malformed_version_probe_impl,
    attrs = {"version": attr.string(mandatory = True)},
)

# L-11: two equal-rank requests spelled differently refuse to pick.
def _tie_probe_impl(ctx):
    select_toolchain_version("sdk", [
        _req(ctx.attr.version, is_root = ctx.attr.is_root, module = ctx.attr.module),
        _req(ctx.attr.version2, is_root = ctx.attr.is_root2, module = ctx.attr.module2),
    ])
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "ok")
    return [DefaultInfo(files = depset([out]))]

_tie_probe = rule(
    implementation = _tie_probe_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "version2": attr.string(mandatory = True),
        "is_root": attr.bool(default = False),
        "is_root2": attr.bool(default = False),
        "module": attr.string(default = ""),
        "module2": attr.string(default = ""),
    },
)

def _expect_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
)

_single_request_test = unittest.make(_single_request_test_impl)
_latest_wins_numerically_test = unittest.make(_latest_wins_numerically_test_impl)
_root_older_than_dep_test = unittest.make(_root_older_than_dep_test_impl)
_root_newer_than_dep_test = unittest.make(_root_newer_than_dep_test_impl)
_root_equal_to_dep_test = unittest.make(_root_equal_to_dep_test_impl)
_no_root_request_test = unittest.make(_no_root_request_test_impl)
_several_root_tags_test = unittest.make(_several_root_tags_test_impl)
_several_toolchain_names_test = unittest.make(_several_toolchain_names_test_impl)
_prerelease_sorts_below_release_test = unittest.make(_prerelease_sorts_below_release_test_impl)
_prerelease_core_decides_test = unittest.make(_prerelease_core_decides_test_impl)
_build_metadata_ignored_test = unittest.make(_build_metadata_ignored_test_impl)
_enterprise_prerelease_root_test = unittest.make(_enterprise_prerelease_root_test_impl)
_root_local_overrides_dep_download_test = unittest.make(_root_local_overrides_dep_download_test_impl)
_root_local_alone_test = unittest.make(_root_local_alone_test_impl)
_root_download_uses_selection_test = unittest.make(_root_download_uses_selection_test_impl)

def toolchain_selection_test_suite(name):
    """Unit tests for `select_toolchain_version` (root pin wins).

    Args:
      name: The test_suite target name.
    """
    malformed = [
        ("nondigit_core", "3.44.x", ["Invalid Flutter SDK version", "3.44.x"]),
        ("empty_prerelease", "3.44.1-", ["Invalid Flutter SDK version", "3.44.1-"]),
        ("empty_version", "", ["Invalid Flutter SDK version"]),
    ]
    for probe_name, bad, expected in malformed:
        _malformed_version_probe(
            name = name + "_malformed_probe_" + probe_name,
            version = bad,
            tags = ["manual"],
        )
        _expect_failure_test(
            name = name + "_malformed_fails_" + probe_name,
            target_under_test = ":" + name + "_malformed_probe_" + probe_name,
            expected_substrings = expected,
        )
    _source_probe(
        name = name + "_root_mix_probe",
        version = "3.44.8",
        local_path = "/some/sdk",
        version2 = "3.47.7",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_root_mix_fails",
        target_under_test = ":" + name + "_root_mix_probe",
        expected_substrings = ["mixes a local SDK"],
    )
    _source_probe(
        name = name + "_root_two_tag_mix_probe",
        local_path = "/sdk/local",
        version2 = "3.44.8",
        is_root2 = True,
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_root_two_tag_mix_fails",
        target_under_test = ":" + name + "_root_two_tag_mix_probe",
        expected_substrings = ["mixes a local SDK"],
    )
    _source_probe(
        name = name + "_dep_local_probe",
        local_path = "/dep/sdk",
        is_root = False,
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_dep_local_fails",
        target_under_test = ":" + name + "_dep_local_probe",
        expected_substrings = ["Only the root module may source"],
    )
    _source_probe(
        name = name + "_multi_local_probe",
        local_path = "/sdk/one",
        version2 = "",
        local_path2 = "/sdk/two",
        is_root2 = True,
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_multi_local_fails",
        target_under_test = ":" + name + "_multi_local_probe",
        expected_substrings = ["multiple local SDKs"],
    )
    _tie_probe(
        name = name + "_dep_tie_probe",
        version = "3.44.1",
        module = "dep_a",
        version2 = "3.44.1+corp.7",
        module2 = "dep_b",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_dep_tie_fails",
        target_under_test = ":" + name + "_dep_tie_probe",
        expected_substrings = ["equally-ranked", "dep_a", "dep_b", "3.44.1+corp.7"],
    )
    _tie_probe(
        name = name + "_root_tie_probe",
        version = "3.44.1",
        is_root = True,
        module = "my_root",
        version2 = "3.44.1+corp.7",
        is_root2 = True,
        module2 = "my_root",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_root_tie_fails",
        target_under_test = ":" + name + "_root_tie_probe",
        expected_substrings = ["equally-ranked", "Keep exactly one"],
    )
    unittest.suite(
        name + "_unit",
        _single_request_test,
        _latest_wins_numerically_test,
        _root_older_than_dep_test,
        _root_newer_than_dep_test,
        _root_equal_to_dep_test,
        _no_root_request_test,
        _several_root_tags_test,
        _several_toolchain_names_test,
        _prerelease_sorts_below_release_test,
        _prerelease_core_decides_test,
        _build_metadata_ignored_test,
        _enterprise_prerelease_root_test,
        _root_local_overrides_dep_download_test,
        _root_local_alone_test,
        _root_download_uses_selection_test,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_malformed_fails_nondigit_core",
            ":" + name + "_malformed_fails_empty_prerelease",
            ":" + name + "_malformed_fails_empty_version",
            ":" + name + "_root_mix_fails",
            ":" + name + "_root_two_tag_mix_fails",
            ":" + name + "_dep_local_fails",
            ":" + name + "_multi_local_fails",
            ":" + name + "_dep_tie_fails",
            ":" + name + "_root_tie_fails",
        ],
    )
