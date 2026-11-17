"""Reading an engine checkout's out dirs: their names, their `args.gn`, and which one serves a slot.

`engine/src/flutter/tools/gn` names an out dir `<target_os | host | wasm>_<runtime
mode>[_sim][_unopt][_<cpu>]`, appending the CPU only when it differs from that
platform's default. A
name is only how the scan finds candidates: `args.gn` is the authority on what
a directory holds.
"""

_MODES = ["debug", "profile", "release"]
_CPUS = ["arm", "arm64", "x64", "x86", "riscv64", "loong64"]
_OSES = ["host", "wasm", "mac", "ios", "android", "linux", "win", "fuchsia"]

# The CPU a name means when it states none.
_DEFAULT_CPU = {
    "android": "arm",
    "mac": "x64",
    "host": "x64",
    "linux": "x64",
    "win": "x64",
    "ios": "arm64",
    "wasm": "wasm",
    "fuchsia": "x64",
}

def parse_out_dir_name(name):
    """Parses the name `tools/gn` gives an out dir.

    Args:
        name: The directory's name.

    Returns:
        `struct(name, os, mode, sim, unopt, cpu)`, or None for a name the grammar does not produce
        (a `--target-dir`, a sanitizer build).
    """
    tokens = name.split("_")
    if len(tokens) < 2 or tokens[0] not in _OSES or tokens[1] not in _MODES:
        return None
    os = tokens[0]
    rest = tokens[2:]
    sim = bool(rest) and rest[0] == "sim"
    if sim:
        rest = rest[1:]
    unopt = bool(rest) and rest[0] == "unopt"
    if unopt:
        rest = rest[1:]
    cpu = _DEFAULT_CPU[os]
    if os == "ios" and sim:
        cpu = "x64"
    if rest:
        if len(rest) > 1 or rest[0] not in _CPUS:
            return None
        cpu = rest[0]
    return struct(name = name, os = os, mode = tokens[1], sim = sim, unopt = unopt, cpu = cpu)

def parse_args_gn(text):
    """Reads the `key = value` lines of an `args.gn`.

    Args:
        text: The file's text.

    Returns:
        A dict from key to value; a quoted string is unquoted, anything else
        (`true`, a number) is kept as written.
    """
    args = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value.startswith("\"") and value.endswith("\""):
            value = value[1:-1]
        args[key.strip()] = value
    return args

def effective_cpu(parsed, args):
    """The CPU an out dir was generated for: `args.gn` says, the name is the fallback."""
    return args.get("target_cpu") or parsed.cpu

def out_dir_names(os_names, mode, cpu, sim = False):
    """The names an out dir for a slot can have, for a message.

    Args:
        os_names: The target OS prefixes that can hold it (`host`, `mac`).
        mode: The runtime mode.
        cpu: The CPU wanted.
        sim: Whether the iOS simulator's name (`ios_debug_sim_unopt_arm64`) is wanted.

    Returns:
        The names, `host_release_arm64` and `host_release_unopt_arm64` and so on.
    """
    names = []
    for os in os_names:
        for unopt in ["", "_unopt"]:
            # `tools/gn` leaves out the CPU that is a platform's default.
            suffix = "" if cpu == _DEFAULT_CPU[os] or (os == "ios" and sim and cpu == "x64") else "_" + cpu
            names.append("{}_{}{}{}{}".format(os, mode, "_sim" if sim else "", unopt, suffix))
    return names

def select_out_dir(candidates, os_names, mode, cpu, pins, sim = False):
    """Chooses the out dir that serves one slot.

    A mode with no out dir is not served by another mode's: the modes are not
    interchangeable at run time. Optimised and unoptimised are the user's
    choice, never a preference: both present is an ambiguity to pin.

    Args:
        candidates: A list of `struct(name, os, mode, sim, unopt, cpu)` whose
            `cpu` is the effective one.
        os_names: The target OS prefixes that can hold the slot.
        mode: The runtime mode.
        cpu: The CPU wanted.
        pins: Out dir names the user chose (`FLUTTER_LOCAL_ENGINES`); empty for none. Only
            those that fit the slot count.
        sim: Whether the slot is the iOS simulator's, which only `--simulator` out dirs serve.

    Returns:
        `struct(name, error)`: the chosen directory's name, or None and why not.
    """
    matches = [c.name for c in candidates if c.os in os_names and c.mode == mode and c.cpu == cpu and c.sim == sim]

    # A pin chooses among the out dirs of the slots it fits; a slot it does
    # not fit is chosen as without it.
    pinned = [n for n in matches if n in pins]
    if pinned:
        matches = pinned
    if len(matches) == 1:
        return struct(name = matches[0], error = None)
    if not matches:
        return struct(name = None, error = "no out dir {} found for {} on {}".format(
            ", ".join(out_dir_names(os_names, mode, cpu, sim)),
            mode,
            cpu,
        ))
    return struct(name = None, error = (
        "{count} out dirs fit {mode} on {cpu}: {names}. Pick one with FLUTTER_LOCAL_ENGINES, " +
        "for example FLUTTER_LOCAL_ENGINES={first}"
    ).format(count = len(matches), mode = mode, cpu = cpu, names = ", ".join(matches), first = matches[0]))

def dict_text(d):
    """A string dict as Starlark source text, in key order.

    Args:
        d: The dict.

    Returns:
        The text of the dict literal.
    """
    return "{" + ", ".join(['"{}": {}'.format(k, json.encode(v)) for k, v in sorted(d.items())]) + "}"

def out_dir_provenance(out_dir, args):
    """What a slice read from an out dir records of where it came from.

    Args:
        out_dir: The out dir's name.
        args: The out dir's parsed `args.gn`.

    Returns:
        The provenance dict. `as_of: gn` says the commit is the one `tools/gn`
        recorded when it generated the directory, which can be older than the
        last ninja run.
    """
    provenance = {"origin": "out_dir", "out_dir": out_dir, "as_of": "gn"}
    for key in ["engine_version", "content_hash", "dart_version"]:
        if args.get(key):
            provenance[key] = args[key]
    return provenance

def first_existing(candidates):
    """The first of some repository paths that exists.

    Args:
        candidates: The paths to try, in order.

    Returns:
        The first one that exists, or None.
    """
    for candidate in candidates:
        if candidate.exists:
            return candidate
    return None

def link_into(repository_ctx, source, destination):
    """Links `source` into the repository and watches it: a rebuild that changes it refetches.

    Args:
        repository_ctx: The repository context.
        source: A path in the checkout.
        destination: The path in the repository.
    """
    repository_ctx.symlink(source, destination)
    if source.is_dir:
        repository_ctx.watch_tree(source)
    else:
        repository_ctx.watch(source)

def link_files_into(repository_ctx, source, destination):
    """Links a directory's files into a real directory of the repository.

    For a directory a program is handed with a trailing slash (a platform
    kernel's `--sdk-root`). On Windows a symlinked directory is a junction, and
    Dart's `FileSystemEntity.type` finds nothing at a junction's path with a
    trailing slash, so the front end reports its SDK root missing.

    Args:
        repository_ctx: The repository context.
        source: A directory in the checkout.
        destination: The directory in the repository.
    """
    pending = [(source, destination)]
    for _ in range(64):
        if not pending:
            break
        directory, target = pending.pop()
        for entry in directory.readdir():
            if entry.is_dir:
                pending.append((entry, target + "/" + entry.basename))
            else:
                repository_ctx.symlink(entry, target + "/" + entry.basename)
    repository_ctx.watch_tree(source)

# The machines whose out dirs can be read. `prebuilt` is the directory name
# `flutter/prebuilts` uses for the machine's Dart SDK; `os_prefix` is the
# machine's OS in an out dir name (`mac_release_arm64`).
_MACHINES = {
    ("mac", "arm64"): struct(key = "darwin-arm64", os = "macos", arch = "arm64", exe = "", prebuilt = "macos-arm64", os_prefix = "mac"),
    ("mac", "x64"): struct(key = "darwin-x64", os = "macos", arch = "x64", exe = "", prebuilt = "macos-x64", os_prefix = "mac"),
    ("linux", "arm64"): struct(key = "linux-arm64", os = "linux", arch = "arm64", exe = "", prebuilt = "linux-arm64", os_prefix = "linux"),
    ("linux", "x64"): struct(key = "linux-x64", os = "linux", arch = "x64", exe = "", prebuilt = "linux-x64", os_prefix = "linux"),
    ("windows", "x64"): struct(key = "windows-x64", os = "windows", arch = "x64", exe = ".exe", prebuilt = "windows-x64", os_prefix = "win"),
}

def machine_of(repository_ctx):
    """The machine that reads the out dirs, which is the host their `host_*` directories were built for.

    Args:
        repository_ctx: The repository context.

    Returns:
        `struct(key, os, arch, exe, prebuilt, os_prefix)`: the `HOST_PLATFORMS`
        key, the OS (`macos`, `linux`, `windows`), the CPU (`arm64`, `x64`),
        the executable suffix, the name of its directory under
        `flutter/prebuilts`, and its OS's prefix in an out dir name. None for a
        machine the out dirs are not read on.
    """
    name = repository_ctx.os.name.lower()
    os = "mac" if name.startswith("mac") else ("windows" if name.startswith("windows") else ("linux" if name.startswith("linux") else ""))
    arch = "arm64" if repository_ctx.os.arch in ["aarch64", "arm64"] else "x64"
    return _MACHINES.get((os, arch))
