# Bazel-native overlay for `package:objective_c` 9.x.
#
# Mirrors `hook/build.dart`:
#   * macOS+iOS only.
#   * Compiles every `.c`/`.m` under `src/` plus (macOS only)
#     `test/util.c` into a single shared library named `objective_c.dylib`,
#     installed under @rpath at runtime.
#   * Registers the library under the asset id
#     `package:objective_c/objective_c.dylib` so the kernel manifest the
#     frontend_server reads via `--native-assets` resolves
#     `DynamicLibrary.open("objective_c.dylib")` at runtime.
#
# Hand-curated translation of the package's `dart build hooks` output.
# Substitutions ({HUB_NAME}, {PKG}, {VERSION}) are injected by
# `flutter_pub_package`'s `_resolve_overlay`. We don't read {VERSION}
# here — the overlay sits under `9/`, so any 9.x version routes here.

load("@rules_cc//cc:cc_shared_library.bzl", "cc_shared_library")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")
load("@rules_flutter//flutter:native_assets.bzl", "flutter_native_asset")

# `objective_c` is a pure-Dart support library — there's no
# `flutter.plugin` block in pubspec.yaml. We use `flutter_plugin` with
# an empty `platforms` list anyway so the spoke can carry the
# `native_assets` attribute that anchors the manifest entry. Consumers
# transitively pick up the dylib + manifest entry simply by depending
# on `@deps//:{PKG}` like any other pub package.
flutter_plugin(
    name = "{PKG}",
    srcs = glob(
        ["lib/**/*.dart"],
        allow_empty = True,
    ),
    language_version = "3.10",
    native_assets = select({
        "@platforms//os:macos": [":{PKG}_native_asset_macos"],
        "@platforms//os:ios": [":{PKG}_native_asset_ios"],
        "//conditions:default": [],
    }),
    package_name = "{PKG}",
    platforms = [],
    visibility = ["//visibility:public"],
    deps = [
        "@{HUB_NAME}__code_assets//:code_assets",
        "@{HUB_NAME}__collection//:collection",
        "@{HUB_NAME}__ffi//:ffi",
        "@{HUB_NAME}__hooks//:hooks",
        "@{HUB_NAME}__logging//:logging",
        "@{HUB_NAME}__native_toolchain_c//:native_toolchain_c",
        "@{HUB_NAME}__pub_semver//:pub_semver",
    ],
)

# Per-platform Apple wrapper that compiles every C / Objective-C file
# under src/ (and, on macOS, the test/util.c memory helper) into a
# single archive with `-fobjc-arc` for `.m` files.
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
        "@platforms//os:macos": [
            # Hook adds test/util.c on macOS only. iOS skips it because
            # mach_vm_region (used inside util.c) isn't available there.
            "test/util.c",
        ],
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
        # The hook also passes `-undefined dynamic_lookup` so the
        # Objective-C runtime symbols resolve at load time against the
        # process. Replicate that here.
        "-Wl,-undefined,dynamic_lookup",
    ],
    visibility = ["//visibility:private"],
    deps = [":_{PKG}_objc"],
)

flutter_native_asset(
    name = "{PKG}_native_asset_macos",
    asset_id = "package:{PKG}/objective_c.dylib",
    bundle_filename = "objective_c.dylib",
    library = ":_{PKG}_dylib",
    link_mode = "dynamic_loading_bundle",
    target_compatible_with = ["@platforms//os:macos"],
    target_os = "macos",
    visibility = ["//visibility:public"],
)

flutter_native_asset(
    name = "{PKG}_native_asset_ios",
    asset_id = "package:{PKG}/objective_c.dylib",
    bundle_filename = "objective_c.dylib",
    library = ":_{PKG}_dylib",
    link_mode = "dynamic_loading_bundle",
    target_compatible_with = ["@platforms//os:ios"],
    target_os = "ios",
    visibility = ["//visibility:public"],
)
