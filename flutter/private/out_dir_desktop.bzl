"""The Linux and Windows slices of an engine checkout's out dirs.

`flutter_local_engine` (local_sdk.bzl) reads the checkout; this module
decides which out dir serves each desktop slice and writes the slice targets
(the labels of `engine_labels.bzl`):

* `linux-<arch>/<mode>:engine`: `libflutter_linux_gtk.so` and the
  `flutter_linux/` headers of the out dir for that CPU and mode: `host_<mode>`
  on a Linux machine of that CPU, or `linux_<mode>[_<cpu>]` built for it.
* `windows-<arch>/<mode>:engine`: `flutter_windows.dll`, its import library,
  the headers and `cpp_client_wrapper/` of `host_<mode>` on a Windows machine
  or `win_<mode>[_<cpu>]`.
* `<platform>/<mode>:gen_snapshot_<platform>` (profile, release): the out dir's
  own gen_snapshot, which runs on the machine that reads the out dirs and so
  serves only that machine's platform.

A desktop engine for another OS than the machine's can be built from out dirs
that name it (`linux_debug_arm64`), and is what a debug cross-build from
another OS uses; the AOT modes need a gen_snapshot that runs where the build
does, and exist only for the machine's own platform.
"""

load("//flutter/private:engine_labels.bzl", "ENGINE_MODES", "desktop_engine_dir")
load("//flutter/private:engine_out_dirs.bzl", "dict_text", "first_existing", "link_into", "out_dir_provenance", "select_out_dir")
load("//flutter/private:toolchains_repo.bzl", "DESKTOP_ENGINE_PLATFORMS")

visibility("//flutter/...")

# The out dir name's prefix of each desktop OS.
_OS_PREFIX = {"linux": "linux", "windows": "win"}

# What each OS's engine consists of, besides the library: headers a runner
# compiles against, linked as the files or directories they are.
_LINUX_HEADERS_DIR = "flutter_linux"
_WINDOWS_HEADERS = [
    "flutter_export.h",
    "flutter_windows.h",
    "flutter_messenger.h",
    "flutter_plugin_registrar.h",
    "flutter_texture_registrar.h",
]

def _gen_snapshot_candidates(out, os, exe):
    """Where an out dir keeps its gen_snapshot: `build/archives/BUILD.gn`."""
    if os == "windows":
        return [out.get_child("gen_snapshot").get_child("gen_snapshot" + exe), out.get_child("gen_snapshot" + exe)]
    return [out.get_child("gen_snapshot" + exe)]

def _linux_engine(repository_ctx, result, package, out, name, arch, mode, args):
    library = out.get_child("libflutter_linux_gtk.so")
    headers = out.get_child(_LINUX_HEADERS_DIR)
    absent = [path.basename for path in [library, headers] if not path.exists]
    if absent:
        result.reasons[(package, "engine")] = (
            "The out dir {out} lacks {absent}: build the Linux embedder (ninja -C out/{name} flutter/shell/platform/linux:flutter_linux_gtk)."
        ).format(out = out, absent = ", ".join(absent), name = name)
        return False
    link_into(repository_ctx, library, package + "/libflutter_linux_gtk.so")
    link_into(repository_ctx, headers, package + "/" + _LINUX_HEADERS_DIR)
    result.provided[(package, "engine")] = """
filegroup(
    name = "files",
    srcs = glob(["libflutter_linux_gtk.so", "flutter_linux/*.h"]),
)

flutter_linux_engine_slice(
    name = "engine",
    mode = "{mode}",
    cpus = ["{cpu}"],
    files = ":files",
    binary = ":libflutter_linux_gtk.so",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(mode = mode, cpu = "arm64" if arch == "arm64" else "x86_64", provenance = dict_text(out_dir_provenance(name, args)))
    return True

def _windows_engine(repository_ctx, result, package, out, name, arch, mode, args):
    needed = ["flutter_windows.dll", "flutter_windows.dll.lib"] + _WINDOWS_HEADERS
    absent = [n for n in needed if not out.get_child(n).exists]
    wrapper = out.get_child("cpp_client_wrapper")
    if not wrapper.exists:
        absent.append("cpp_client_wrapper")
    if absent:
        result.reasons[(package, "engine")] = (
            "The out dir {out} lacks {absent}: build the Windows embedder (ninja -C out/{name} flutter/shell/platform/windows:flutter_windows " +
            "flutter/shell/platform/windows/client_wrapper:publish_wrapper_windows)."
        ).format(out = out, absent = ", ".join(absent), name = name)
        return False
    for n in needed:
        link_into(repository_ctx, out.get_child(n), package + "/" + n)
    link_into(repository_ctx, wrapper, package + "/cpp_client_wrapper")
    result.provided[(package, "engine")] = """
filegroup(
    name = "files",
    srcs = glob([
        "flutter_windows.dll",
        "flutter_windows.dll.lib",
        "*.h",
        "cpp_client_wrapper/include/flutter/*.h",
        "cpp_client_wrapper/*.h",
        "cpp_client_wrapper/*.cc",
    ]),
)

flutter_windows_engine_slice(
    name = "engine",
    mode = "{mode}",
    cpus = ["{cpu}"],
    files = ":files",
    binary = ":flutter_windows.dll",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(mode = mode, cpu = "arm64" if arch == "arm64" else "x86_64", provenance = dict_text(out_dir_provenance(name, args)))
    return True

def _no_out_dir(ctx, os, mode, arch, error):
    return (
        "The engine out dirs under {out} have no {mode} engine for {os} on {arch}: {error}. Found: {found}. " +
        "Build one in the checkout (engine/src/flutter/tools/gn --{flag} --runtime-mode {mode} --{flag}-cpu {arch}, then ninja -C out/{dir}), " +
        "or build in a mode that exists."
    ).format(
        out = ctx.out_root,
        mode = mode,
        os = {"linux": "Linux", "windows": "Windows"}[os],
        arch = arch,
        error = error,
        found = ctx.found,
        flag = {"linux": "linux", "windows": "windows"}[os],
        dir = "{}_{}{}".format(_OS_PREFIX[os], mode, "" if arch == "x64" else "_" + arch),
    )

def desktop_slices(repository_ctx, out_root, candidates, args_of, pins, found, machine):
    """The Linux and Windows slices the out dirs provide, and why the others are missing.

    Args:
        repository_ctx: The adapter's repository context; slices' files are linked into it.
        out_root: The `engine/src/out` path.
        candidates: The out dirs found, as `struct(name, os, mode, sim, unopt, cpu)`.
        args_of: Each out dir's `args.gn`, by directory name.
        pins: Out dir names the user chose, or empty.
        found: A description of the out dirs found, for messages.
        machine: The machine reading the out dirs (`engine_out_dirs.machine_of`).

    Returns:
        `struct(provided, reasons)`: BUILD text by `(package, target)` of the
        slices that exist, and why the others do not.
    """
    result = struct(provided = {}, reasons = {})
    ctx = struct(out_root = out_root, found = found)
    for platform in DESKTOP_ENGINE_PLATFORMS:
        os, arch = platform.split("-")
        if os not in _OS_PREFIX:
            continue
        directory = desktop_engine_dir(platform)
        native = machine.os == os and machine.arch == arch
        os_names = [_OS_PREFIX[os]] + (["host"] if native else [])
        for mode in ENGINE_MODES:
            package = "{}/{}".format(directory, mode)
            pick = select_out_dir(candidates, os_names, mode, arch, pins)
            if not pick.name:
                message = _no_out_dir(ctx, os, mode, arch, pick.error)
                result.reasons[(package, "engine")] = message
                if mode != "debug":
                    result.reasons[(package, "gen_snapshot_" + platform)] = message
                continue
            out = out_root.get_child(pick.name)
            args = args_of[pick.name]
            (_linux_engine if os == "linux" else _windows_engine)(repository_ctx, result, package, out, pick.name, arch, mode, args)
            if mode == "debug":
                continue
            slice_key = (package, "gen_snapshot_" + platform)
            if not native:
                result.reasons[slice_key] = (
                    "The gen_snapshot of {platform} runs on a {platform} machine, and the engine out dirs are read on {machine}."
                ).format(platform = platform, machine = machine.key)
                continue
            found_binary = first_existing(_gen_snapshot_candidates(out, os, machine.exe))
            if found_binary == None:
                result.reasons[slice_key] = (
                    "The out dir {out} has no gen_snapshot{exe}: build it (ninja -C out/{name} flutter:gen_snapshot)."
                ).format(out = out, exe = machine.exe, name = pick.name)
                continue
            link_into(repository_ctx, found_binary, package + "/gen_snapshot" + machine.exe)
            result.provided[slice_key] = """
flutter_gen_snapshot(
    name = "gen_snapshot_{platform}",
    binary = ":gen_snapshot{exe}",
    target_cpu = "{cpu}",
    mode = "{mode}",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(platform = platform, exe = machine.exe, cpu = arch, mode = mode, provenance = dict_text(out_dir_provenance(pick.name, args)))
    return result
