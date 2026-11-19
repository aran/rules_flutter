"""The `flutter_assets/` tree an application builds for a chosen platform."""

load("@rules_dart//dart:defs.bzl", "dart_test")
load("@rules_flutter//flutter:defs.bzl", "flutter_application")
load("@rules_flutter//flutter:providers.bzl", "FlutterApplicationInfo")

def _platform_transition_impl(settings, attr):
    # The kernel is compiled in debug mode: nothing here depends on the
    # compiled program, only on what the asset step bundles, and a debug
    # build skips the AOT compile.
    return {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:platforms": [str(attr.platform)] if attr.platform else settings["//command_line_option:platforms"],
    }

_platform_transition = transition(
    implementation = _platform_transition_impl,
    inputs = ["//command_line_option:platforms"],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
    ],
)

def _app_bundle_impl(ctx):
    app = ctx.attr.application[0]
    return [DefaultInfo(files = depset([app[FlutterApplicationInfo].flutter_assets]))]

app_bundle = rule(
    implementation = _app_bundle_impl,
    doc = "Exposes the `flutter_assets/` tree of `application` as built for `platform`.",
    attrs = {
        "application": attr.label(
            cfg = _platform_transition,
            providers = [FlutterApplicationInfo],
            mandatory = True,
        ),
        "platform": attr.label(
            doc = "The platform to build `application` for; the build's own when unset.",
        ),
    },
)

def bundled_app(name, assets = [], deps = [], package = "//:pubspec-metadata", main = "lib/main.dart", platform = None, bundle_compatible_with = None, **kwargs):
    """A trivial application and, as `<name>_bundle`, the asset tree it builds.

    What the applications of this workspace differ in is where they sit, which
    assets they declare and which libraries they depend on, never the program.

    Args:
        name: The application's name.
        assets: Its own asset files.
        deps: Libraries beside `@deps//:flutter`.
        package: The `dart_package_metadata` of the application's Dart package.
        main: Its entry point.
        platform: The platform to build the bundle for.
        bundle_compatible_with: The bundle's `target_compatible_with`, which
            holds in the host's own configuration, the one the bundle's
            dependents have: the hosts that can build it for `platform`.
        **kwargs: More attributes of the application.
    """
    flutter_application(
        name = name,
        assets = assets,
        main = main,
        package = package,
        deps = ["@deps//:flutter"] + deps,
        # The program imports none of `deps`: what is under test is what they
        # put in the bundle, licences included, which no import shows. The
        # unused-dependency check would refuse the very edges being tested.
        features = kwargs.pop("features", []) + ["-dart_unused_deps"],
        **kwargs
    )
    app_bundle(
        name = name + "_bundle",
        application = ":" + name,
        platform = platform,
        target_compatible_with = bundle_compatible_with,
        visibility = ["//visibility:public"],
    )

def bundle_test(name, bundle, expected, prefix = "", platform = "", flavor = "", subdir = "", allow_extra = False, unlisted = [], **kwargs):
    """Checks the tree `bundle` builds against the assets `flutter build` would bundle.

    Args:
        name: The test's name, which states the property it checks.
        bundle: An `app_bundle` target.
        expected: A file under `//tests:expected`, in the shape
            `tests/bundle_check.dart` documents.
        prefix: Put in front of every key and path in `expected`; the
            `packages/<name>/` of a library's assets.
        platform: The `platforms:` value the bundle is built for, for the
            entries of `expected` that restrict it.
        flavor: The flavor the bundle is built for, for the entries of
            `expected` that name flavors; none when empty.
        subdir: Where the `flutter_assets/` tree sits in `bundle`, for a bundle
            that holds more than that.
        allow_extra: Whether the bundle may hold more than `expected` lists.
        unlisted: Files the bundle must hold that have no key in its manifest.
        **kwargs: More attributes of the test.
    """
    args = ["$(rlocationpath %s)" % bundle, "$(rlocationpath %s)" % expected]
    if prefix:
        args.append("--prefix=" + prefix)
    if platform:
        args.append("--platform=" + platform)
    if flavor:
        args.append("--flavor=" + flavor)
    if subdir:
        args.append("--subdir=" + subdir)
    if allow_extra:
        args.append("--allow-extra")
    args += ["--unlisted=" + f for f in unlisted]
    dart_test(
        name = name,
        args = args,
        data = [bundle, expected],
        main = "//tests:bundle_test.dart",
        size = "small",
        deps = [
            "//tests:bundle_check",
            "@rules_dart//dart/runfiles",
        ],
        **kwargs
    )

def _tree_impl(ctx):
    return [DefaultInfo(files = depset([f for f in ctx.files.src if f.is_directory]))]

tree_of = rule(
    implementation = _tree_impl,
    doc = "The directory `src` builds, without the files beside it.",
    attrs = {"src": attr.label(mandatory = True)},
)

def notices_test(name, bundle, web = False, subdir = "", own_license = None, package = None, additional = [], fixtures = None, absent = [], **kwargs):
    """Checks the `NOTICES` asset of the tree `bundle` builds.

    Args:
        name: The test's name, which states the property it checks.
        bundle: An `app_bundle` target (or a tree of the web build).
        web: Whether the bundle is the web's, which holds `NOTICES`, not `NOTICES.Z`.
        subdir: Where the `flutter_assets/` tree sits in `bundle`.
        own_license: The licence file of the application, listed under `package`.
        package: The application's package name, when `own_license` is set.
        additional: The files the application lists in `additional_licenses`,
            which the asset ends with in this order.
        fixtures: The expected text of the entries that only `fx_` packages name.
        absent: Package names that must not be listed.
        **kwargs: More attributes of the test.
    """
    args = ["$(rlocationpath %s)" % bundle]
    data = [bundle]
    if web:
        args.append("--web")
    if subdir:
        args.append("--subdir=" + subdir)
    if own_license:
        args += ["--own-license=$(rlocationpath %s)" % own_license, "--package=" + package]
        data.append(own_license)
    for f in additional:
        args.append("--additional=$(rlocationpath %s)" % f)
        data.append(f)
    if fixtures:
        args.append("--fixtures=$(rlocationpath %s)" % fixtures)
        data.append(fixtures)
    args += ["--absent=" + n for n in absent]
    dart_test(
        name = name,
        args = args,
        data = data,
        main = "//tests:notices_test.dart",
        size = "small",
        deps = ["@rules_dart//dart/runfiles"],
        **kwargs
    )
