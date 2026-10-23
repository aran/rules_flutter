"""Flutter AOT compilation action using gen_snapshot.

gen_snapshot converts a kernel .dill file into native code.
Output format depends on the target platform:
- Android/Linux/Windows: ELF shared library (app.so) via --snapshot_kind=app-aot-elf
- macOS/iOS: Mach-O dylib (App.framework/App) via --snapshot_kind=app-aot-macho-dylib
"""

def _flutter_aot_action(
        ctx,
        gen_snapshot,
        kernel_dill,
        output,
        snapshot_kind,
        output_flag,
        strip = True,
        extra_flags = [],
        extra_outputs = [],
        mnemonic = "FlutterAot"):
    """Internal helper for all AOT compilation variants."""
    args = ctx.actions.args()
    args.add("--deterministic")
    args.add("--snapshot_kind=" + snapshot_kind)
    args.add(output_flag + "=" + output.path)

    if strip:
        args.add("--strip")

    args.add_all(extra_flags)
    args.add(kernel_dill)

    ctx.actions.run(
        executable = gen_snapshot,
        arguments = [args],
        inputs = depset(
            direct = [kernel_dill],
        ),
        outputs = [output] + extra_outputs,
        mnemonic = mnemonic,
        progress_message = "AOT compiling Flutter %s %s" % (snapshot_kind, ctx.label),
    )

def _has_gen_snapshot_flag(flags, name):
    """Whether `flags` already carries `name` (with or without `=value`).

    Args:
        flags: List of gen_snapshot flags.
        name: Flag name to look for.

    Returns:
        True if present.
    """
    for f in flags:
        if f == name or f.startswith(name + "="):
            return True
    return False

def flutter_aot_gen_snapshot_flags(ctx, strip):
    """Build gen_snapshot extra flags/outputs from a rule's AOT attrs.

    Shared by `flutter_application` and `flutter_aot_target` so the two cannot
    drift on `obfuscate`, `split_debug_info`, or `extra_gen_snapshot_options`.

    `--resolve-dwarf-paths` is deliberately omitted: it rewrites the DWARF
    script URIs to filesystem paths, which fails for the `org-dartlang-app:`
    multi-root URIs these rules compile under and would embed host paths in
    the debugging info. `--dwarf-stack-traces` keeps DWARF stack traces and
    `--save-debugging-info` keeps the split output without resolving paths.

    When `obfuscate` is set the returned `strip` is forced True: gen_snapshot
    embeds full DWARF debugging info carrying the original, unobfuscated names
    unless `--strip` is passed (it warns about this itself), so an unstripped
    "obfuscated" snapshot still leaks every class name.

    Args:
        ctx: Rule context carrying the AOT attributes.
        strip: Whether the caller would strip for the current compilation mode.

    Returns:
        A tuple of (extra_flags, extra_outputs, debug_info_output, strip).
    """
    extra_flags = list(ctx.attr.extra_gen_snapshot_options)
    extra_outputs = []
    debug_info_output = None

    if ctx.attr.obfuscate and not _has_gen_snapshot_flag(extra_flags, "--obfuscate"):
        extra_flags.append("--obfuscate")

    if ctx.attr.split_debug_info:
        debug_info_output = ctx.actions.declare_file(ctx.label.name + ".symbols")
        if not _has_gen_snapshot_flag(extra_flags, "--dwarf-stack-traces"):
            extra_flags.append("--dwarf-stack-traces")
        if not _has_gen_snapshot_flag(extra_flags, "--save-debugging-info"):
            extra_flags.append("--save-debugging-info=" + debug_info_output.path)
        extra_outputs.append(debug_info_output)

    if ctx.attr.obfuscate:
        strip = True

    if strip:
        # `--strip` is emitted from the action's `strip` parameter, so drop any
        # user-supplied spelling: the command line carries it exactly once.
        # `--no-strip` contradicts `obfuscate` (it would keep the unobfuscated
        # DWARF), so obfuscation wins over it.
        extra_flags = [
            f
            for f in extra_flags
            if f != "--strip" and (f != "--no-strip" or not ctx.attr.obfuscate)
        ]

    return extra_flags, extra_outputs, debug_info_output, strip

def flutter_aot_elf_action(ctx, gen_snapshot, kernel_dill, output, strip = True, extra_flags = [], extra_outputs = []):
    """AOT compile to ELF shared library. Used for Android, Linux, Windows."""
    _flutter_aot_action(ctx, gen_snapshot, kernel_dill, output, "app-aot-elf", "--elf", strip, extra_flags, extra_outputs, "FlutterAotElf")

def flutter_aot_macho_action(
        ctx,
        gen_snapshot,
        kernel_dill,
        output,
        strip = True,
        extra_flags = [],
        extra_outputs = [],
        install_name = "@rpath/App.framework/App",
        min_os_version = None,
        rpath = "@executable_path/Frameworks,@loader_path/Frameworks"):
    """AOT compile to Mach-O dylib. Used for macOS and iOS.

    Args:
        ctx: Rule context.
        gen_snapshot: gen_snapshot executable File.
        kernel_dill: Kernel .dill input.
        output: Output dylib File.
        strip: Whether to strip debug symbols.
        extra_flags: Additional gen_snapshot flags.
        extra_outputs: Additional output Files (e.g. debug info).
        install_name: Mach-O LC_ID_DYLIB install name.
        min_os_version: Optional minimum OS version for LC_BUILD_VERSION.
        rpath: Comma-separated LC_RPATH entries to embed in the Mach-O dylib.
    """
    macho_flags = list(extra_flags)
    macho_flags.append("--macho-install-name=" + install_name)
    if min_os_version:
        macho_flags.append("--macho-min-os-version=" + min_os_version)
    if rpath:
        macho_flags.append("--macho-rpath=" + rpath)
    _flutter_aot_action(ctx, gen_snapshot, kernel_dill, output, "app-aot-macho-dylib", "--macho", strip, macho_flags, extra_outputs, "FlutterAotMacho")
