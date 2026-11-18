"""Actions that run Xcode's tools on an Apple target's AOT snapshot.

Shared by the iOS and macOS framework rules: both ship gen_snapshot's Mach-O
dylib as `App.framework/App`, and both treat it the way `flutter build`
does (`flutter_tools/lib/src/base/build.dart`): the dSYM is extracted from the
snapshot with `dsymutil`, and then `strip -x` removes the local symbols the
shipped binary does not need, unless `--no-strip` is among the application's
`extra_gen_snapshot_options`.
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE", "use_cc_toolchain")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")

visibility("//flutter/...")

# The attributes and toolchains a rule needs to call `run_xcode_tool`.
XCODE_TOOL_ATTRS = dicts.add(
    apple_support.action_required_attrs(),
    apple_support.platform_constraint_attrs(),
)
XCODE_TOOL_TOOLCHAINS = use_cc_toolchain(mandatory = True)
XCODE_TOOL_FRAGMENTS = ["apple"]

def run_xcode_tool(ctx, **kwargs):
    """Registers a shell action that runs Xcode's tools (`xcrun`).

    `apple_support.run_shell` gives the action the selected Xcode's
    environment (`DEVELOPER_DIR`, `SDKROOT`) and execution requirements, so the
    Xcode version is part of the action's key. The workspace's shell
    environment is left out: an `--action_env` such as
    `MACOSX_DEPLOYMENT_TARGET` would otherwise retarget clang. The action runs
    in the auto exec group of the C++ toolchain resolved for this Apple target:
    that toolchain is Xcode's clang, and its registration says which hosts can
    run Xcode.

    Args:
      ctx: A rule context with `XCODE_TOOL_ATTRS`, `XCODE_TOOL_FRAGMENTS` and
        `XCODE_TOOL_TOOLCHAINS`.
      **kwargs: Forwarded to `ctx.actions.run_shell`.
    """
    apple_support.run_shell(
        actions = ctx.actions,
        xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
        apple_platform_info = apple_support.platform_info_from_rule_ctx(ctx),
        toolchain = CC_TOOLCHAIN_TYPE,
        use_default_shell_env = False,
        **kwargs
    )

def declare_dsym(ctx, directory):
    """Declares the files of an `App.framework.dSYM` bundle.

    The bundle is declared as the two files `dsymutil` writes into it, not as
    a tree artifact, because that is the form rules_apple takes a framework's
    `dsym_imports` in.

    Args:
      ctx: A rule context.
      directory: The package-relative directory the bundle is declared in.

    Returns:
      A struct of `plist`, `dwarf` and `files`.
    """
    bundle = "%s/App.framework.dSYM" % directory
    plist = ctx.actions.declare_file(bundle + "/Contents/Info.plist")
    dwarf = ctx.actions.declare_file(bundle + "/Contents/Resources/DWARF/App")
    return struct(plist = plist, dwarf = dwarf, files = [plist, dwarf])

def split_and_strip_aot_binary(
        ctx,
        dylib,
        object,
        binary,
        dsym,
        strip = True,
        retag = None):
    """Registers the action that makes the shipped `App` and its dSYM.

    Order matters: the dSYM is read out of the snapshot before `strip -x`
    removes what it is read from. `dsymutil` follows the snapshot's debugging
    map to `object`, the relocatable object gen_snapshot wrote beside it, so
    that has to be an input at the path gen_snapshot recorded.

    The binary's UUID is the same before and after, so crash reports of the
    shipped binary symbolicate against the dSYM.

    Args:
      ctx: A rule context with `XCODE_TOOL_ATTRS`.
      dylib: gen_snapshot's dylib, symbols intact.
      object: The relocatable object gen_snapshot wrote with it.
      binary: The `App` File to write.
      dsym: A `declare_dsym` struct.
      strip: Whether to `strip -x` the binary. False keeps its local symbols,
        as `flutter build` does with `--no-strip`; the dSYM is made either way.
      retag: None, or a pair of the `vtool` platform and the minimum OS
        version to tag the binary with, for a dylib gen_snapshot tagged as
        macOS (the host it ran on) that is for another platform.
    """
    if object == None:
        fail(
            ("%s: the application provides no gen_snapshot object, so no " +
             "dSYM can be extracted from its snapshot. It is produced by a " +
             "flutter_application built for an Apple platform in release or " +
             "profile mode.") % ctx.label,
        )
    args = ctx.actions.args().add_all([dylib, binary, dsym.plist])
    commands = [
        "set -e",
        'cp "$1" "$2"',
        # An input is read-only, and so is this copy of it.
        'chmod u+w "$2"',
        # Run on the copy: the DWARF file in the bundle is named for the file
        # it is read from, and it is `App`.
        'xcrun dsymutil -o "$(dirname "$(dirname "$3")")" "$2"',
    ]
    if retag:
        args.add_all(retag)
        commands.append('xcrun vtool -set-build-version "$4" "$5" "$5" -replace -output "$2" "$2"')
    if strip:
        commands.append('xcrun strip -x "$2" -o "$2"')
    run_xcode_tool(
        ctx,
        command = "\n".join(commands),
        arguments = [args],
        inputs = [dylib, object],
        outputs = [binary] + dsym.files,
        mnemonic = "FlutterAppleSplitDebugInfo",
        execution_requirements = PATH_MAPPING,
        progress_message = "Extracting the dSYM of %s%s" % (binary.short_path, " and stripping it" if strip else ""),
    )

AppleBinaryStrippingInfo = provider(
    doc = "Whether the build strips an Apple app's binary, as rules_apple does.",
    fields = {"strip": "True with `--objc_enable_binary_stripping` in `-c opt`."},
)

def _apple_binary_stripping_impl(ctx):
    return [AppleBinaryStrippingInfo(strip = ctx.attr.strip)]

# The command line's stripping, which Bazel keeps from Starlark rules: a
# `config_setting` reads it, and this target hands it on.
apple_binary_stripping = rule(
    implementation = _apple_binary_stripping_impl,
    attrs = {"strip": attr.bool(mandatory = True)},
    doc = "Provides `AppleBinaryStrippingInfo`: a `select` on the stripping flags sets `strip`.",
)

# The attribute `native_library_symbols` reads, beside `XCODE_TOOL_ATTRS`.
NATIVE_LIBRARY_SYMBOLS_ATTRS = {
    "_apple_binary_stripping": attr.label(
        default = Label("//flutter/private:apple_binary_stripping"),
        providers = [AppleBinaryStrippingInfo],
    ),
}

def native_library_symbols(ctx):
    """What the build asks of a native library an Apple app bundles beside its binary.

    The conditions rules_apple applies to the app's own binary, so a library
    the bundle carries is treated as the binary it is linked beside:
    `--apple_generate_dsym` makes its dSYM, and `--objc_enable_binary_stripping`
    in `-c opt` strips its local symbols and debugging map. `flutter build`
    does both in every release build, upstream's one way to build one.

    Args:
      ctx: A rule context with the `cpp` fragment and `NATIVE_LIBRARY_SYMBOLS_ATTRS`.

    Returns:
      A struct of `dsym` and `strip`, booleans.
    """
    return struct(
        dsym = ctx.fragments.cpp.apple_generate_dsym,
        strip = ctx.attr._apple_binary_stripping[AppleBinaryStrippingInfo].strip,
    )

def declare_library_dsym(ctx, directory, bundle, binary_name):
    """Declares the files of the dSYM bundle `<directory>/<bundle>.dSYM` of `binary_name`.

    Args:
      ctx: A rule context.
      directory: The package-relative directory the bundle is declared in.
      bundle: The name the bundle is for: `libfoo.dylib`, `foo.framework`.
      binary_name: The binary's file name, which names its DWARF file.

    Returns:
      A struct of `plist`, `dwarf` and `files`, as `declare_dsym`.
    """
    path = "%s/%s.dSYM" % (directory, bundle)
    plist = ctx.actions.declare_file(path + "/Contents/Info.plist")
    dwarf = ctx.actions.declare_file(path + "/Contents/Resources/DWARF/" + binary_name)
    return struct(plist = plist, dwarf = dwarf, files = [plist, dwarf])

def read_install_names(ctx, library, output):
    """Registers the action that writes `library`'s install names to `output`.

    One a line, as `otool -D` reads them: one for each architecture, which
    need not agree; none for a file that is not a dylib. `rewrite_install_names`
    reads them back. Each is a file of its own, so a change to a library that
    keeps its install name reruns nothing that links it.

    Args:
      ctx: A rule context with `XCODE_TOOL_ATTRS`.
      library: The library File.
      output: The File to write.
    """
    run_xcode_tool(
        ctx,
        # The first line names the file, and so does the header of each
        # architecture of a universal binary.
        command = "\n".join([
            "set -e",
            'out="$(xcrun otool -D "$1")"',
            'printf "%s\\n" "$out" | tail -n +2 | { grep -v " (architecture .*):$" || true; } > "$2"',
        ]),
        arguments = [ctx.actions.args().add_all([library, output])],
        inputs = [library],
        outputs = [output],
        mnemonic = "FlutterAppleInstallNames",
        execution_requirements = PATH_MAPPING,
        progress_message = "Reading the install name of %s" % library.basename,
    )

def rewrite_install_names(ctx, directory, libraries):
    """The links between bundled libraries, to rewrite as each moves to its new install name.

    As `flutter build` does (`copyNativeCodeAssetsIOS`, `setInstallNamesDylib`):
    a library that links another records it by that library's install name
    when it was linked, `@rpath/libfoo.dylib`, say. Once `libfoo` ships as
    `foo.framework/foo` under the install name `@rpath/foo.framework/foo`,
    nothing has the old one, and the library that links it fails to load.
    So every library is given `-change <old> <new>` for each library bundled
    beside it (its own included, which changes nothing), from the old install
    names `read_install_names` reads when the libraries are built.

    Args:
      ctx: A rule context with `XCODE_TOOL_ATTRS`.
      directory: The package-relative directory to declare the install-name
        files in.
      libraries: Pairs of a library File and the install name it ships with,
        every library of one bundle.

    Returns:
      A struct of `inputs`, the files of the old install names, and `pairs`,
      which alternates each of those files with the install name it moves to,
      for `process_native_library`'s `install_name_changes`.
    """
    inputs = []
    pairs = []
    for library, install_name in libraries:
        names = ctx.actions.declare_file("%s/%s.install_names" % (directory, install_name.split("/")[-1]))
        read_install_names(ctx, library, names)
        inputs.append(names)
        pairs.extend([names, install_name])
    return struct(inputs = inputs, pairs = pairs)

# Sets $2's install name to $3, and changes its links to the libraries named in
# the files of `rewrite_install_names` from $6 on, each followed by the
# install name it moves to.
_INSTALL_NAME_TOOL = """\
changes=()
seen=$'\\n'
for ((i = 6; i < $#; i += 2)); do
  j=$((i + 1))
  new="${!j}"
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    case "$seen" in
      *$'\\n'"$old -> $new"$'\\n'*) continue ;;
      *$'\\n'"$old -> "*)
        echo "Two of the libraries bundled with $(basename "$1") have the install name $old" >&2
        exit 1 ;;
    esac
    seen="$seen$old -> $new"$'\\n'
    changes+=(-change "$old" "$new")
  done < "${!i}"
done
xcrun install_name_tool -id "$3" "${changes[@]}" "$2"
"""

def process_native_library(ctx, library, output, symbols, mnemonic, dsym = None, debug_info = None, install_name = None, install_name_changes = None):
    """Registers the action that makes the copy of `library` an Apple app bundles.

    As `flutter build` treats a native asset (`native_assets_host.dart`):
    `dsymutil` reads the dSYM out of the copy first, then `strip -x -S`
    removes its local symbols and debugging map. The UUID is unchanged, so a
    crash in the shipped library symbolicates against the dSYM.

    A library holds no DWARF of its own. Its debugging map names the object
    files and static archives it was linked from, and `dsymutil` reads the
    DWARF out of those, so they are inputs of the action, `link_inputs`: the
    dSYM then has the line tables a crash report's `file:line` comes from. A
    debugging map naming a file that is not among them fails the action,
    because the dSYM would silently lack that file's lines.

    A library whose link made its dSYM, as rustc makes a `rust_shared_library`'s
    from objects it deletes in the same action, has that dSYM copied, named
    as the shipped binary is. Its UUID must be the library's. An empty one,
    from a compile without debug information, leaves the symbol table's.

    A prebuilt library, one whose `link_inputs` are empty, was linked
    somewhere else, and the files its debugging map names are not in the
    build. Its map is dropped first, and its dSYM holds its symbol table,
    which names every function a crash report can land in.

    The dSYM is read from the copy before anything strips it: `strip -S` or
    `strip -x` leaves a binary no line table can be read from.

    Args:
      ctx: A rule context with `XCODE_TOOL_ATTRS`.
      library: The library File.
      output: The File to write.
      symbols: A `native_library_symbols` struct.
      mnemonic: The action's mnemonic.
      dsym: A `declare_library_dsym` struct, when `symbols.dsym`.
      debug_info: With `dsym`, what it is made from, as
        `bundled_library_debug_info` gives it: `link_inputs`, a depset of what
        `library` was linked from (`DartCodeAssetInfo.link_inputs`, or a
        `native_deps` library's, `native_link_aspect.bzl`), empty for a
        prebuilt library; or `dsym`, the dSYM its link made.
      install_name: None, or the install name to give the copy.
      install_name_changes: None, or a `rewrite_install_names` struct of the
        libraries bundled with this one, whose links to them the copy has
        rewritten. Needs `install_name`.
    """

    # $1 the library, $2 the copy, $3 its install name, $4 its dSYM's plist,
    # $5 the dSYM its link made, and from $6 the install-name changes.
    if dsym and debug_info == None:
        fail("%s: the dSYM of %s needs what it was linked from" % (ctx.label, library.short_path))
    prebuilt_dsym = debug_info.dsym if dsym else None
    link_inputs = debug_info.link_inputs if dsym else None
    args = ctx.actions.args().add_all([library, output])
    args.add(install_name or "")
    args.add_all([dsym.plist] if dsym else [""])
    args.add_all([prebuilt_dsym] if prebuilt_dsym else [""], expand_directories = False)
    commands = [
        "set -e",
        'cp "$1" "$2"',
        'chmod u+w "$2"',
    ]
    inputs = [library]
    transitive_inputs = []
    outputs = [output]

    # Path mapping would move the files the debugging map names away from the
    # paths it names them by.
    execution_requirements = PATH_MAPPING
    if install_name_changes:
        if not install_name:
            fail("install_name_changes needs an install_name")
        args.add_all(install_name_changes.pairs)
        inputs.extend(install_name_changes.inputs)
    if install_name:
        commands.append(_INSTALL_NAME_TOOL)

    # dsymutil reads a copy without the debugging map (the stabs `strip -S`
    # removes), named as the shipped binary is, as its DWARF file is.
    symbol_table_dsym = [
        'bundle="$(dirname "$(dirname "$4")")"',
        'scratch="$bundle.input"',
        'mkdir -p "$scratch"',
        'xcrun strip -S "$2" -o "$scratch/$(basename "$2")"',
        # It warns that the copy has no debugging map, which it has not by
        # design; anything else it says is passed on.
        'out="$(xcrun dsymutil -o "$bundle" "$scratch/$(basename "$2")" 2>&1)" || { echo "$out" >&2; exit 1; }',
        'out="$(echo "$out" | grep -v "no debug symbols in executable" || true)"',
        '[ -z "$out" ] || echo "$out" >&2',
        'rm -rf "$scratch"',
    ]
    if prebuilt_dsym:
        inputs.append(prebuilt_dsym)

        # rustc leaves its dSYM empty when it compiled with no debug
        # information, as rules_rust does outside `-c dbg`: the library's
        # dSYM is then its symbol table's, as a prebuilt's is.
        commands.extend([
            'if [ -z "$(ls -A "$5")" ]; then',
        ] + ["  " + c for c in symbol_table_dsym] + [
            "else",
            '  dwarf=("$5"/Contents/Resources/DWARF/*)',
            '  [ "${#dwarf[@]}" -eq 1 ] && [ -f "${dwarf[0]}" ] || { echo "$5 holds no single DWARF file" >&2; exit 1; }',
            '  want="$(xcrun dwarfdump --uuid "$2" | cut -d" " -f2 | sort)"',
            '  have="$(xcrun dwarfdump --uuid "${dwarf[0]}" | cut -d" " -f2 | sort)"',
            '  [ -n "$want" ] && [ "$want" = "$have" ] || { echo "$5 (UUID $have) is not the dSYM of $(basename "$1") (UUID $want)" >&2; exit 1; }',
            '  mkdir -p "$(dirname "$4")/Resources/DWARF"',
            '  cp "$5/Contents/Info.plist" "$4"',
            '  cp "${dwarf[0]}" "$(dirname "$4")/Resources/DWARF/$(basename "$2")"',
            "fi",
        ])
        outputs.extend(dsym.files)
    elif dsym and not link_inputs:
        commands.extend(symbol_table_dsym)
        outputs.extend(dsym.files)
    elif dsym:
        transitive_inputs.append(link_inputs)
        execution_requirements = {}

        # Its DWARF file is named for the file it is read from, the copy,
        # named as the shipped binary is. A library compiled without debug
        # information has no debugging map, which it says, and that is all it
        # may say: a file of the map it cannot read is a missing input.
        commands.extend([
            'out="$(xcrun dsymutil -o "$(dirname "$(dirname "$4")")" "$2" 2>&1)" || { echo "$out" >&2; exit 1; }',
            'out="$(echo "$out" | grep -v "no debug symbols in executable" || true)"',
            'if [ -n "$out" ]; then',
            '  echo "$out" >&2',
            '  echo "dsymutil could not read all of $(basename "$1")\'s debug information: the files its debugging map names must be inputs of this action." >&2',
            "  exit 1",
            "fi",
        ])
        outputs.extend(dsym.files)
    if symbols.strip:
        commands.append('xcrun strip -x -S "$2" -o "$2"')
    run_xcode_tool(
        ctx,
        command = "\n".join(commands),
        arguments = [args],
        inputs = depset(inputs, transitive = transitive_inputs),
        outputs = outputs,
        mnemonic = mnemonic,
        execution_requirements = execution_requirements,
        progress_message = "Preparing %s for the bundle%s" % (
            library.basename,
            " with its dSYM" if dsym else "",
        ),
    )
