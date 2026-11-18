"""Shared fixtures and tests for the iOS and macOS bundling rules.

These tests care about how a rule lays its outputs out, not about what a real
Flutter build produces, so their applications are fakes: compiling a real one
per fixture would cost minutes and need a device SDK.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_apple//apple:providers.bzl", "AppleFrameworkImportInfo")
load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartProgramAssetsInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")

def _fake_application_impl(ctx):
    """Placeholder outputs, every one declared under this target's name.

    So fakes in one package never share an output — which is the very defect
    the tests over them are checking the real rules for.

    A path named in both `native_libs` and `code_assets` is one File: the shape
    of one library arriving by both routes. `code_assets` ship, each as the
    asset `package:fake/<path>`; `dropped_code_assets` are code assets of a
    package `pick` whose link hook dropped them, and `data_assets` data assets
    that ship. Each library was linked from one object, `<path>.o`.
    """
    libs = {}
    objects = {}
    for path in ctx.attr.native_libs + ctx.attr.code_assets + ctx.attr.dropped_code_assets + ctx.attr.data_assets:
        if path not in libs:
            lib = ctx.actions.declare_file("%s/%s" % (ctx.label.name, path))
            ctx.actions.write(lib, "%s %s" % (ctx.label, path))
            libs[path] = lib
            objects[path] = ctx.actions.declare_file("%s/%s.o" % (ctx.label.name, path))
            ctx.actions.write(objects[path], "%s %s" % (ctx.label, path))

    def code_asset(package, path):
        return DartCodeAssetInfo(
            asset_id = "package:%s/%s" % (package, path),
            link_mode = "dynamic_loading_bundle",
            file = libs[path],
            uri = "",
            link_inputs = depset([objects[path]]),
        )

    link_outputs = ()
    if ctx.attr.dropped_code_assets:
        selection = ctx.actions.declare_file(ctx.label.name + "/pick.code_selection")
        ctx.actions.write(selection, "")
        emitted = ctx.actions.declare_directory(ctx.label.name + "/pick.data")
        ctx.actions.run(
            executable = ctx.executable._assemble,
            arguments = ["--output", emitted.path],
            outputs = [emitted],
        )
        link_outputs = (struct(
            package = "pick",
            data_assets = emitted,
            code_assets = {
                "package:pick/" + path: code_asset("pick", path)
                for path in ctx.attr.dropped_code_assets
            },
            code_selection = selection,
        ),)
    program_assets = DartProgramAssetsInfo(
        data_assets = {"package:fake/" + path: libs[path] for path in ctx.attr.data_assets},
        code_assets = {"package:fake/" + path: code_asset("fake", path) for path in ctx.attr.code_assets},
        link_outputs = link_outputs,
    )

    # Debug carries a kernel and no AOT dylib; release the reverse. Which one
    # a fixture wants is not cosmetic: a release Apple framework retags its
    # dylib with `vtool`, which rejects a placeholder that is not a Mach-O, so
    # a fixture that will actually be *built* has to be a debug one.
    if ctx.attr.debug:
        aot_output = None
        aot_object = None
        kernel_dill = ctx.actions.declare_file(ctx.label.name + "/app.dill")
        ctx.actions.write(kernel_dill, str(ctx.label))
    else:
        kernel_dill = None
        aot_output = ctx.actions.declare_file(ctx.label.name + "/app.so")
        ctx.actions.write(aot_output, str(ctx.label))
        aot_object = ctx.actions.declare_file(ctx.label.name + "/app.o")
        ctx.actions.write(aot_object, str(ctx.label))

    flutter_assets = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")
    manifest = ctx.actions.declare_file(ctx.label.name + "/AssetManifest.bin.src")
    ctx.actions.write(manifest, "")
    ctx.actions.run(
        executable = ctx.executable._assemble,
        arguments = ["--output", flutter_assets.path, "--add", "AssetManifest.bin", manifest.path],
        inputs = [manifest],
        outputs = [flutter_assets],
    )

    icu_data = ctx.actions.declare_file(ctx.label.name + "/icudtl.dat")
    ctx.actions.write(icu_data, "")

    return [FlutterApplicationInfo(
        icu_data = icu_data,
        aot_output = aot_output,
        aot_object = aot_object,
        strip_aot = ctx.attr.strip_aot,
        kernel_dill = kernel_dill,
        is_debug = ctx.attr.debug,
        flutter_assets = flutter_assets,
        native_libraries = [
            struct(
                library = libs[path],
                package = "app",
                sources = (),
                contract = (),
                link_inputs = depset([objects[path]]),
                dsym = None,
                link_inputs_unset_reason = None,
            )
            for path in ctx.attr.native_libs
        ],
        program_assets = program_assets,
    )]

fake_application = rule(
    implementation = _fake_application_impl,
    attrs = {
        "code_assets": attr.string_list(),
        "data_assets": attr.string_list(),
        "debug": attr.bool(default = False),
        "dropped_code_assets": attr.string_list(),
        "native_libs": attr.string_list(),
        "strip_aot": attr.bool(default = True),
        "_assemble": attr.label(
            default = "//flutter/private/tools:assemble_directory",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "A fake FlutterApplicationInfo for tests over Apple bundling rules.",
)

def _outputs_under_target_dir_test_impl(ctx):
    """Every output this rule declares sits under a directory named after it.

    The invariant both Apple framework rules exist under: two apps in one
    package are two targets, and Bazel gives a declared file the package's path
    plus whatever name the rule asks for, with nothing of the target's own in
    between. A rule that hardcodes its layout therefore has both targets
    writing one path, which fails the build with conflicting actions as soon as
    the two apps differ enough for their actions to differ. A pair built from
    the *same* application hides it, because Bazel shares identical actions.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    own = "/".join([p for p in [target.label.package, target.label.name] if p])

    outputs = target[DefaultInfo].files.to_list()
    asserts.true(env, len(outputs) > 0, "the rule declared no outputs to check")
    for f in outputs:
        asserts.true(
            env,
            f.short_path == own or f.short_path.startswith(own + "/"),
            "%s is not the directory %s nor under it, so a second app in the " % (f.short_path, own) +
            "package would declare it too",
        )
    return analysistest.end(env)

outputs_under_target_dir_test = analysistest.make(
    _outputs_under_target_dir_test_impl,
)

def _strip_step_test_impl(ctx):
    """The shipped binary is stripped exactly when the application says it is.

    `flutter build` strips an Apple AOT binary after its dSYM is extracted,
    unless `--no-strip` is among the extra gen_snapshot options. The dSYM is
    extracted either way.
    """
    env = analysistest.begin(ctx)
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterAppleSplitDebugInfo"
    ]
    asserts.equals(env, 1, len(actions), "expected one dSYM-and-strip action")
    if len(actions) != 1:
        return analysistest.end(env)
    script = "\n".join(actions[0].argv)
    asserts.true(env, "dsymutil" in script, "the dSYM is extracted either way: %s" % script)
    asserts.equals(
        env,
        ctx.attr.expect_strip,
        "strip -x" in script,
        "strip -x %s run: %s" % ("should be" if ctx.attr.expect_strip else "should not be", script),
    )
    return analysistest.end(env)

strip_step_test = analysistest.make(
    _strip_step_test_impl,
    attrs = {"expect_strip": attr.bool(mandatory = True)},
)

def _native_library_symbols_impl(ctx):
    """Each bundled native library is prepared as rules_apple treats the app's binary.

    With `--objc_enable_binary_stripping` in `-c opt` and
    `--apple_generate_dsym`, one action a library strips it and makes its
    dSYM, which the rule hands rules_apple's `dsyms` output group. The dSYM is
    read through the library's debugging map from the files it was linked
    from, so they are inputs, and the map is kept until it is.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == ctx.attr.mnemonic]
    asserts.equals(env, len(ctx.attr.expected_dsyms), len(actions), "one action a library: %s" % [a.argv for a in actions])
    for action in actions:
        script = "\n".join(action.argv)
        asserts.true(env, "dsymutil" in script, "the dSYM is made: %s" % script)
        asserts.true(env, "strip -x -S" in script, "the library is stripped: %s" % script)
        asserts.false(env, "strip -S" in script.split("dsymutil")[0], "the debugging map is kept for dsymutil: %s" % script)
        inputs = action.inputs.to_list()
        asserts.equals(
            env,
            sorted([f.basename + ".o" for f in inputs if f.extension in ("dylib", "so")]),
            sorted([f.basename for f in inputs if f.extension == "o"]),
            "what each library was linked from is an input: %s" % [f.short_path for f in inputs],
        )
    asserts.equals(
        env,
        sorted(ctx.attr.expected_dsyms),
        sorted([f.path.split("/")[-5] + "/" + f.basename for a in actions for f in a.outputs.to_list() if "/Resources/DWARF/" in f.path]),
        "the dSYM each library's action makes",
    )

    # rules_apple's `dsyms` group gets one directory, of the dSYMs of the
    # libraries that ship, which an action picks from every candidate's once
    # the link hooks have chosen (`code_assets.dart dsyms`).
    collect = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterShippedDsyms"]
    asserts.equals(env, 1, len(collect), "one action collects the dSYMs that ship")
    dsyms = target[AppleFrameworkImportInfo].dsym_imports.to_list() if AppleFrameworkImportInfo in target else []
    asserts.equals(
        env,
        [f.path for f in collect[0].outputs.to_list()] if collect else [],
        [f.path for f in dsyms],
        "the dSYMs rules_apple puts in the app's `dsyms` group are those that ship",
    )
    if collect:
        argv = collect[0].argv
        always = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--always"]
        candidates = [argv[i + 2] for i in range(len(argv) - 2) if argv[i] == "--candidate-dsym"]
        bundle = lambda plist: plist.split("/")[-3]
        asserts.equals(env, sorted(ctx.attr.expected_always), sorted([bundle(p) for p in always]), "the dSYMs that always ship")
        asserts.equals(env, sorted(ctx.attr.expected_candidates), sorted([bundle(p) for p in candidates]), "the dSYMs of the code assets a link hook chooses among")
        asserts.equals(
            env,
            sorted(ctx.attr.expected_always + ctx.attr.expected_candidates),
            sorted([f.path.split("/")[-5] for f in collect[0].inputs.to_list() if "/Resources/DWARF/" in f.path]),
            "every candidate's dSYM is an input",
        )
    return analysistest.end(env)

native_library_symbols_test = analysistest.make(
    _native_library_symbols_impl,
    attrs = {
        "expected_always": attr.string_list(doc = "`<bundle>.dSYM` of each library that always ships."),
        "expected_candidates": attr.string_list(doc = "`<bundle>.dSYM` of each code asset a link hook chooses among."),
        "expected_dsyms": attr.string_list(doc = "`<bundle>.dSYM/<binary>` of each library."),
        "mnemonic": attr.string(mandatory = True, doc = "The mnemonic of the action that prepares each library."),
    },
    config_settings = {
        "//command_line_option:apple_generate_dsym": True,
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:objc_enable_binary_stripping": True,
    },
)

def _native_library_untouched_impl(ctx):
    """Without the flags, no library is stripped and none has a dSYM."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    for action in analysistest.target_actions(env):
        # A file write has no command line.
        script = "\n".join(action.argv or [])
        asserts.false(env, "dsymutil" in script or "strip -x" in script, "%s: %s" % (action.mnemonic, script))
    dsyms = target[AppleFrameworkImportInfo].dsym_imports.to_list() if AppleFrameworkImportInfo in target else []
    asserts.equals(env, [], [f.path for f in dsyms])
    return analysistest.end(env)

native_library_untouched_test = analysistest.make(_native_library_untouched_impl)
