"""Flutter AOT compilation action using gen_snapshot.

gen_snapshot converts a kernel .dill file into native code.
Output format depends on the target platform:
- Android/Linux/Windows: ELF shared library (app.so) via --snapshot_kind=app-aot-elf
- macOS/iOS: Mach-O dylib (App.framework/App) via --snapshot_kind=app-aot-macho-dylib,
  with the relocatable object it links, which a dSYM is read from.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING", "SPLIT_DEBUG_INFO_ATTR", "split_debug_info")

_FLUTTER_TOOLCHAIN = Label("//flutter:toolchain_type")

# gen_snapshot flags whose value is a file path gen_snapshot writes, by their
# hyphenated names (gen_snapshot takes `_` for `-` in a flag name).
_FILE_WRITING_FLAGS = [
    "print-instructions-sizes-to",
    "save-obfuscation-map",
    "write-v8-snapshot-profile-to",
]

_RESOLVE_DWARF_PATHS_REFUSED = (
    "%s: extra_gen_snapshot_options cannot hold `--resolve-dwarf-paths`. The " +
    "kernel names each source `org-dartlang-app:///<path in the workspace>` " +
    "or by its `package:` URI, never a path on disk, so the build is the same " +
    "on every machine, and gen_snapshot converts only `file:` URIs: it would " +
    "abort. Leave it out; the debug information then names each source by its " +
    "import URI."
)

# The build settings `gen_snapshot_options` reads, for every rule that AOT
# compiles. Like `flutter build --split-debug-info` and `--obfuscate`, they are
# the build's, not the app's: rules_dart's flag splits the debug info of every
# AOT program in the build, a `dart_binary`'s too.
GEN_SNAPSHOT_SETTINGS_ATTRS = SPLIT_DEBUG_INFO_ATTR | {
    "_obfuscate": attr.label(default = Label("//flutter:obfuscate")),
}

_OBFUSCATE_NEEDS_SPLIT = (
    "%s: `--@rules_flutter//flutter:obfuscate` needs " +
    "`--@rules_dart//dart:split_debug_info`, as `flutter build --obfuscate` " +
    "needs `--split-debug-info`: without the symbols it writes, an obfuscated " +
    "stack trace cannot be read back."
)

# The name `flutter build` gives an architecture in a split debug info file:
# Darwin's for Apple targets, Flutter's own for the rest.
_DARWIN_ARCHS = {"arm64": "arm64", "x64": "x86_64"}

def _symbols_basename(ctx, target_platform, target_arch):
    """`app.<platform>.symbols`, as `flutter build --split-debug-info` names it.

    `app.ios-arm64.symbols`, `app.darwin-x86_64.symbols`,
    `app.android-arm64.symbols`: one build may write several, one a platform
    and architecture, into one directory.
    """
    if target_platform in ("ios", "macos"):
        arch = _DARWIN_ARCHS.get(target_arch, "")
        platform = "darwin" if target_platform == "macos" else "ios"
    else:
        arch = target_arch
        platform = target_platform
    if not arch:
        fail(("%s: the split debug info is named after the target architecture, " +
              "which could not be determined for %s (got %r). This is a " +
              "rules_flutter bug in host_target_arch's cpu detection: please " +
              "report the bazel-out cpu segment of this build.") % (ctx.label, target_platform, target_arch))
    return "app.%s-%s.symbols" % (platform, arch)

def gen_snapshot_options(ctx, target_platform, target_arch, inputs = None):
    """Reads the gen_snapshot options a rule's attributes ask for.

    `extra_gen_snapshot_options` means the same on every rule that declares
    it, and `--@rules_flutter//flutter:obfuscate` and
    `--@rules_dart//dart:split_debug_info` the same on every rule that AOT
    compiles, so they are read in one place.

    An option that makes gen_snapshot write a file (`--save-obfuscation-map`,
    for one) names the file relative to the package, and the file is declared
    as an output of the rule under `<name>_gen_snapshot/`: an action keeps its
    declared outputs and nothing else. The files are in the rule's
    `gen_snapshot_files` output group.

    Args:
        ctx: A rule context with an `extra_gen_snapshot_options` attribute
            and `GEN_SNAPSHOT_SETTINGS_ATTRS`, which says where the declared
            files go (`<name>_gen_snapshot/`).
        target_platform: The platform the snapshot is for (`ios`, `macos`,
            `android`, `linux`, `windows`).
        target_arch: Its architecture (`arm64`, `x64`, `arm`), which names
            the split debug info file as `flutter build` does.
        inputs: What to read `extra_gen_snapshot_options` from, if not `ctx`:
            `flutter_program_inputs`, which a program rebuilt under another
            target (`flutter_application_variant`) carries from its own.

    Returns:
        A struct of `flags` (strings), `file_flags` ((flag, File) pairs),
        `debug_info` (the split debug info File,
        `<name>_symbols/app.<platform>-<arch>.symbols`, or None), `files` (every
        output the options declare) and `strip` (False when the options hold
        `--no-strip`, which `flutter build` reads as "ship the symbols").
    """
    flags = []
    file_flags = []
    strip = True
    if inputs == None:
        inputs = struct(extra_gen_snapshot_options = ctx.attr.extra_gen_snapshot_options)
    obfuscate = ctx.attr._obfuscate[BuildSettingInfo].value
    split = split_debug_info(ctx)
    if obfuscate and not split:
        fail(_OBFUSCATE_NEEDS_SPLIT % ctx.label)
    for option in inputs.extra_gen_snapshot_options:
        if option.partition("=")[0].replace("_", "-") == "--resolve-dwarf-paths":
            fail(_RESOLVE_DWARF_PATHS_REFUSED % ctx.label)

        # As flutter_tools does, `--no-strip` is read here and not passed on:
        # whether the snapshot is stripped is the rule's to decide, and an
        # Apple rule strips after its dSYM is made, not in gen_snapshot.
        if option.replace("_", "-") == "--no-strip":
            strip = False
            continue
        flag, has_value, value = option.partition("=")
        if not has_value or flag.lstrip("-").replace("_", "-") not in _FILE_WRITING_FLAGS or not flag.startswith("--"):
            flags.append(option)
            continue
        if not value or value.startswith("/") or ".." in value.split("/"):
            fail(
                ("%s: extra_gen_snapshot_options `%s` writes a file, so it must name " +
                 "one relative to the package, without `..`.") % (ctx.label, option),
            )
        output = ctx.actions.declare_file("%s_gen_snapshot/%s" % (ctx.label.name, value))
        file_flags.append((flag, output))
    if obfuscate:
        flags.append("--obfuscate")
    debug_info = None
    if split:
        debug_info = ctx.actions.declare_file("%s_symbols/%s" % (
            ctx.label.name,
            _symbols_basename(ctx, target_platform, target_arch),
        ))
    return struct(
        flags = flags,
        file_flags = file_flags,
        debug_info = debug_info,
        files = [f for _, f in file_flags],
        strip = strip,
    )

def _flutter_aot_action(
        ctx,
        gen_snapshot,
        kernel_dill,
        output,
        snapshot_kind,
        output_flag,
        strip = True,
        extra_flags = [],
        file_flags = [],
        debug_info = None,
        object = None,
        mnemonic = "FlutterAot"):
    """Internal helper for all AOT compilation variants."""
    args = ctx.actions.args()
    args.add("--deterministic")
    args.add("--snapshot_kind=" + snapshot_kind)
    args.add(output, format = output_flag + "=%s")

    if strip:
        args.add("--strip")

    outputs = [output]
    if object != None:
        args.add(object, format = "--macho-object=%s")
        outputs.append(object)
    if debug_info != None:
        args.add("--dwarf-stack-traces")

        # Not `--resolve-dwarf-paths`, which `flutter build` passes: it writes
        # each script's resolved URI as a path of the machine that compiled
        # it, and gen_snapshot aborts on any scheme but `file:` and the SDK's.
        # The kernel reads its sources under `APP_SCHEME`, so the debug info
        # names each by its import URI (`package:app/main.dart`), the same on
        # every machine. `gen_snapshot_options` refuses it from the user.
        args.add(debug_info, format = "--save-debugging-info=%s")
        outputs.append(debug_info)

    args.add_all(extra_flags)
    for flag, file in file_flags:
        args.add(file, format = flag + "=%s")
        outputs.append(file)
    args.add(kernel_dill)

    ctx.actions.run(
        executable = gen_snapshot,
        arguments = [args],
        # `gen_snapshot` is a standalone binary: it reads the kernel and no file
        # of any SDK.
        inputs = [kernel_dill],
        outputs = outputs,
        mnemonic = mnemonic,
        # `gen_snapshot` is the target toolchain's, which also fixes the hosts
        # it can run on: an iOS or macOS compiler runs only on a Mac.
        toolchain = _FLUTTER_TOOLCHAIN,
        execution_requirements = PATH_MAPPING,
        progress_message = "AOT compiling Flutter %s %s" % (snapshot_kind, ctx.label),
    )

# What flutter_tools gives gen_snapshot for a 32-bit ARM snapshot
# (`base/build.dart`): no integer division instruction, which not every 32-bit
# device has.
_ARM_FLAGS = ["--no-use-integer-division"]

def flutter_aot_elf_action(ctx, gen_snapshot, kernel_dill, output, strip = True, extra_flags = [], file_flags = [], debug_info = None, target_arch = ""):
    """AOT compile to ELF shared library. Used for Android, Linux, Windows.

    Args:
        ctx: Rule context.
        gen_snapshot: gen_snapshot executable File.
        kernel_dill: Kernel .dill input.
        output: Output shared library File.
        strip: Whether to strip debug symbols.
        extra_flags: Additional gen_snapshot flags. Not paths: a path
            reaches the action as a File, or path mapping cannot rewrite it.
        file_flags: (flag, File) pairs for the flags that write a file, such
            as `--save-obfuscation-map`; the Files are outputs of the action.
        debug_info: Optional File the split debug info is saved to
            (`--save-debugging-info`), with DWARF stack traces turned on.
        target_arch: The CPU the snapshot is for (`FlutterSdkInfo.target_arch`);
            `arm` adds the flags a 32-bit ARM snapshot needs.
    """
    flags = (_ARM_FLAGS if target_arch == "arm" else []) + list(extra_flags)
    _flutter_aot_action(ctx, gen_snapshot, kernel_dill, output, "app-aot-elf", "--elf", strip, flags, file_flags, debug_info, mnemonic = "FlutterAotElf")

def flutter_aot_macho_action(
        ctx,
        gen_snapshot,
        kernel_dill,
        output,
        extra_flags = [],
        file_flags = [],
        debug_info = None,
        object = None,
        install_name = "@rpath/App.framework/App",
        minimum_os_version = None,
        rpath = "@executable_path/Frameworks,@loader_path/Frameworks"):
    """AOT compile to Mach-O dylib. Used for macOS and iOS.

    The dylib keeps its symbols: gen_snapshot's `--strip` leaves no debug
    information to make a dSYM from, so Apple targets strip after extracting
    one, as `flutter build` does (see `split_and_strip_aot_binary`), unless
    `--no-strip` asked for the symbols (`gen_snapshot_options(...).strip`).

    Args:
        ctx: Rule context.
        gen_snapshot: gen_snapshot executable File.
        kernel_dill: Kernel .dill input.
        output: Output dylib File.
        extra_flags: Additional gen_snapshot flags. Not paths: a path
            reaches the action as a File, or path mapping cannot rewrite it.
        file_flags: (flag, File) pairs for the flags that write a file, such
            as `--save-obfuscation-map`; the Files are outputs of the action.
        debug_info: Optional File the split debug info is saved to
            (`--save-debugging-info`), with DWARF stack traces turned on.
        object: Optional File the relocatable object is written to
            (`--macho-object`). The dylib's debugging map points at it, and
            `dsymutil` reads the dSYM out of it.
        install_name: Mach-O LC_ID_DYLIB install name.
        minimum_os_version: Minimum OS deployment target (e.g. "15.0" for iOS, "12.0" for macOS).
        rpath: Comma-separated rpath entries for LC_RPATH.
    """
    macho_flags = list(extra_flags)
    macho_flags.append("--macho-install-name=" + install_name)
    if minimum_os_version:
        macho_flags.append("--macho-min-os-version=" + minimum_os_version)
    if rpath:
        macho_flags.append("--macho-rpath=" + rpath)
    _flutter_aot_action(ctx, gen_snapshot, kernel_dill, output, "app-aot-macho-dylib", "--macho", False, macho_flags, file_flags, debug_info, object, mnemonic = "FlutterAotMacho")
