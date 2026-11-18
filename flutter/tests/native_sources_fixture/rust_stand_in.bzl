"""A library written as rules_rust's `rust_shared_library` writes one, for `native_link_test`.

rustc compiles the crate and links the library in one `Rustc` action, and on
macOS writes the library's dSYM there too, which rules_rust hands out as the
`dsym_folder` output group. This has that shape, so the test needs no Rust
toolchain: the link aspect reads only the action's mnemonic and outputs and
the output group.
"""

def _rust_stand_in_impl(ctx):
    library = ctx.actions.declare_file("lib%s.dylib" % ctx.label.name)
    outputs = [library]
    groups = {}
    if ctx.attr.dsym:
        dsym = ctx.actions.declare_directory(library.basename + ".dSYM", sibling = library)
        outputs.append(dsym)
        groups["dsym_folder"] = depset([dsym])
    ctx.actions.run_shell(
        command = "touch " + " ".join([f.path for f in outputs]),
        inputs = [ctx.file.src],
        outputs = outputs,
        mnemonic = "Rustc",
    )
    return [DefaultInfo(files = depset([library])), OutputGroupInfo(**groups)]

rust_stand_in = rule(
    implementation = _rust_stand_in_impl,
    attrs = {
        "src": attr.label(allow_single_file = True, mandatory = True, doc = "The crate root."),
        "dsym": attr.bool(doc = "Whether rustc writes the library's dSYM, as on macOS."),
    },
)
