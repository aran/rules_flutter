"""Runs an already built Flutter test kernel under `flutter_tester`.

The Tier-2 half of `flutter_test`: where `flutter_test` compiles the test
entrypoint to a kernel `.dill` and then runs it, this rule only runs one. The
compile pipeline is the caller's — a `flutter_test`'s `test_kernel` output
group, or a custom compile over `flutter_test_bootstrap` from
`@rules_flutter//flutter:utils.bzl` — and this target's own actions contain no
compile at all, so a kernel rebuild never invalidates a cached test run.

The runner, protocol, env contract, JUnit XML and golden handling are
`flutter_test`'s: both rules set up their run through
`//flutter/private:flutter_test_common.bzl`.

Usage: feed it a `flutter_test`'s output groups, one filegroup per attr:

```starlark
filegroup(
    name = "widget_test_kernel",
    srcs = [":widget_test"],
    output_group = "test_kernel",
)

filegroup(
    name = "widget_test_assets",
    srcs = [":widget_test"],
    output_group = "test_assets",
)

flutter_prebuilt_test(
    name = "widget_prebuilt_test",
    dill = ":widget_test_kernel",
    assets = ":widget_test_assets",
)
```
"""

load("//flutter/private:flutter_test_common.bzl", "flutter_test_runner")

def _flutter_prebuilt_test_impl(ctx):
    if len(ctx.files.base_dill) > 1:
        fail("%s: base_dill holds at most one .dill, got %s." % (
            ctx.label,
            [f.short_path for f in ctx.files.base_dill],
        ))
    base_dill = ctx.files.base_dill[0] if ctx.files.base_dill else None
    if base_dill != None and not base_dill.path.endswith(".dill"):
        fail("%s: base_dill must be a .dill file, got %s." % (
            ctx.label,
            base_dill.short_path,
        ))
    runner = flutter_test_runner(
        ctx,
        dill = ctx.file.dill,
        base_dill = base_dill,
        assets_dir = ctx.file.assets,
        library_tags = ctx.file.library_tags,
        test_path = ctx.attr.test_path,
        enable_impeller = ctx.attr.enable_impeller,
        include_tags = ctx.attr.include_tags,
        exclude_tags = ctx.attr.exclude_tags,
        user_env = ctx.attr.env,
        data = ctx.attr.data,
    )
    return [
        DefaultInfo(
            executable = runner.executable,
            runfiles = runner.runfiles,
        ),
        runner.env,
    ]

flutter_prebuilt_test = rule(
    implementation = _flutter_prebuilt_test_impl,
    attrs = {
        "dill": attr.label(
            doc = "The already built test kernel `.dill` to run, e.g. a " +
                  "`flutter_test`'s `test_kernel` output group. Must be " +
                  "compiled from the `flutter_test_bootstrap` bootstrap " +
                  "library so it dials the test harness back at start-up.",
            mandatory = True,
            allow_single_file = [".dill"],
        ),
        "base_dill": attr.label_list(
            doc = "The base dill the kernel links against at run time " +
                  "(`FLUTTER_TEST_BASE_DILL`), e.g. a `flutter_test`'s " +
                  "`test_base_kernel` output group. A list so an empty " +
                  "output group feeds it directly: zero or one `.dill` " +
                  "file. Unset when the kernel was compiled whole-program.",
            allow_files = True,
        ),
        "assets": attr.label(
            doc = "The `flutter_assets/` tree the test resolves via " +
                  "`rootBundle`, e.g. a `flutter_test`'s `test_assets` " +
                  "output group or a `flutter_asset_bundle` with the " +
                  "test's shaders compiled for `flutter_tester`.",
            mandatory = True,
            allow_single_file = True,
        ),
        "library_tags": attr.label(
            doc = "The suite entrypoint's `@Tags` as a `{\"tags\": [...]}` " +
                  "JSON file, reaching every test through the suite's root " +
                  "group. Unset means the suite carries no library tags.",
            allow_single_file = True,
        ),
        "test_path": attr.string(
            doc = "Display path for the suite in `package:test` report " +
                  "output. Defaults to the dill's basename.",
        ),
        "data": attr.label_list(
            doc = "Runtime data deps. Available in test runfiles. Use for " +
                  "fixtures, goldens, and FFI dylibs. Golden PNGs must be " +
                  "listed here or the comparator cannot see them.",
            allow_files = True,
        ),
        "env": attr.string_dict(
            doc = "Extra environment variables for the test process. Values are " +
                  "literal — no Make-variable or $(location) expansion. The " +
                  "FLUTTER_TEST_* keys the runner reads cannot be set here; " +
                  "override tag selection at run time with " +
                  "--test_env=FLUTTER_TEST_TAGS=... instead.",
        ),
        "enable_impeller": attr.bool(
            doc = "Render with Impeller in flutter_tester, as `flutter test " +
                  "--enable-impeller` does, instead of software Skia.",
            default = False,
        ),
        "include_tags": attr.string_list(
            doc = "Run only tests matching every one of these `package:test` " +
                  "tag selectors (library, group or test level), as " +
                  "`flutter test --tags` intersects them. Each entry is a " +
                  "boolean selector (`a && b`, `a || b`, `!a`, parentheses); " +
                  "several entries, or comma-separated values in one entry, " +
                  "all have to match. A test matching an `exclude_tags` " +
                  "selector never runs. An attribute selection that matches " +
                  "no test fails the target.",
        ),
        "exclude_tags": attr.string_list(
            doc = "Skip tests matching any of these `package:test` tag " +
                  "selectors (library, group or test level), as `flutter " +
                  "test --exclude-tags` unions them. Wins over " +
                  "`include_tags`.",
        ),
        "_tool": attr.label(
            default = Label("//flutter/private/tools:flutter_test_runner"),
            cfg = "exec",
        ),
        "_windows_constraint": attr.label(
            default = "@platforms//os:windows",
        ),
    },
    test = True,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ],
    doc = "Runs an already built Flutter test kernel under flutter_tester " +
          "via the package:test_api RemoteListener protocol.",
)
