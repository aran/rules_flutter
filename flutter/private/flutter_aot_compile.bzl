"""Flutter AOT compilation action using gen_snapshot.

gen_snapshot converts a kernel .dill file into native code.
Output format depends on the target platform:
- Android/Linux/Windows: ELF shared library (app.so) via --snapshot_kind=app-aot-elf
- macOS/iOS: Mach-O dylib (App.framework/App) via --snapshot_kind=app-aot-macho-dylib
"""

def _flutter_aot_action(
        ctx,
        gen_snapshot,
        flutter_sdk_files,
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
            transitive = [flutter_sdk_files],
        ),
        outputs = [output] + extra_outputs,
        mnemonic = mnemonic,
        progress_message = "AOT compiling Flutter %s %s" % (snapshot_kind, ctx.label),
    )

def flutter_aot_elf_action(ctx, gen_snapshot, flutter_sdk_files, kernel_dill, output, strip = True, extra_flags = [], extra_outputs = []):
    """AOT compile to ELF shared library. Used for Android, Linux, Windows."""
    _flutter_aot_action(ctx, gen_snapshot, flutter_sdk_files, kernel_dill, output, "app-aot-elf", "--elf", strip, extra_flags, extra_outputs, "FlutterAotElf")

def flutter_aot_macho_action(
        ctx,
        gen_snapshot,
        flutter_sdk_files,
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
        flutter_sdk_files: SDK support files.
        kernel_dill: Kernel .dill input.
        output: Output dylib File.
        strip: Whether to strip debug symbols.
        extra_flags: Additional gen_snapshot flags.
        extra_outputs: Additional output Files (e.g. debug info).
        install_name: Mach-O LC_ID_DYLIB install name.
        min_os_version: Minimum OS deployment target (e.g. "13.0" for iOS, "10.14" for macOS).
        rpath: Comma-separated rpath entries for LC_RPATH.
    """
    macho_flags = list(extra_flags)
    macho_flags.append("--macho-install-name=" + install_name)
    if min_os_version:
        macho_flags.append("--macho-min-os-version=" + min_os_version)
    if rpath:
        macho_flags.append("--macho-rpath=" + rpath)
    _flutter_aot_action(ctx, gen_snapshot, flutter_sdk_files, kernel_dill, output, "app-aot-macho-dylib", "--macho", strip, macho_flags, extra_outputs, "FlutterAotMacho")
