"""What a `native_deps` entry's libraries were linked from, for their dSYMs.

An Apple library holds no DWARF of its own: its debugging map names the object
files and static archives the linker read, and `dsymutil` reads the DWARF out
of those. An action making the library's dSYM needs them as inputs, and only
the action that linked the library knows them all: a `cc_shared_library` links
in less than its `deps` reach when `dynamic_deps` supply part of them.

They are found on rules_dart's terms, as `dart_code_asset` finds a code
asset's: what a target states in `DartLinkInputsInfo` comes first, then a code
asset's `link_inputs`, then the inputs of the C++ action that linked the
library. A `rust_shared_library` is linked inside its `Rustc` action from
objects the action deletes, so its dSYM is the one rustc makes there
(`link_of_actions`). A wrapper
whose action copies the library unchanged (`copy_file`), or that has no action
of its own (`filegroup`, `flutter_native_library`), passes on what the library
below it was linked from. Any other action that writes a library, a genrule
that strips or renames one, say, leaves the link unknown, with
`link_inputs_unset_reason` saying why: its output need not carry the debugging
map of what it read. The inputs stay a depset: nothing is flattened until an
action runs.

The aspect is applied to `native_deps` edges only, and follows nothing but the
attributes a wrapper takes its library by, so it visits the few targets
between an entry and the action that linked its library. A code asset's link
is rules_dart's `DartCodeAssetInfo.link_inputs`, read off the asset itself.
"""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartLinkInputsInfo")
load("//flutter/private:constants.bzl", "SHARED_LIBRARY_EXTENSIONS")
load("//flutter/private:rule_edges.bzl", "rule_attr_targets")

visibility("//flutter/...")

NativeLinkInfo = provider(
    doc = "What the native libraries at or below this target were linked from, or the dSYM their link made.",
    fields = {
        "link_inputs": "depset[File] or None: What they were linked from. None when the link cannot be seen, or `dsym` is set.",
        "dsym": "File or None: The `.dSYM` directory the action that linked them made, which is their dSYM as it is.",
        "link_inputs_unset_reason": "str or None: Why `link_inputs` and `dsym` are None, and what to do about it.",
    },
)

# The attributes a wrapper takes the library it passes on by, which is all the
# link is followed through: a `flutter_native_library`'s `library`, a
# `dart_code_asset`'s `file`, a `filegroup`'s or genrule's `srcs`, a
# `copy_file`'s `src`.
_LIBRARY_ATTRS = ["library", "file", "srcs", "src"]

# The actions that link a library with a C++ toolchain, as rules_dart counts them.
LINK_MNEMONICS = ("CppLink", "ObjcLink")

# rules_rust's action, in which rustc compiles a crate and links the library.
RUST_MNEMONIC = "Rustc"

# The actions that write a library unchanged: its debugging map is the one of
# the library they read.
COPY_MNEMONICS = ("CopyFile", "Symlink", "SolibSymlink")

def _known(link_inputs = None, dsym = None):
    return struct(link_inputs = link_inputs, dsym = dsym, link_inputs_unset_reason = None)

def _unknown(reason):
    return struct(link_inputs = None, dsym = None, link_inputs_unset_reason = reason)

def link_of_actions(label, actions, rust_dsym = None):
    """What the libraries the `actions` write were linked from.

    A `Rustc` action links its library from object files it makes and deletes
    in the action, so its debugging map names files no other action can read.
    On macOS rustc runs `dsymutil` itself before deleting them, and rules_rust
    declares the result (`rust_dsym`), which is the library's dSYM as it is.
    Without one (rules_rust declares none for iOS), nothing in the build holds
    the library's line tables, and its dSYM can hold its symbol table only:
    its `link_inputs` are empty, as a prebuilt library's are.

    Args:
      label: The Label of the target the actions are of, for the reason.
      actions: Its actions, each with `mnemonic`, `inputs` and `outputs`.
      rust_dsym: The target's `dsym_folder` output, as rules_rust names it,
        or None.

    Returns:
      A struct of `link_inputs`, `dsym` and `link_inputs_unset_reason`, as
      `NativeLinkInfo` has them, or None when no action writes a library or
      every one that does copies it.
    """
    linked = []
    rust = False
    for action in actions:
        if not any([f.extension in SHARED_LIBRARY_EXTENSIONS for f in action.outputs.to_list()]):
            continue
        if action.mnemonic in LINK_MNEMONICS:
            linked.append(action.inputs)
        elif action.mnemonic == RUST_MNEMONIC:
            rust = True
        elif action.mnemonic not in COPY_MNEMONICS:
            return _unknown((
                "%s writes a library with a `%s` action, which does not link it, so what it " +
                "was linked from is unknown. Name the target that links it, or have %s " +
                "return DartLinkInputsInfo."
            ) % (label, action.mnemonic, label))
    if rust and linked:
        return _unknown("%s links libraries with both rustc and a C++ toolchain; name the target of each." % label)
    if rust:
        return _known(dsym = rust_dsym) if rust_dsym != None else _known(link_inputs = depset())
    if linked:
        return _known(link_inputs = depset(transitive = linked))
    return None

def _rust_dsym(target):
    if OutputGroupInfo not in target or not hasattr(target[OutputGroupInfo], "dsym_folder"):
        return None
    folders = target[OutputGroupInfo].dsym_folder.to_list()
    return folders[0] if len(folders) == 1 else None

def _link(target, ctx):
    """What the libraries of `target` were linked from, as `NativeLinkInfo` has it."""

    # What a library was linked from that is gone (`gone`, rustc's deleted
    # objects) leaves its symbol table to make its dSYM of, as a `Rustc`
    # action without rustc's dSYM does here.
    if DartLinkInputsInfo in target:
        stated = target[DartLinkInputsInfo]
        return _known(link_inputs = depset() if stated.gone else stated.inputs)
    if DartCodeAssetInfo in target and target[DartCodeAssetInfo].file != None:
        asset = target[DartCodeAssetInfo]
        if asset.dsym != None:
            return _known(dsym = asset.dsym)
        if asset.link_inputs != None:
            return _known(link_inputs = asset.link_inputs)
        if asset.link_inputs_gone:
            return _known(link_inputs = depset())
        return _unknown(asset.link_inputs_unset_reason)

    found = link_of_actions(target.label, target.actions, _rust_dsym(target))
    if found != None:
        return found

    below = []
    for dep in rule_attr_targets(ctx.rule.attr, _LIBRARY_ATTRS):
        if NativeLinkInfo in dep:
            below.append(dep[NativeLinkInfo])
    for info in below:
        if info.link_inputs == None and info.dsym == None:
            return info
    if len(below) == 1:
        return below[0]
    if below:
        if any([info.dsym != None for info in below]):
            return _unknown("%s passes on several libraries, one of them with the dSYM its link made; name each library on its own." % target.label)
        return _known(link_inputs = depset(transitive = [info.link_inputs for info in below]))
    return _unknown((
        "found no action linking the libraries of %s, nor a target below it that does. " +
        "Name the target that links them, or have %s return DartLinkInputsInfo."
    ) % (target.label, target.label))

def _native_link_aspect_impl(target, ctx):
    found = _link(target, ctx)
    return [NativeLinkInfo(
        link_inputs = found.link_inputs,
        dsym = found.dsym,
        link_inputs_unset_reason = found.link_inputs_unset_reason,
    )]

native_link_aspect = aspect(
    implementation = _native_link_aspect_impl,
    attr_aspects = _LIBRARY_ATTRS,
    # A label naming the library file itself reaches the rule that wrote it.
    apply_to_generating_rules = True,
    doc = "Gives each target from a `native_deps` entry down to its library's link what that library was linked from.",
)
