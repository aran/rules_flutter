"""Extensions for bzlmod.

Installs a Flutter toolchain and optionally resolves pub dependencies
(including Flutter SDK packages like package:flutter).

Every module can define a toolchain version under the default name, "flutter".
The latest of those versions will be selected (the rest discarded),
and will always be registered by rules_flutter.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.
"""

load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_lock")
load("//flutter/private:flutter_pub_lock_hub.bzl", "flutter_pub_lock_hub")
load("//flutter/private:flutter_pub_package.bzl", "flutter_pub_package")
load("//flutter/private:flutter_sdk_package.bzl", "flutter_sdk_package")
load(":repositories.bzl", "flutter_register_toolchains")

_DEFAULT_NAME = "flutter"

# Flutter SDK packages that exist as source under packages/ in the Flutter repo.
# sky_engine is excluded — it provides dart:ui which is already in platform_strong.dill.
_FLUTTER_SDK_PACKAGES = {"flutter": True, "flutter_test": True, "flutter_driver": True, "flutter_localizations": True, "flutter_web_plugins": True}

def _parse_version(v):
    """Splits a version string into a list of ints for comparison."""
    parts = v.split(".")
    result = []
    for x in parts:
        if not x.isdigit():
            fail(
                "Invalid Flutter version '{}': expected numeric components " +
                "separated by dots (e.g. '3.41.2'), but got non-numeric " +
                "component '{}'.".format(v, x),
            )
        result.append(int(x))
    return result

flutter_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one Flutter toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
    "flutter_version": attr.string(doc = "Version of the Flutter SDK.", mandatory = True),
})

_flutter_pub = tag_class(attrs = {
    "name": attr.string(
        doc = "Repository name for the resolved packages hub.",
        mandatory = True,
    ),
    "lock": attr.label(
        doc = "The pubspec.lock file to parse.",
        mandatory = True,
        allow_single_file = True,
    ),
})

_flutter_plugin_overlays = tag_class(attrs = {
    "roots": attr.label_list(
        doc = "BUILD.bazel anchors for user-supplied overlay trees. Each " +
              "label points at an `ext/BUILD.bazel` (or equivalent) that " +
              "anchors a directory tree of `<package>/<version>/BUILD.bazel.tpl` " +
              "overrides. flutter_pub_package walks user roots first, then the " +
              "bundled `@rules_flutter//ext:BUILD.bazel`.",
        allow_files = True,
        default = [],
    ),
})

def _toolchain_extension(module_ctx):
    registrations = {}
    selected_versions = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the Flutter toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
            registrations[toolchain.name].append(toolchain.flutter_version)
    for name, versions in registrations.items():
        unique_versions = {v: True for v in versions}.keys()
        if len(unique_versions) > 1:
            selected = versions[0]
            for v in versions[1:]:
                if _parse_version(v) > _parse_version(selected):
                    selected = v

            # buildifier: disable=print
            print("NOTE: Flutter toolchain {} has multiple versions {}, selected {}".format(name, list(unique_versions), selected))
        else:
            selected = versions[0]

        flutter_register_toolchains(
            name = name,
            flutter_version = selected,
        )
        selected_versions[name] = selected

    # Collect user-supplied overlay roots from `flutter.plugin_overlays(...)`
    # tags. They're applied to every flutter_pub_package invocation in
    # the order seen, then the bundled `@rules_flutter//ext` root. This
    # makes any pub plugin user-fixable locally — drop a
    # `<workspace>/plugin_overlays/<pkg>/<major>/BUILD.bazel.tpl` and
    # register the root in MODULE.bazel; the next build picks it up.
    user_overlay_roots = []
    for mod in module_ctx.modules:
        for tag in mod.tags.plugin_overlays:
            user_overlay_roots.extend(tag.roots)

    # Handle flutter.pub() tags — resolve pubspec.lock with Flutter SDK support.
    for mod in module_ctx.modules:
        for pub_tag in mod.tags.pub:
            hub_name = pub_tag.name
            lock_content = module_ctx.read(pub_tag.lock)
            lock_pkgs = parse_pubspec_lock(lock_content)

            # Determine the Flutter version to use for SDK packages.
            # Use the default toolchain version; fail if no toolchain is registered.
            flutter_version = selected_versions.get(_DEFAULT_NAME)
            if not flutter_version:
                fail("flutter.pub() requires a flutter.toolchain() to be registered.")

            # Classify packages by source.
            hosted = {}
            sdk_flutter = {}
            all_package_names = []
            for name, info in lock_pkgs.items():
                source = info.get("source", "unknown")
                if source == "hosted":
                    hosted[name] = info
                    all_package_names.append(name)
                elif source == "sdk":
                    if name in _FLUTTER_SDK_PACKAGES:
                        sdk_flutter[name] = info
                        all_package_names.append(name)
                else:
                    # buildifier: disable=print
                    print("flutter.pub: skipping package \"{}\" (source: {}). Only hosted and Flutter SDK packages are supported.".format(name, source))

            # Create spoke repos for hosted packages. flutter.pub() routes
            # every hosted package through flutter_pub_package — the
            # `flutter pub get` analog — so plugins surface their
            # `flutter.plugin.platforms` metadata via FlutterInfo. Pure-Dart
            # packages still emit a plain `dart_library`; the rule branches
            # internally on whether a `flutter.plugin` block is present.
            # Non-Flutter modules using `pub.pub()` keep using rules_dart's
            # `pub_lock_package` directly.
            for name, info in hosted.items():
                desc = info.get("description", {})
                flutter_pub_package(
                    name = hub_name + "__" + name,
                    package_name = name,
                    version = info.get("version", ""),
                    sha256 = desc.get("sha256", "") if type(desc) == "dict" else "",
                    base_url = desc.get("url", "https://pub.dev") if type(desc) == "dict" else "https://pub.dev",
                    hub_name = hub_name,
                    lock_packages = all_package_names,
                    overlay_roots = user_overlay_roots + ["@rules_flutter//ext:BUILD.bazel"],
                )

            # Create spoke repos for Flutter SDK packages.
            for name in sdk_flutter.keys():
                flutter_sdk_package(
                    name = hub_name + "__" + name,
                    package_name = name,
                    flutter_version = flutter_version,
                    hub_name = hub_name,
                    lock_packages = all_package_names,
                )

            # Create hub repo with aliases for all packages plus the
            # Android plugin-libs aggregator. flutter.pub() always uses
            # `flutter_pub_lock_hub` (not rules_dart's plain
            # `pub_lock_hub`) because the Tier-1 `flutter_android_app`
            # macro needs `@<hub>//android:all_android_plugin_libs` to
            # auto-wire transitively-collected plugin Kotlin/Java into
            # the final APK. Non-Flutter pub.pub() consumers keep using
            # rules_dart's plain hub.
            flutter_pub_lock_hub(
                name = hub_name,
                hub_name = hub_name,
                packages = sorted(all_package_names),
            )

    # Don't declare root_module_direct_deps: flutter_register_toolchains creates
    # many repos (iOS, Android, web, desktop, cross-compile per platform) and
    # each user workspace only needs a subset — a macOS-only app doesn't want
    # Android engine repos forced into its use_repo. Declaring a strict subset
    # makes `bazel mod tidy` strip out repos the user actually needs; declaring
    # the full set makes tidy force repos they don't. Letting users maintain
    # their own use_repo lists (rules_python does the same) is the right
    # tradeoff for an extension with this many optional outputs.
    return module_ctx.extension_metadata(reproducible = True)

flutter = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {
        "toolchain": flutter_toolchain,
        "pub": _flutter_pub,
        "plugin_overlays": _flutter_plugin_overlays,
    },
    os_dependent = False,
    arch_dependent = False,
    doc = "Installs a Flutter SDK toolchain and optionally resolves pub dependencies including Flutter SDK packages.",
)
