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
# the files of `rewrite_install_names` from $5 on, each followed by the
# install name it moves to.
_INSTALL_NAME_TOOL = """\
changes=()
seen=$'\\n'
for ((i = 5; i < $#; i += 2)); do
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

def process_native_library(ctx, library, output, symbols, mnemonic, dsym = None, install_name = None, install_name_changes = None):
    """Registers the action that makes the copy of `library` an Apple app bundles.

    As `flutter build` treats a native asset (`native_assets_host.dart`):
    `dsymutil` reads the dSYM out of the copy first, then `strip -x -S`
    removes its local symbols and debugging map. The UUID is unchanged, so a
    crash in the shipped library symbolicates against the dSYM.

    The library's debugging map is dropped before the dSYM is made: it names
    object files that are not inputs of this action (a pub package's build
    hook compiled them in an action of its own), so `dsymutil` would read them
    when it ran unsandboxed and not otherwise. The dSYM holds the library's
    symbol table, which names every function a crash report can land in.

    Args:
      ctx: A rule context with `XCODE_TOOL_ATTRS`.
      library: The library File.
      output: The File to write.
      symbols: A `native_library_symbols` struct.
      mnemonic: The action's mnemonic.
      dsym: A `declare_library_dsym` struct, when `symbols.dsym`.
      install_name: None, or the install name to give the copy.
      install_name_changes: None, or a `rewrite_install_names` struct of the
        libraries bundled with this one, whose links to them the copy has
        rewritten. Needs `install_name`.
    """

    # $1 the library, $2 the copy, $3 its install name, $4 its dSYM's plist,
    # and from $5 the install-name changes.
    args = ctx.actions.args().add_all([library, output])
    args.add(install_name or "")
    args.add_all([dsym.plist] if dsym else [""])
    commands = [
        "set -e",
        'cp "$1" "$2"',
        'chmod u+w "$2"',
    ]
    inputs = [library]
    outputs = [output]
    if install_name_changes:
        if not install_name:
            fail("install_name_changes needs an install_name")
        args.add_all(install_name_changes.pairs)
        inputs.extend(install_name_changes.inputs)
    if install_name:
        commands.append(_INSTALL_NAME_TOOL)
    if dsym:
        # dsymutil reads a copy without the debugging map (the stabs `strip -S`
        # removes), named as the shipped binary is, as its DWARF file is.
        commands.extend([
            'bundle="$(dirname "$(dirname "$4")")"',
            'scratch="$bundle.input"',
            'mkdir -p "$scratch"',
            'xcrun strip -S "$2" -o "$scratch/$(basename "$2")"',
            # It warns that the copy has no debugging map, which it has not
            # by design; anything else it says is passed on.
            'out="$(xcrun dsymutil -o "$bundle" "$scratch/$(basename "$2")" 2>&1)" || { echo "$out" >&2; exit 1; }',
            'out="$(echo "$out" | grep -v "no debug symbols in executable" || true)"',
            '[ -z "$out" ] || echo "$out" >&2',
            'rm -rf "$scratch"',
        ])
        outputs.extend(dsym.files)
    if symbols.strip:
        commands.append('xcrun strip -x -S "$2" -o "$2"')
    run_xcode_tool(
        ctx,
        command = "\n".join(commands),
        arguments = [args],
        inputs = inputs,
        outputs = outputs,
        mnemonic = mnemonic,
        execution_requirements = PATH_MAPPING,
        progress_message = "Preparing %s for the bundle%s" % (
            library.basename,
            " with its dSYM" if dsym else "",
        ),
    )
