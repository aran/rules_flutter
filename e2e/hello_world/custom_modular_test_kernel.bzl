"""Custom kernels over the public modular `flutter:utils.bzl` helpers.

The `flutter_modular_test_kernel` / `flutter_modular_app_kernel` docstrings'
examples as running targets: instead of `flutter_test` compiling the suite,
`custom_modular_test_kernel` writes the bootstrap with the same protocol the
built-in modular path uses, compiles it as one entry module against the
dependency outlines, links it, and exposes the products as the `test_kernel` /
`test_base_kernel` output groups `flutter_prebuilt_test` feeds on. By default
the link is complete and the test runs with no `base_dill`; with
`use_base_dill = True` the kernel delta-links against the `flutter_test` base
dill, which must then reach `flutter_prebuilt_test`'s `base_dill`.
`custom_modular_app_kernel` does the same
for an app entry point: it synthesizes the `package:` mapping for its own
sources, compiles them as the entry module, and links everything with the
debug platform dill prepended.

Loads are public only (`@rules_flutter//flutter:utils.bzl`). The `deps` attr
(with `flutter_kernel_module_aspect` — the same aspect object the built-in
rules use — applied), the kernel tools, and the transition allowlist all come
from `FLUTTER_MODULAR_KERNEL_ATTRS`, so neither rule declares a private-named
attribute of its own.
"""

load(
    "@rules_flutter//flutter:utils.bzl",
    "FLUTTER_MODULAR_KERNEL_ATTRS",
    "FLUTTER_MODULAR_KERNEL_TOOLCHAINS",
    "FLUTTER_TEST_BOOTSTRAP_ATTRS",
    "flutter_modular_app_kernel",
    "flutter_modular_test_kernel",
)

def _custom_modular_test_kernel_impl(ctx):
    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    base_dill = flutter_modular_test_kernel(
        ctx,
        test_uri = "package:modular_suite/widget_test.dart",
        deps = ctx.attr.deps,
        output = kernel_dill,
        use_base_dill = ctx.attr.use_base_dill,
    )
    return [
        DefaultInfo(files = depset([kernel_dill])),
        # The kernel links no base dill under the default complete link (or
        # when no dependency carries one), so `test_base_kernel` is empty
        # rather than absent then — the same shape a `flutter_test` that
        # linked no base dill exposes.
        OutputGroupInfo(
            test_kernel = depset([kernel_dill]),
            test_base_kernel = depset([base_dill]) if base_dill else depset(),
        ),
    ]

custom_modular_test_kernel = rule(
    implementation = _custom_modular_test_kernel_impl,
    attrs = {
        "use_base_dill": attr.bool(
            doc = "Delta-link against the shared `flutter_test` base dill " +
                  "instead of linking a complete kernel. The linked base " +
                  "must then reach `flutter_prebuilt_test`'s `base_dill`.",
            default = False,
        ),
    } | FLUTTER_MODULAR_KERNEL_ATTRS | FLUTTER_TEST_BOOTSTRAP_ATTRS,
    toolchains = FLUTTER_MODULAR_KERNEL_TOOLCHAINS,
)

def _custom_modular_app_kernel_impl(ctx):
    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_modular_app_kernel(
        ctx,
        main = ctx.file.main,
        package_name = "hello_world",
        srcs = ctx.files.srcs,
        deps = ctx.attr.deps,
        output = kernel_dill,
    )
    return [DefaultInfo(files = depset([kernel_dill]))]

custom_modular_app_kernel = rule(
    implementation = _custom_modular_app_kernel_impl,
    attrs = {
        "main": attr.label(mandatory = True, allow_single_file = [".dart"]),
        "srcs": attr.label_list(allow_files = [".dart"]),
    } | FLUTTER_MODULAR_KERNEL_ATTRS,
    toolchains = FLUTTER_MODULAR_KERNEL_TOOLCHAINS,
)
