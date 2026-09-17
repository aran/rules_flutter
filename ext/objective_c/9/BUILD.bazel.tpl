# Bazel-native overlay for `package:objective_c` 9.x.
#
# Mirrors `hook/build.dart`:
#   * macOS+iOS only.
#   * Compiles every `.c`/`.m` under `src/` (plus, up to 9.4, the macOS
#     `test/util.c` memory helper) into a single shared library named
#     `objective_c.dylib`, installed under @rpath at runtime.
#   * Registers the library under the asset id
#     `package:objective_c/objective_c.dylib` so the kernel manifest the
#     frontend_server reads via `--native-assets` resolves
#     `DynamicLibrary.open("objective_c.dylib")` at runtime.
#
# Hand-curated translation of the package's `dart build hooks` output.
# Placeholders (HUB_NAME, PKG, VERSION, LANGUAGE_VERSION, DEPS — written
# in braces below, and deliberately not in this comment, because
# substitution rewrites comment text too) are injected by
# `flutter_pub_package`'s `_resolve_overlay`. We don't read the version
# here: the overlay sits under `9/`, so any 9.x routes to it, and
# everything that varies across 9.x is either substituted or globbed
# rather than written out.

load("@rules_cc//cc:cc_shared_library.bzl", "cc_shared_library")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")
load("@rules_flutter//flutter:native_assets.bzl", "flutter_native_asset")

# `objective_c` is a pure-Dart support library — there's no
# `flutter.plugin` block in pubspec.yaml. We use `flutter_plugin` with
# an empty `platforms` list anyway so the spoke can carry the
# `native_assets` attribute that anchors the manifest entry. Consumers
# transitively pick up the dylib + manifest entry simply by depending
# on `@<hub>//:objective_c` like any other pub package.
flutter_plugin(
    name = "{PKG}",
    srcs = glob(
        ["lib/**/*.dart"],
        allow_empty = True,
    ),
    language_version = "{LANGUAGE_VERSION}",
    native_assets = select({
        "@platforms//os:macos": [":{PKG}_native_asset"],
        "@platforms//os:ios": [":{PKG}_native_asset"],
        "//conditions:default": [],
    }),
    package_name = "{PKG}",
    platforms = [],
    visibility = ["//visibility:public"],
    deps = [
        {DEPS}
    ],
)

# Per-platform Apple wrapper that compiles every C / Objective-C file
# under src/ into a single archive with `-fobjc-arc` for `.m` files.
#
# The Bazel CC toolchain (apple_support's wrapped clang) handles
# headers and ObjC properly via `objc_library`. The hook sets just
# `-fobjc-arc` for `.m` files; rules_cc does the same by default for
# obj_library, so no extra copts are needed.
objc_library(
    name = "_{PKG}_objc",
    srcs = glob(
        [
            "src/**/*.c",
            "src/**/*.m",
        ],
        allow_empty = False,
    ) + select({
        # Up to 9.4 the hook compiled test/util.c on macOS only — iOS skips
        # it because mach_vm_region, which util.c calls, is unavailable
        # there. 9.5.0 deleted the file and moved its replacements behind
        # the `include_test_utils` user define, which only objective_c's own
        # test suite sets; a consumer never gets them. A glob spans both:
        # named literally, the label would not resolve on 9.5+.
        "@platforms//os:macos": glob(
            ["test/util.c"],
            allow_empty = True,
        ),
        "//conditions:default": [],
    }),
    hdrs = glob(
        [
            "src/**/*.h",
            "src/include/**/*.h",
        ],
        allow_empty = True,
    ),
    copts = [
        "-fobjc-arc",
    ],
    includes = ["src"],
    target_compatible_with = select({
        "@platforms//os:macos": [],
        "@platforms//os:ios": [],
        "//conditions:default": ["@platforms//:incompatible"],
    }),
    visibility = ["//visibility:private"],
)

cc_shared_library(
    name = "_{PKG}_dylib",
    # Use a distinct filename — `flutter_native_asset` symlinks this
    # to `objective_c.dylib` in its own package and that's what lands
    # in `Contents/Frameworks/`. Collapsing both names into one collides
    # because the rules live in the same Bazel package.
    shared_lib_name = "_{PKG}_internal.dylib",
    target_compatible_with = select({
        "@platforms//os:macos": [],
        "@platforms//os:ios": [],
        "//conditions:default": ["@platforms//:incompatible"],
    }),
    user_link_flags = [
        # Match the install_name the engine looks up — the kernel's
        # `["absolute", "objective_c.dylib"]` entry resolves the bare
        # basename via `dlopen`, but `@rpath/objective_c.dylib` lets
        # the loader pick it up wherever it's bundled in the .app.
        "-Wl,-install_name,@rpath/objective_c.dylib",
        # Foundation, rather than the `-undefined dynamic_lookup` the
        # package's own hook passes. Every symbol this dylib leaves
        # undefined is a system one — libobjc (`objc_msgSend`,
        # `class_addMethod`), Foundation's classes, libSystem (`malloc`,
        # `dispatch_async`, the Block runtime) — and none come from the
        # host process, so there is nothing for a load-time lookup to find
        # that the SDK cannot resolve at link time. Checked with `nm -u` on
        # both the macOS and iOS-simulator slices: 72 undefined symbols, no
        # `Dart_*` among them.
        #
        # Linking them is also the stronger answer. `dynamic_lookup` defers
        # every unresolved symbol to `dlopen` time, so a misspelled or
        # dropped one becomes a crash in someone's app instead of a link
        # error here — and Apple now deprecates the flag, warning
        # "-undefined dynamic_lookup is deprecated on iOS-simulator" on
        # every consumer's link.
        "-Wl,-framework,Foundation",
    ],
    visibility = ["//visibility:private"],
    deps = [":_{PKG}_objc"],
)

flutter_native_asset(
    name = "{PKG}_native_asset",
    asset_id = "package:{PKG}/objective_c.dylib",
    bundle_filename = "objective_c.dylib",
    library = ":_{PKG}_dylib",
    link_mode = "dynamic_loading_bundle",
    target_compatible_with = select({
        "@platforms//os:macos": [],
        "@platforms//os:ios": [],
        "//conditions:default": ["@platforms//:incompatible"],
    }),
    visibility = ["//visibility:public"],
)
