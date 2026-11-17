"""Unit tests for reading an engine checkout's out dirs."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:engine_out_dirs.bzl", "effective_cpu", "parse_args_gn", "parse_out_dir_name", "select_out_dir")

def _shape(name):
    parsed = parse_out_dir_name(name)
    if parsed == None:
        return None
    return (parsed.os, parsed.mode, parsed.sim, parsed.unopt, parsed.cpu)

def _names_test_impl(ctx):
    env = unittest.begin(ctx)

    # (os, mode, simulator, unoptimised, cpu)
    asserts.equals(env, ("host", "debug", False, True, "arm64"), _shape("host_debug_unopt_arm64"))
    asserts.equals(env, ("host", "release", False, False, "x64"), _shape("host_release"))
    asserts.equals(env, ("ios", "debug", True, True, "arm64"), _shape("ios_debug_sim_unopt_arm64"))
    asserts.equals(env, ("ios", "debug", True, False, "x64"), _shape("ios_debug_sim"))
    asserts.equals(env, ("ios", "release", False, False, "arm64"), _shape("ios_release"))
    asserts.equals(env, ("android", "release", False, False, "arm64"), _shape("android_release_arm64"))

    # An unoptimised 32-bit ARM Android build is a name the grammar produces;
    # it is reported as what it is, so that no slot takes it for another.
    asserts.equals(env, ("android", "debug", False, True, "arm"), _shape("android_debug_unopt"))
    asserts.equals(env, ("mac", "release", False, False, "arm64"), _shape("mac_release_arm64"))
    asserts.equals(env, ("wasm", "release", False, False, "wasm"), _shape("wasm_release"))

    # A `--target-dir` or a sanitizer build is not a name `tools/gn` makes.
    asserts.equals(env, None, _shape("my_build"))
    asserts.equals(env, None, _shape("host_debug_asan_arm64"))
    asserts.equals(env, None, _shape("host_jit_release"))
    asserts.equals(env, None, _shape("host"))
    asserts.equals(env, None, _shape("flutter"))
    return unittest.end(env)

def _args_gn_test_impl(ctx):
    env = unittest.begin(ctx)
    args = parse_args_gn("""
# comment
target_cpu = "arm64"
flutter_runtime_mode = "debug"
flutter_prebuilt_dart_sdk = false
engine_version = "4f1c0d"

""")
    asserts.equals(env, "arm64", args["target_cpu"])
    asserts.equals(env, "false", args["flutter_prebuilt_dart_sdk"])
    asserts.equals(env, "4f1c0d", args["engine_version"])

    # args.gn is the authority on the CPU; the name is the fallback.
    parsed = parse_out_dir_name("host_debug")
    asserts.equals(env, "arm64", effective_cpu(parsed, args))
    asserts.equals(env, "x64", effective_cpu(parsed, {}))
    return unittest.end(env)

def _candidates(*names):
    return [parse_out_dir_name(n) for n in names]

def _slots_test_impl(ctx):
    env = unittest.begin(ctx)
    host_mac = ["host", "mac"]

    one = select_out_dir(_candidates("host_debug_unopt_arm64", "host_release_arm64"), host_mac, "release", "arm64", [])
    asserts.equals(env, "host_release_arm64", one.name)
    asserts.equals(env, None, one.error)

    # A mode with no out dir is not served by another mode's.
    missing = select_out_dir(_candidates("host_debug_unopt_arm64"), host_mac, "release", "arm64", [])
    asserts.equals(env, None, missing.name)
    asserts.equals(
        env,
        "no out dir host_release_arm64, host_release_unopt_arm64, mac_release_arm64, mac_release_unopt_arm64 found for release on arm64",
        missing.error,
    )

    # The wrong CPU is not served either.
    wrong_cpu = select_out_dir(_candidates("host_debug_x64", "host_debug"), host_mac, "debug", "arm64", [])
    asserts.equals(env, None, wrong_cpu.name)

    # Optimised and unoptimised are the user's choice: both present is an
    # ambiguity, never a preference.
    both = select_out_dir(_candidates("host_debug_arm64", "host_debug_unopt_arm64"), host_mac, "debug", "arm64", [])
    asserts.equals(env, None, both.name)
    asserts.equals(
        env,
        "2 out dirs fit debug on arm64: host_debug_arm64, host_debug_unopt_arm64. " +
        "Pick one with FLUTTER_LOCAL_ENGINES, for example FLUTTER_LOCAL_ENGINES=host_debug_arm64",
        both.error,
    )

    # A pin resolves it.
    pinned = select_out_dir(_candidates("host_debug_arm64", "host_debug_unopt_arm64"), host_mac, "debug", "arm64", ["host_debug_unopt_arm64"])
    asserts.equals(env, "host_debug_unopt_arm64", pinned.name)

    # A pin of another slot leaves this one as it is.
    unpinned = select_out_dir(_candidates("host_debug_unopt_arm64", "host_release_arm64"), host_mac, "release", "arm64", ["host_debug_unopt_arm64"])
    asserts.equals(env, "host_release_arm64", unpinned.name)
    still_both = select_out_dir(_candidates("host_debug_arm64", "host_debug_unopt_arm64"), host_mac, "debug", "arm64", ["wasm_release"])
    asserts.equals(env, None, still_both.name)

    # A simulator build is not a host build, whatever its mode.
    sim = select_out_dir(_candidates("ios_debug_sim_arm64"), host_mac, "debug", "arm64", [])
    asserts.equals(env, None, sim.name)
    return unittest.end(env)

def _mobile_slots_test_impl(ctx):
    env = unittest.begin(ctx)

    # The iOS simulator's slot is a `--simulator` out dir for the CPU, and the
    # device's is not one.
    names = _candidates("ios_debug_sim_unopt_arm64", "ios_debug_unopt", "ios_release", "ios_profile_unopt")
    simulator = select_out_dir(names, ["ios"], "debug", "arm64", [], sim = True)
    asserts.equals(env, "ios_debug_sim_unopt_arm64", simulator.name)
    asserts.equals(env, "ios_release", select_out_dir(names, ["ios"], "release", "arm64", []).name)
    asserts.equals(env, "ios_profile_unopt", select_out_dir(names, ["ios"], "profile", "arm64", []).name)

    # The other simulator CPU is not served, and the message names the out
    # dirs a simulator build is called.
    other = select_out_dir(names, ["ios"], "debug", "x64", [], sim = True)
    asserts.equals(env, None, other.name)
    asserts.equals(
        env,
        "no out dir ios_debug_sim, ios_debug_sim_unopt found for debug on x64",
        other.error,
    )

    # A device debug build is not the simulator's.
    asserts.equals(env, "ios_debug_unopt", select_out_dir(names, ["ios"], "debug", "arm64", []).name)

    # An Android out dir is named for its CPU; 32-bit ARM, `android_debug_unopt`,
    # serves neither 64-bit slot.
    android = _candidates("android_release_arm64", "android_release_x64", "android_debug_unopt")
    asserts.equals(env, "android_release_arm64", select_out_dir(android, ["android"], "release", "arm64", []).name)
    asserts.equals(env, "android_release_x64", select_out_dir(android, ["android"], "release", "x64", []).name)
    asserts.equals(env, None, select_out_dir(android, ["android"], "debug", "arm64", []).name)
    asserts.equals(env, None, select_out_dir(android, ["android"], "debug", "x64", []).name)

    # It serves the 32-bit slot, whose out dir `tools/gn` names without a CPU.
    asserts.equals(env, "android_debug_unopt", select_out_dir(android, ["android"], "debug", "arm", []).name)
    asserts.equals(
        env,
        "no out dir android_release, android_release_unopt found for release on arm",
        select_out_dir(_candidates("android_debug"), ["android"], "release", "arm", []).error,
    )
    return unittest.end(env)

def _desktop_slots_test_impl(ctx):
    env = unittest.begin(ctx)

    # Linux and Windows out dirs: the CPU is named when it is not x64.
    asserts.equals(env, ("linux", "debug", False, False, "x64"), _shape("linux_debug"))
    asserts.equals(env, ("linux", "release", False, True, "arm64"), _shape("linux_release_unopt_arm64"))
    asserts.equals(env, ("win", "profile", False, False, "x64"), _shape("win_profile"))

    # A Linux engine is a `linux_*` out dir for its CPU, or the host build on
    # a Linux machine of that CPU; a Mac's `host_*` is not a Linux build.
    linux = _candidates("linux_debug", "linux_debug_arm64", "linux_release_arm64", "host_debug_arm64")
    asserts.equals(env, "linux_debug", select_out_dir(linux, ["linux"], "debug", "x64", []).name)
    asserts.equals(env, "linux_debug_arm64", select_out_dir(linux, ["linux"], "debug", "arm64", []).name)
    asserts.equals(env, "host_debug_arm64", select_out_dir(_candidates("host_debug_arm64"), ["linux", "host"], "debug", "arm64", []).name)

    # On a Linux machine of that CPU both are Linux builds: the user chooses.
    both = select_out_dir(linux, ["linux", "host"], "debug", "arm64", [])
    asserts.equals(env, None, both.name)
    asserts.true(env, both.error.startswith("2 out dirs fit debug on arm64: "))

    # A mode with no out dir is not served by another mode's; the message
    # names the x64 out dirs without a CPU, as `tools/gn` does.
    missing = select_out_dir(linux, ["linux"], "release", "x64", [])
    asserts.equals(env, None, missing.name)
    asserts.equals(env, "no out dir linux_release, linux_release_unopt found for release on x64", missing.error)

    # The web SDK is the one `wasm_release` out dir.
    web = _candidates("wasm_release", "host_debug_arm64")
    asserts.equals(env, "wasm_release", select_out_dir(web, ["wasm"], "release", "wasm", []).name)
    asserts.equals(
        env,
        "no out dir wasm_release, wasm_release_unopt found for release on wasm",
        select_out_dir(_candidates("host_debug"), ["wasm"], "release", "wasm", []).error,
    )
    return unittest.end(env)

_names_test = unittest.make(_names_test_impl)
_args_gn_test = unittest.make(_args_gn_test_impl)
_slots_test = unittest.make(_slots_test_impl)
_mobile_slots_test = unittest.make(_mobile_slots_test_impl)
_desktop_slots_test = unittest.make(_desktop_slots_test_impl)

def engine_out_dirs_test_suite(name):
    unittest.suite(name, _names_test, _args_gn_test, _slots_test, _mobile_slots_test, _desktop_slots_test)
