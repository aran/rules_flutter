"""`flutter_application_variant`: an application built from another's program with a different `main`."""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:structs.bzl", "structs")
load("@rules_dart//dart:utils.bzl", "program_assets_attrs", "runtime_reset")
load("//flutter:providers.bzl", "FlutterApplicationInputsInfo")
load("//flutter/private:code_asset_libraries.bzl", "code_asset_libraries_aspect")
load("//flutter/private:common.bzl", "FLUTTER_APPLICATION_TOOL_ATTRS", "PLATFORM_CONSTRAINT_ATTRS", "flutter_deps_attr")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//flutter/private:flutter_application.bzl", "APPLICATION_TOOLCHAINS", "WEB_PLATFORM_CONSTRAINT_ATTRS", "flutter_application_build")
load("//flutter/private:flutter_native_assets.bzl", "CODE_ASSETS_TOOL_ATTRS")
load("//flutter/private:program_analysis.bzl", "staged_sources")
load("//flutter/private:required_packages.bzl", "check_required_packages")

visibility("//flutter/...")

def _flutter_application_variant_impl(ctx):
    program = ctx.attr.application[FlutterApplicationInputsInfo].inputs
    deps = program.deps + ctx.attr.deps
    check_required_packages(ctx.label, deps, ctx.attr.requires_packages)

    # Everything not named here is the application's own: its package and so
    # its `package:` URIs and asset keys (`package`, `package_root`), its assets, native dependencies and
    # build options. `label` in particular stays the application's, which is
    # what makes `package:<app>/…` imports in the new `main` resolve.
    #
    # The application's own `main` stays a source: the new one is likely to
    # import it (`package:<app>/main.dart`) to start the app it tests.
    kept_main = [program.main] if program.main not in program.srcs else []
    application_srcs = program.srcs + kept_main
    inputs = structs.to_dict(program) | {
        "main": ctx.file.main,
        "srcs": application_srcs + ctx.files.srcs + ctx.files.unchecked_srcs,
        "unchecked_srcs": program.unchecked_srcs + ctx.files.unchecked_srcs,
        # The new `main` need not load them all: the application's own target
        # checks that its `main` does.
        "entry_srcs": application_srcs,
        "staged_sources": program.staged_sources + staged_sources(ctx.attr.unchecked_srcs),
        "deps": deps,
        "defines": program.defines + ctx.attr.defines,
        "code_assets": program.code_assets,
    }
    return flutter_application_build(ctx, struct(**inputs))

flutter_application_variant = rule(
    implementation = _flutter_application_variant_impl,
    attrs = FLUTTER_APPLICATION_TOOL_ATTRS | PLATFORM_CONSTRAINT_ATTRS | WEB_PLATFORM_CONSTRAINT_ATTRS | CODE_ASSETS_TOOL_ATTRS | program_assets_attrs() | apple_support.platform_constraint_attrs() | {
        "application": attr.label(
            doc = "The `flutter_application` whose program this is a variant of.",
            mandatory = True,
            providers = [FlutterApplicationInputsInfo],
        ),
        "main": attr.label(
            doc = "The entry point, in place of the application's `main`. It may be anywhere: a file outside the application's `lib/` is compiled under the app scheme (`org-dartlang-app:///<workspace path>`), as an application's own `main` outside `lib/` is.",
            mandatory = True,
            allow_single_file = [".dart"],
            # As the application's `main`: a written one is in the output
            # directory of the web app's wrapper that imports it.
            cfg = runtime_reset,
        ),
        "srcs": attr.label_list(
            doc = "Dart sources added to the application's.",
            allow_files = [".dart"],
        ),
        "unchecked_srcs": attr.label_list(
            doc = "Dart sources added to the application's like `srcs`, whose imports are not checked against the program's `deps`: files a rule wrote for the program (an integration test's bootstrap and support library), whose imports are that rule's to get right and need not be `deps` of the user's target. `main` is exempt when listed here too.",
            allow_files = [".dart"],
        ),
        # Dependencies added to the application's: a plugin only these bring is
        # registered in the variant and not in the application.
        "deps": flutter_deps_attr(aspects = [code_asset_libraries_aspect]),
        "defines": attr.string_list(
            doc = "Dart environment defines (`-D`) added after the application's.",
        ),
        "requires_packages": attr.string_list(
            doc = "Dart packages the program must have, by name: analysis fails, naming the package and the hub target to add, if no dependency of the application or of `deps` brings one. For a program whose added sources import packages the application does not need, as an integration test's.",
        ),
    },
    toolchains = APPLICATION_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = ["cpp"],
    doc = """The `flutter_application` `application`, rebuilt with another `main`.

Compiles the application's program again with `main` as its entry point, `srcs`,
`deps` and `defines` added to the application's (its own `main` stays among its
sources, for the new one to import), and everything else the
application's own: its Dart package (so `package:<name>/…` imports in the new
`main` resolve against the application's `lib/`), assets, native dependencies,
code assets, shaders and build options. It returns what `flutter_application`
returns (`FlutterApplicationInfo`, `DefaultInfo`, the output groups and, in a
debug build, the dev config), so each platform's app rule takes it as its
`application` unchanged.

Two uses are the same shape: an entry point that is not the application's
(`flutter run -t test_driver/app.dart`), and a test program that runs the
application under a harness. Neither needs the application's own `main` to
change, and neither rebuilds what the program does not touch: the Flutter
framework's and each package's kernels are shared with the application.

```starlark
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "app_flutter",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    deps = ["@deps//:flutter"],
)

flutter_application_variant(
    name = "driver_flutter",
    application = ":app_flutter",
    main = "test_driver/app.dart",
    srcs = ["test_driver/banner.dart"],
)

flutter_macos_app(
    name = "driver_app",
    application = ":driver_flutter",
    bundle_id = "com.example.myapp.driver",
)
```
""",
)
