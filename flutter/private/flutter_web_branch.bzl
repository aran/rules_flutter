"""The compilers a web bundle's Dart goes through, and what each one reads.

A web bundle compiles one program, its `flutter_application`'s, with up to
three compilers, and the program may differ between them: a library's `deps`
can `select()` on
`@rules_dart//dart/constraints:wasm` or `:js`, so a dependency that holds an
`Int64List` for dart2wasm can be a `List<int>` for dart2js. The bundle
therefore reads each compiler's inputs from a *branch* of its application,
built for that compiler's web platform (where the application builds nothing
of its own and gives its program, `FlutterApplicationInputsInfo`):

    branch     compiles                              platform
    dart2wasm  the WebAssembly build                 wasm_platform
    dart2js    the JavaScript fallback               js_platform
    ddc        the dev loop (`flutter_bazel run`)    js_platform

Two branches share a platform, so a debug bundle has at most two
configurations of its program: DDC compiles what dart2js does.

Each branch is its own configured target of `flutter_web_branch`, because the
staging a compile needs (the package config and the co-located sources of a
package whose files are split between the source tree and `bazel-out`) declares
files named after its target, and two of them in one target collide. The
bundle macro (`flutter_web_bundle`) declares that target beside the bundle.
"""

load(
    "@rules_dart//dart:utils.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "WEB_PLATFORM_SETTINGS",
    "collect_packages",
    "collect_transitive_srcs",
    "web_platform_settings",
)
load("//flutter:providers.bzl", "FlutterApplicationInputsInfo")
load("//flutter/private:app_entrypoint.bzl", "compile_package_config", "synthesize_app_package")

visibility("//flutter/...")

# The web runtime each branch builds for, which keys the split: `wasm` is built
# for the bundle's `wasm_platform`, `js` for its `js_platform`.
BRANCH_COMPILER = {
    "dart2wasm": "wasm",
    "dart2js": "js",
    "ddc": "js",
}

def web_branches_target(bundle):
    """The name of the staging target declared beside a bundle.

    Args:
        bundle: The bundle's target name.

    Returns:
        The name of its `flutter_web_branch`.
    """
    return "__%s_branches" % bundle

def web_compile_branches(compiler, js_fallback, debug):
    """The compilers a bundle's Dart goes through, the primary first.

    Each is a branch of the program: what it compiles is read from its own
    branch of `deps`, so a dependency may differ by compiler. The primary is
    `compiler`, the build the bundle describes; dart2js joins a dart2wasm
    bundle as its fallback; and a debug build adds DDC, which compiles the
    app for `flutter_bazel run -d chrome` from the files `_dev_config.json`
    names rather than in this rule.

    Args:
        compiler: The `compiler` attr: "dart2wasm" or "dart2js".
        js_fallback: The `js_fallback` attr.
        debug: Whether this is a debug build.

    Returns:
        A list of "dart2wasm", "dart2js" and "ddc", the primary first.
    """
    branches = [compiler]
    if compiler == "dart2wasm" and js_fallback:
        branches.append("dart2js")
    if debug:
        branches.append("ddc")
    return branches

def branch_settings(branches):
    """The distinct web runtimes of some branches, in order.

    Args:
        branches: Branch names, from `web_compile_branches`.

    Returns:
        A list of "wasm" and "js", each at most once.
    """
    settings = []
    for branch in branches:
        setting = BRANCH_COMPILER[branch]
        if setting not in settings:
            settings.append(setting)
    return settings

def _branches_impl(settings, attr):
    # A profile build is not a debug build under any compilation mode, so
    # `profile` rules the dev loop out as `web_build_mode` does.
    # The mode arrives as a `CompilationMode`, which compares equal to no string.
    debug = str(settings["//command_line_option:compilation_mode"]) == "dbg" and not attr.profile
    platforms = {"js": attr.js_platform, "wasm": attr.wasm_platform}
    return {
        setting: web_platform_settings(settings, platforms[setting])
        for setting in branch_settings(web_compile_branches(attr.compiler, attr.js_fallback, debug))
    }

# One configuration of a bundle's program per web platform its compilers need,
# keyed by runtime (`ctx.split_attr.<attr>["wasm"]`). A dart2js bundle in
# release builds its program once. Through rules_dart's `web_platform_settings`,
# so its resets can rejoin the configuration the build had before.
web_branches = transition(
    implementation = _branches_impl,
    inputs = ["//command_line_option:compilation_mode"] + WEB_PLATFORM_SETTINGS,
    outputs = WEB_PLATFORM_SETTINGS,
)

# The platforms a bundle builds its program for, by runtime.
WEB_PLATFORM_ATTRS = {
    "js_platform": attr.label(
        doc = "The platform the dart2js and DDC builds of the program are built for. " +
              "It must carry `@rules_dart//dart/constraints:js`. Defaults to rules_dart's, " +
              "which carries only that.",
        default = "@rules_dart//dart/platforms:js",
    ),
    "wasm_platform": attr.label(
        doc = "The platform the dart2wasm build of the program is built for. It must " +
              "carry `@rules_dart//dart/constraints:wasm`. Defaults to rules_dart's, " +
              "which carries only that.",
        default = "@rules_dart//dart/platforms:wasm",
    ),
}

FlutterWebBranchInfo = provider(
    doc = "What one compiler of a web bundle reads, staged for it.",
    fields = {
        "program": "struct: the application's program as this compiler's branch configured it: its `FlutterApplicationInputsInfo.inputs`, whose `deps` are built for the branch's web platform.",
        "srcs": "list[File]: the program's `srcs` and its dependencies' sources, as declared.",
        "packages": "list[DartPackageInfo]: as declared, the app's own package last.",
        "config_file": "File: the package config, after co-location.",
        "compile_srcs": "list[File]: the sources the package config reaches, after co-location.",
        "runtime": "string: the web runtime its target platform carries: `js`, `wasm` or `none`.",
    },
)

def _runtime(ctx):
    for runtime in ["js", "wasm"]:
        if ctx.target_platform_has_constraint(getattr(ctx.attr, "_" + runtime)[platform_common.ConstraintValueInfo]):
            return runtime
    return "none"

def _flutter_web_branch_impl(ctx):
    program = ctx.attr.application[FlutterApplicationInputsInfo].inputs
    metadata = program.package
    deps = program.deps
    srcs = list(program.srcs) + collect_transitive_srcs(deps).to_list()

    # Register the app's own package so `package:<name>/main.dart` is a valid
    # URI for the wrapper to import. Include `main` in the colocate inputs so
    # it ends up inside the same assembled directory as its lib/ siblings —
    # that's what lets `main.dart`'s relative imports resolve to the
    # assembled (codegen-co-located) copies of its package siblings.
    packages = synthesize_app_package(ctx.attr.bundle, collect_packages(deps), metadata.package_name, metadata.package_root, metadata)
    staged = compile_package_config(ctx, packages, srcs + [program.main])
    return [
        FlutterWebBranchInfo(
            program = program,
            srcs = srcs,
            packages = packages,
            config_file = staged.config_file,
            compile_srcs = staged.srcs,
            runtime = _runtime(ctx),
        ),
        DefaultInfo(files = depset([staged.config_file] + [f for f in staged.srcs if not f.is_source])),
    ]

flutter_web_branch = rule(
    implementation = _flutter_web_branch_impl,
    attrs = {
        "application": attr.label(
            doc = "The bundle's `flutter_application`, built in this branch's configuration.",
            providers = [FlutterApplicationInputsInfo],
            mandatory = True,
        ),
        "bundle": attr.string(
            doc = "The bundle this stages, for the messages that name it.",
            mandatory = True,
        ),
        "_js": attr.label(default = "@rules_dart//dart/constraints:js"),
        "_wasm": attr.label(default = "@rules_dart//dart/constraints:wasm"),
    },
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = """One compiler's view of a `flutter_web_bundle`'s program.

Declared by the bundle macro with the bundle's `application`, and reached from
the bundle through its split, so each configured target stages the program
as one compiler sees it. Not for use outside that macro.""",
)
