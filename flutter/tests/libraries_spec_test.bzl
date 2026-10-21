"""Unit tests for the derived Flutter libraries spec."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:libraries_spec.bzl", "flutter_libraries_spec")

_SDK_SPEC = {
    "vm_common": {"libraries": {
        "core": {"uri": "core/core.dart", "patches": ["_internal/vm/lib/core_patch.dart"]},
        "io": {"uri": "io/io.dart", "patches": "_internal/vm/bin/io_patch.dart"},
        "isolate": {"uri": "isolate/isolate.dart"},
        "mirrors": {"uri": "mirrors/mirrors.dart"},
    }},
    "vm": {"include": [{"target": "vm_common"}], "libraries": {"cli": {"uri": "cli/cli.dart"}}},
    "dart2js": {"libraries": {"html": {"uri": "html/dart2js/html_dart2js.dart"}}},
}

def _names_test_impl(ctx):
    env = unittest.begin(ctx)
    spec = flutter_libraries_spec(_SDK_SPEC, "dart-sdk/lib/")
    asserts.equals(env, ["flutter"], [k for k in spec if not k.startswith("comment:")])
    asserts.equals(
        env,
        ["core", "io", "isolate", "ui"],
        sorted(spec["flutter"]["libraries"].keys()),
    )
    return unittest.end(env)

def _paths_rebased_test_impl(ctx):
    env = unittest.begin(ctx)
    libraries = flutter_libraries_spec(_SDK_SPEC, "dart-sdk/lib/")["flutter"]["libraries"]
    asserts.equals(env, "dart-sdk/lib/core/core.dart", libraries["core"]["uri"])
    asserts.equals(env, ["dart-sdk/lib/_internal/vm/lib/core_patch.dart"], libraries["core"]["patches"])
    asserts.equals(env, "dart-sdk/lib/_internal/vm/bin/io_patch.dart", libraries["io"]["patches"])
    asserts.false(env, "patches" in libraries["isolate"])
    return unittest.end(env)

_names_test = unittest.make(_names_test_impl)
_paths_rebased_test = unittest.make(_paths_rebased_test_impl)

def libraries_spec_test_suite(name):
    unittest.suite(name, _names_test, _paths_rebased_test)
