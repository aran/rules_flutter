"""Tests for how an application merges the records of its native libraries."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:native_libraries.bzl", "merge_native_libraries")

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

def native_libraries_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    _one_record_per_library_test(name = name + "_one_record_per_library")
    _conflicting_contracts(name = name + "_conflicting_contracts_fixture", tags = ["manual"])
    _fails_test(
        name = name + "_conflicting_contracts",
        target_under_test = name + "_conflicting_contracts_fixture",
    )
    native.test_suite(
        name = name,
        tests = [
            name + "_one_record_per_library",
            name + "_conflicting_contracts",
        ],
    )
