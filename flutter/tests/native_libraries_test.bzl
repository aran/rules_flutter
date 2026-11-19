"""Tests for the records of an application's native libraries: which libraries
a `native_deps` entry brings, and how the records of one library merge."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:native_dynamic_deps_aspect.bzl", "native_dynamic_deps_aspect")
load("//flutter/private:native_libraries.bzl", "merge_native_libraries", "native_library_records")

_FIXTURE = "//flutter/tests/native_sources_fixture:"

# Stand-ins for Files: the merge reads only identity and `short_path`.
_LIB = struct(short_path = "libfoo.dylib")
_A = struct(short_path = "a.c")
_B = struct(short_path = "b.c")
_CONTRACT = struct(short_path = "foo.h")
_OTHER_CONTRACT = struct(short_path = "bar.h")

_LINKED = depset([struct(short_path = "foo.o")])

def _record(sources, contract, link_inputs = None):
    return struct(
        library = _LIB,
        package = "foo",
        sources = sources,
        contract = contract,
        link_inputs = link_inputs,
        dsym = None,
        link_inputs_unset_reason = None if link_inputs != None else "unseen",
    )

def _one_record_per_library_impl(ctx):
    # The app's own `native_deps` and a plugin's bring one library; only the
    # wrapper in one of them states its contract, and only the other sees the
    # link.
    env = unittest.begin(ctx)
    merged = merge_native_libraries(ctx.label, [
        _record((_A,), (), _LINKED),
        _record((_B, _A), (_CONTRACT,)),
    ])
    asserts.equals(env, [_LIB], merged.keys())
    asserts.equals(env, (_A, _B), merged[_LIB].sources, "every route's sources, each once, first seen first")
    asserts.equals(env, (_CONTRACT,), merged[_LIB].contract, "no contract yields to a stated one")
    asserts.equals(env, _LINKED, merged[_LIB].link_inputs, "an unseen link yields to a seen one")
    return unittest.end(env)

_one_record_per_library_test = unittest.make(_one_record_per_library_impl)

def _conflicting_contracts_impl(ctx):
    merge_native_libraries(ctx.label, [
        _record((), (_CONTRACT,)),
        _record((), (_OTHER_CONTRACT,)),
    ])
    return []

_conflicting_contracts = rule(implementation = _conflicting_contracts_impl)

def _fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "state different binding contracts for it")
    return analysistest.end(env)

_fails_test = analysistest.make(_fails_impl, expect_failure = True)

def _name(f):
    # The fixture's libraries are named for the platform the build runs on.
    return paths.split_extension(f.basename)[0]

def _library_name(target):
    # What the toolchain names a `cc_shared_library`: `libbridge` on Linux and
    # macOS, `bridge` on Windows.
    return [_name(f) for f in target[DefaultInfo].files.to_list() if f.extension in ("so", "dylib", "dll")][0]

def _loaded_libraries_impl(ctx):
    # `top` loads `bridge` through `dynamic_deps`, and the prebuilt
    # `libprebuilt` its `deps` reach: each has a record of its own, with its
    # own sources and link, whether `top` is named bare or behind a wrapper.
    env = unittest.begin(ctx)
    top_name = _library_name(ctx.attr.top)
    bridge_name = _library_name(ctx.attr.bridge)
    for entry in ctx.attr.native_deps:
        records = {_name(r.library): r for r in native_library_records([entry], "app")}
        asserts.equals(env, [top_name, bridge_name, "libprebuilt"], records.keys(), str(entry.label))
        asserts.equals(env, ["app"], {r.package: True for r in records.values()}.keys(), "every record is the entry's package's")

        bridge = records[bridge_name]
        asserts.equals(env, ["bridge.c", "bridge.h", "helper.c"], sorted([f.basename for f in bridge.sources]), "the loaded library's own sources")
        asserts.equals(
            env,
            ["libbridge_cc.a", "libhelper.a"],
            sorted([f.basename for f in bridge.link_inputs.to_list() if f.extension in ("o", "a")]),
            "the loaded library's own link",
        )
        asserts.equals(env, (), bridge.contract)

        prebuilt = records["libprebuilt"]
        asserts.equals(env, [], prebuilt.link_inputs.to_list(), "a checked-in library was linked from nothing")
        asserts.equals(env, None, prebuilt.link_inputs_unset_reason)
    return unittest.end(env)

_loaded_libraries_test = unittest.make(
    _loaded_libraries_impl,
    attrs = {
        "bridge": attr.label(),
        "native_deps": attr.label_list(aspects = [native_dynamic_deps_aspect]),
        "top": attr.label(),
    },
)

def native_libraries_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    _one_record_per_library_test(name = name + "_one_record_per_library")
    _loaded_libraries_test(
        name = name + "_loaded_libraries",
        native_deps = [_FIXTURE + "top", _FIXTURE + "top_files"],
        top = _FIXTURE + "top",
        bridge = _FIXTURE + "bridge",
    )
    _conflicting_contracts(name = name + "_conflicting_contracts_fixture", tags = ["manual"])
    _fails_test(
        name = name + "_conflicting_contracts",
        target_under_test = name + "_conflicting_contracts_fixture",
    )
    native.test_suite(
        name = name,
        tests = [
            name + "_one_record_per_library",
            name + "_loaded_libraries",
            name + "_conflicting_contracts",
        ],
    )
