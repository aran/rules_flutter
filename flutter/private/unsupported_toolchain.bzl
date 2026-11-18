"""A toolchain for a target rules_flutter does not build, which fails saying why.

Without one, a build for such a target stops at toolchain resolution with "No
matching toolchains found", which names the toolchain type and not the cause.
Registered after every real toolchain, it is chosen only where none applies.
"""

visibility("//flutter/...")

def _flutter_unsupported_toolchain_impl(ctx):
    fail(ctx.attr.message)

flutter_unsupported_toolchain = rule(
    implementation = _flutter_unsupported_toolchain_impl,
    attrs = {
        "message": attr.string(
            doc = "Why the target is not supported, and what to build instead.",
            mandatory = True,
        ),
    },
    doc = "Fails analysis with `message` when a build resolves it.",
)
