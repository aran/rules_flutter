"""Analysis tests for the shared gen_snapshot flag construction.

`flutter_application` and `flutter_aot_target` build their AOT command line
from one helper (`flutter_aot_gen_snapshot_flags`), so these tests pin the
properties every public path must keep:

- `obfuscate` forces `--strip`, even in fastbuild: gen_snapshot embeds full
  DWARF carrying the original names unless stripped, so an unstripped
  "obfuscated" snapshot still leaks every class name.
- Every flag the rules add appears exactly once, even when the user also
  lists it in `extra_gen_snapshot_options`.
- `split_debug_info` keeps `--dwarf-stack-traces` and `--save-debugging-info`
  without `--resolve-dwarf-paths` (which cannot handle the rules'
  `org-dartlang-app:` URIs and would embed host paths).
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load("//flutter/private:flutter_aot_target.bzl", "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", "flutter_application")

_PACKAGE = "aot_flags_fixture"
_MAIN = "lib/language_version_main.dart"

def _aot_argv(env):
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic in ("FlutterAotElf", "FlutterAotMacho")
    ]
    asserts.equals(
        env,
        1,
        len(actions),
        "expected exactly one AOT action, got %s" % ([a.mnemonic for a in actions]),
    )
    return actions[0].argv if actions else []

def _count(argv, flag):
    return len([a for a in argv if a == flag])

def _obfuscate_strips_test_impl(ctx):
    """`obfuscate` forces `--strip`, even where the mode would not strip."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    asserts.equals(env, 1, _count(argv, "--obfuscate"), "expected exactly one --obfuscate, got %s" % (argv,))
    asserts.true(env, "--strip" in argv, "obfuscate must force --strip, got %s" % (argv,))
    return analysistest.end(env)

def _obfuscate_dedup_test_impl(ctx):
    """A user-supplied `--obfuscate` is not emitted a second time."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    asserts.equals(env, 1, _count(argv, "--obfuscate"), "expected exactly one --obfuscate, got %s" % (argv,))
    asserts.true(env, "--strip" in argv, "obfuscate must force --strip, got %s" % (argv,))
    return analysistest.end(env)

def _split_debug_flags_test_impl(ctx):
    """`split_debug_info` keeps DWARF traces and saved info, resolves nothing."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    asserts.equals(env, 1, _count(argv, "--dwarf-stack-traces"), "expected exactly one --dwarf-stack-traces, got %s" % (argv,))
    save_info = [a for a in argv if a.startswith("--save-debugging-info=")]
    asserts.equals(env, 1, len(save_info), "expected exactly one --save-debugging-info=, got %s" % (argv,))
    asserts.false(
        env,
        "--resolve-dwarf-paths" in argv,
        "must not pass --resolve-dwarf-paths, got %s" % (argv,),
    )
    asserts.false(
        env,
        "--strip" in argv,
        "split_debug_info alone must not strip, got %s" % (argv,),
    )
    return analysistest.end(env)

def _obfuscate_split_debug_flags_test_impl(ctx):
    """`obfuscate` + `split_debug_info` strips the binary, keeps the symbols file."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    asserts.equals(env, 1, _count(argv, "--obfuscate"), "expected exactly one --obfuscate, got %s" % (argv,))
    asserts.true(env, "--strip" in argv, "obfuscate must force --strip, got %s" % (argv,))
    asserts.equals(env, 1, _count(argv, "--dwarf-stack-traces"), "expected exactly one --dwarf-stack-traces, got %s" % (argv,))
    save_info = [a for a in argv if a.startswith("--save-debugging-info=")]
    asserts.equals(env, 1, len(save_info), "expected exactly one --save-debugging-info=, got %s" % (argv,))
    asserts.false(
        env,
        "--resolve-dwarf-paths" in argv,
        "must not pass --resolve-dwarf-paths, got %s" % (argv,),
    )
    return analysistest.end(env)

def _application_obfuscate_strips_test_impl(ctx):
    """`flutter_application(obfuscate = True)` strips like `flutter_aot_target` does."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    asserts.equals(env, 1, _count(argv, "--obfuscate"), "expected exactly one --obfuscate, got %s" % (argv,))
    asserts.true(env, "--strip" in argv, "obfuscate must force --strip, got %s" % (argv,))
    return analysistest.end(env)

_FASTBUILD = {
    "//command_line_option:compilation_mode": "fastbuild",
    str(Label("//flutter:profile")): False,
}

_obfuscate_strips_test = analysistest.make(
    _obfuscate_strips_test_impl,
    config_settings = _FASTBUILD,
)
_obfuscate_dedup_test = analysistest.make(
    _obfuscate_dedup_test_impl,
    config_settings = _FASTBUILD,
)
_split_debug_flags_test = analysistest.make(
    _split_debug_flags_test_impl,
    config_settings = _FASTBUILD,
)
_obfuscate_split_debug_flags_test = analysistest.make(
    _obfuscate_split_debug_flags_test_impl,
    config_settings = _FASTBUILD,
)
_application_obfuscate_strips_test = analysistest.make(
    _application_obfuscate_strips_test_impl,
    config_settings = _FASTBUILD,
)

def aot_flags_test_suite(name):
    """Defines analysis tests for the shared gen_snapshot flags.

    Args:
        name: The test_suite target name.
    """
    flutter_aot_target(
        name = "_flags_obf_target",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        obfuscate = True,
        tags = ["manual"],
    )
    flutter_aot_target(
        name = "_flags_obf_dup_target",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        obfuscate = True,
        extra_gen_snapshot_options = ["--obfuscate"],
        tags = ["manual"],
    )
    flutter_aot_target(
        name = "_flags_split_target",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        split_debug_info = True,
        tags = ["manual"],
    )
    flutter_aot_target(
        name = "_flags_obf_split_target",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        obfuscate = True,
        split_debug_info = True,
        tags = ["manual"],
    )
    flutter_application(
        name = "_flags_application_obf",
        package_name = _PACKAGE,
        main = _MAIN,
        obfuscate = True,
        tags = ["manual"],
    )

    _obfuscate_strips_test(
        name = name + "_obfuscate_strips",
        target_under_test = ":_flags_obf_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _obfuscate_dedup_test(
        name = name + "_obfuscate_dedup",
        target_under_test = ":_flags_obf_dup_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _split_debug_flags_test(
        name = name + "_split_debug",
        target_under_test = ":_flags_split_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _obfuscate_split_debug_flags_test(
        name = name + "_obfuscate_split_debug",
        target_under_test = ":_flags_obf_split_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _application_obfuscate_strips_test(
        name = name + "_application_obfuscate_strips",
        target_under_test = ":_flags_application_obf",
        target_compatible_with = HOST_COMPATIBLE,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_obfuscate_strips",
            ":" + name + "_obfuscate_dedup",
            ":" + name + "_split_debug",
            ":" + name + "_obfuscate_split_debug",
            ":" + name + "_application_obfuscate_strips",
        ],
    )
