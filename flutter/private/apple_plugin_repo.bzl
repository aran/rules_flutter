"""The Apple libraries of a pub plugin, as its `Package.swift` says to build them.

A plugin's source repository (`flutter_pub_package`) says which of iOS and
macOS it has a library for, and where its sources are: the directory of its
`Package.swift` (`ios/<plugin>`, or `darwin/<plugin>` with
`sharedDarwinSource`), or, for a plugin without one, the directories of its
CocoaPods layout. This repository builds each of those libraries. It reads a
`Package.swift` with Xcode's `swift package dump-package`, which evaluates the
manifest as SwiftPM does, and turns the plugin's target into a
`flutter_apple_plugin_library` (`swiftpm_manifest.bzl`); a manifest it cannot
honour gets a stand-in that fails the platform's build, naming why.

Only an iOS or macOS build reaches the libraries, so only such a build fetches
this repository, and needs Xcode for it: other builds, and other hosts, never
evaluate a manifest.
"""

load(":flutter_pub_index.bzl", "SPOKE_PREFIX", "sibling_path", "source_repo")
load(
    ":swift_packages.bzl",
    "SWIFT_PACKAGES_FILE",
    "SWIFT_PACKAGES_REPO",
    "pins_from_listing",
    "requirement_swift",
    "requirement_text",
    "requirement_violation",
    "swift_package_repo",
    "swift_product_label",
)
load(":swiftpm_app_settings.bzl", "defines_header_name")
load(
    ":swiftpm_manifest.bzl",
    "CONFIGURATIONS",
    "SWIFTPM_HEADER_EXTENSIONS",
    "SWIFTPM_SOURCE_EXTENSIONS",
    "shell_quote_copt",
    "swift_package_message",
    "swift_package_targets",
)

visibility("//flutter/...")

# What a plugin's source repository writes for this one.
APPLE_PLUGIN_FILE = "flutter_apple_plugin.json"

# The extensions of a CocoaPods-layout plugin's sources.
_LEGACY_EXTENSIONS = ("swift", "m", "mm", "h")

def apple_repo(package, prefix = SPOKE_PREFIX):
    """The name of the repository holding a plugin's Apple libraries."""
    return "{}_apple__{}".format(prefix, package)

def apple_library_label(package, platform, prefix = SPOKE_PREFIX):
    """The label, in a sibling repository's BUILD file, of a plugin's `platform` library."""
    return "@{}//:{}_apple_{}".format(apple_repo(package, prefix), package, platform)

def _dump_package(ctx, manifest_dir):
    """`swift package dump-package` of the package in `manifest_dir`, decoded."""
    xcrun = ctx.which("xcrun")
    if not xcrun:
        fail((
            "package:{pkg}: building its iOS or macOS library reads its Package.swift " +
            "with Xcode's `swift package dump-package`, and `xcrun` is not on PATH. " +
            "Install Xcode, or select it with `xcode-select`."
        ).format(pkg = ctx.attr.package_name))

    # SwiftPM writes its build state under the scratch path, by default in
    # the package: keep the plugin's files as they are.
    scratch = ctx.path("_swiftpm_scratch")
    result = ctx.execute(
        [
            xcrun,
            "swift",
            "package",
            "--package-path",
            str(manifest_dir),
            "--scratch-path",
            str(scratch),
            "--manifest-cache",
            "none",
            "dump-package",
        ],
        quiet = True,
    )
    ctx.delete(scratch)
    if result.return_code != 0:
        fail("package:{pkg}: `swift package dump-package` of {dir} failed:\n{err}".format(
            pkg = ctx.attr.package_name,
            dir = manifest_dir,
            err = result.stderr,
        ))
    return json.decode(result.stdout)

def _configured(values, quote):
    """A BUILD expression of the list `values` (a dict by configuration) selects."""
    always = [quote(v) for v in values[""]]
    debug = [quote(v) for v in values["debug"]]
    release = [quote(v) for v in values["release"]]
    if not debug and not release:
        return repr(always)
    return '{} + select({{\n        "@rules_flutter//flutter/private:swiftpm_release": {},\n        "//conditions:default": {},\n    }})'.format(
        repr(always),
        repr(release),
        repr(debug),
    )

def _unique(values):
    """`values` without repeats, in first-seen order."""
    return {v: None for v in values}.keys()

def _make_variables_escaped(flag):
    return flag.replace("$", "$$")

def _patterns(ctx, path, extensions):
    """Glob patterns for the files with `extensions` at `path`, a file or a directory."""
    if not ctx.path(path).exists:
        fail("package:{}: its Package.swift names {}, which it does not have".format(ctx.attr.package_name, path))
    if ctx.path(path).is_dir:
        return ["{}/**/*.{}".format(path, ext) for ext in extensions]
    return [path]

def _target_label(package, platform, target, main):
    """The name of a package target's library: the plugin's own for its module."""
    name = "{}_apple_{}".format(package, platform)
    return name if target == main else "{}__{}".format(name, target)

def _files_under(ctx, path):
    """The files at `path` (repository-relative): itself, or those under it."""
    root = ctx.path(path)
    if not root.exists:
        fail("package:{}: its Package.swift names the resource {}, which it does not have".format(ctx.attr.package_name, path))
    if not root.is_dir:
        return [path]
    found = []
    stack = [(root, path)]
    for _ in range(100000):
        if not stack:
            break
        directory, relative = stack.pop()
        for entry in directory.readdir():
            child = relative + "/" + entry.basename
            if entry.is_dir:
                stack.append((entry, child))
            else:
                found.append(child)
    return sorted(found)

_SWIFT_BUNDLE_ACCESSOR = """\
// Generated by rules_flutter, as SwiftPM generates it for a target with
// resources: `Bundle.module` is the bundle they are in.
import Foundation

private final class _BundleFinder {{}}

extension Foundation.Bundle {{
    static let module: Bundle = {{
        let name = "{bundle}.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: _BundleFinder.self).resourceURL,
            Bundle.main.bundleURL,
        ]
        for candidate in candidates {{
            if let url = candidate?.appendingPathComponent(name), let bundle = Bundle(url: url) {{
                return bundle
            }}
        }}
        fatalError("could not find the resource bundle \\(name)")
    }}()
}}
"""

_OBJC_BUNDLE_ACCESSOR_H = """\
// Generated by rules_flutter, as SwiftPM generates it for a target with
// resources: `SWIFTPM_MODULE_BUNDLE` is the bundle they are in.
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#if __cplusplus
extern "C" {{
#endif
NSBundle *{module}_SWIFTPM_MODULE_BUNDLE(void);
#define SWIFTPM_MODULE_BUNDLE {module}_SWIFTPM_MODULE_BUNDLE()
#if __cplusplus
}}
#endif
#endif
"""

_OBJC_BUNDLE_ACCESSOR_M = """\
// Generated by rules_flutter, as SwiftPM generates it for a target with
// resources.
#import <Foundation/Foundation.h>

@interface __{module}_BundleFinder : NSObject
@end

@implementation __{module}_BundleFinder
@end

NSBundle *{module}_SWIFTPM_MODULE_BUNDLE(void) {{
    NSString *name = @"{bundle}.bundle";
    NSArray<NSURL *> *candidates = @[
        [[NSBundle mainBundle] resourceURL] ?: [[NSBundle mainBundle] bundleURL],
        [[NSBundle bundleForClass:[__{module}_BundleFinder class]] resourceURL] ?: [[NSBundle mainBundle] bundleURL],
        [[NSBundle mainBundle] bundleURL],
    ];
    for (NSURL *candidate in candidates) {{
        NSBundle *bundle = [NSBundle bundleWithURL:[candidate URLByAppendingPathComponent:name]];
        if (bundle != nil) {{
            return bundle;
        }}
    }}
    return nil;
}}
"""

def _has_swift(ctx, target):
    """Whether the target's sources hold Swift, which makes it a Swift module."""
    for source in target.sources:
        if ctx.path(source).is_dir:
            if [f for f in _files_under(ctx, source) if f.endswith(".swift")]:
                return True
        elif source.endswith(".swift"):
            return True
    return False

def _resource_bundle(ctx, label, target):
    """The resource bundle of a target with resources, as SwiftPM makes it.

    SwiftPM puts a target's resources in `<package>_<target>.bundle`, which
    the app carries, and gives the target an accessor for it: `Bundle.module`
    in Swift, `SWIFTPM_MODULE_BUNDLE` in Objective-C. A privacy manifest is
    the app's already (`apple_privacy_files`), so it is not bundled again.

    Returns:
        A struct with `build`, the bundle's BUILD text; and what the
        target's library takes for it: `srcs` (the accessor), `data`,
        `includes` and `clang_copts`.
    """
    processed = []
    copied = []
    strip = []
    for resource in target.resources:
        files = [f for f in _files_under(ctx, resource.path) if not f.endswith(".xcprivacy")]
        if resource.copy:
            copied.extend(files)
            strip.append(resource.path.rsplit("/", 1)[0])
        else:
            processed.extend(files)
    if not processed and not copied:
        return struct(build = "", srcs = [], data = [], includes = [], clang_copts = [])

    bundle = label + "__resources"
    accessor_dir = "_swiftpm/" + label
    module = target.name
    if _has_swift(ctx, target):
        ctx.file(accessor_dir + "/resource_bundle_accessor.swift", _SWIFT_BUNDLE_ACCESSOR.format(bundle = target.resource_bundle))
        srcs = [accessor_dir + "/resource_bundle_accessor.swift"]
        includes = []
        clang_copts = []
    else:
        ctx.file(accessor_dir + "/resource_bundle_accessor.h", _OBJC_BUNDLE_ACCESSOR_H.format(module = module))
        ctx.file(accessor_dir + "/resource_bundle_accessor.m", _OBJC_BUNDLE_ACCESSOR_M.format(module = module, bundle = target.resource_bundle))
        srcs = [accessor_dir + "/resource_bundle_accessor.m", accessor_dir + "/resource_bundle_accessor.h"]
        includes = [accessor_dir]
        clang_copts = ["-include", "resource_bundle_accessor.h"]
    build = """
apple_resource_bundle(
    name = "{name}",
    bundle_name = "{bundle}",
    resources = {processed},
    structured_resources = {copied},
    strip_structured_resources_prefixes = {strip},
)
""".format(
        name = bundle,
        bundle = target.resource_bundle,
        processed = repr(processed),
        copied = repr(copied),
        strip = repr(_unique(strip)),
    )
    return struct(build = build, srcs = srcs, data = [":" + bundle], includes = includes, clang_copts = clang_copts)

def _swift_package_library(ctx, package, platform, target, main, manifest_dir, products, dynamic, app_settings = None):
    """A `flutter_apple_plugin_library` of `target` (`swift_package_targets`).

    With `app_settings`, a struct of `manifest` and `reference` (the
    manifest's fetch-time dump), the package's manifest decides its defines
    from the app: `target` has none of its own here, and takes them from a
    `flutter_swiftpm_app_settings` of its own, and the plugin's module is
    `<package>_apple_<platform>__app`, which the
    `flutter_swiftpm_app_library` named `<package>_apple_<platform>` stands
    for (`swiftpm_app_settings.bzl`).

    The plugin's module is named after the plugin, as its registrant imports
    it; each other target is a module named after itself, a Clang module
    when it has no Swift sources, as SwiftPM builds it.

    A `.dynamic` product is a framework in `flutter build`, whose global
    symbols all stay for Dart to look up. It is linked into the app here, so
    the plugin's module is wrapped, when `dynamic`, in
    `flutter_apple_kept_symbols`, which keeps the global symbols of the
    package's code through a release link's dead-code removal.
    """
    srcs = []
    for source in target.sources:
        srcs.extend(_patterns(ctx, source, SWIFTPM_SOURCE_EXTENSIONS + SWIFTPM_HEADER_EXTENSIONS))

    # A target's headers are its own, wherever its sources are named.
    srcs.extend(_patterns(ctx, target.dir, SWIFTPM_HEADER_EXTENSIONS))
    exclude = []
    for path in target.exclude:
        exclude.extend([path + "/**"] if ctx.path(path).is_dir else [path])
    srcs = _unique(srcs)

    # SwiftPM lets a target include any header of its package by path, and,
    # when it names its sources, any other file of its own directory
    # (libremidi_flutter compiles one `.cpp`, which includes the others).
    textual_hdrs = _patterns(ctx, manifest_dir, SWIFTPM_HEADER_EXTENSIONS)
    own_textual = []
    if [s for s in target.sources if s != target.dir]:
        own_textual = _patterns(ctx, target.dir, [e for e in SWIFTPM_SOURCE_EXTENSIONS if e != "swift"])
    public_hdrs = []
    if ctx.path(target.public_headers).is_dir:
        public_hdrs = _patterns(ctx, target.public_headers, SWIFTPM_HEADER_EXTENSIONS)

    label = _target_label(package, platform, target.name, main)
    if app_settings and target.name == main:
        label += APP_LIBRARY_SUFFIX
    resources = _resource_bundle(ctx, label, target)

    # The defines, for each app, of a manifest that decides them from it.
    settings_build = ""
    settings_deps = []
    settings_clang = []
    settings_swift = []
    settings_inputs = []
    if app_settings:
        settings = label + "__defines"
        settings_build = _APP_SETTINGS.format(
            name = settings,
            manifest = app_settings.manifest,
            reference = app_settings.reference,
            package = package,
            target = target.name,
            platform = platform,
        )
        settings_deps = [":" + settings]
        settings_clang = ["-include", defines_header_name(settings)]
        settings_swift = ["@$(execpath :{})".format(settings)]
        settings_inputs = [":" + settings]

    # The plugin's module of a `.dynamic` product is wrapped: the library is
    # `<label>_unkept`, and `<label>` is what keeps its symbols.
    kept = dynamic and target.name == main
    library = label + "_unkept" if kept else label

    # Linked SDK frameworks and libraries go to the link of whatever binary
    # links the plugin, configuration by configuration.
    linkopts = {
        c: (
            ["-Wl,-framework," + f for f in target.sdk_frameworks[c]] +
            ["-l" + d for d in target.sdk_dylibs[c]] +
            target.linkopts[c]
        )
        for c in CONFIGURATIONS
    }
    kept_build = _KEPT_SYMBOLS.format(
        name = label,
        library = library,
    ) if kept else ""
    return resources.build + settings_build + """
flutter_apple_plugin_library(
    name = "{library}",
    srcs = glob({srcs}, exclude = {exclude}, allow_empty = True) + {resource_srcs},
    data = {data},
    public_hdrs = glob({public_hdrs}, exclude = {exclude}, allow_empty = True),
    textual_hdrs = glob({textual_hdrs}, exclude = {own}, allow_empty = True) + glob({own_textual}, exclude = {srcs} + {exclude}, allow_empty = True),
    includes = {includes},
    clang_copts = {resource_copts} + {settings_clang} + {clang_copts},
    cxxopts = {cxxopts},
    conlyopts = {conlyopts},
    swift_copts = {settings_swift} + {swift_copts},
    swiftc_inputs = {settings_inputs},
    linkopts = {linkopts},
    deps = {deps},
    module_name = "{module}",
    swift_language_mode = {swift_language_mode},
    platform = "{platform}",
    visibility = ["//visibility:public"],
)
""".format(
        library = library,
        resource_srcs = repr(resources.srcs),
        resource_copts = repr(resources.clang_copts),
        data = repr(resources.data),
        module = package if target.name == main else target.name,
        swift_language_mode = repr(target.swift_language_mode),
        deps = repr([":" + _target_label(package, platform, d, main) for d in target.deps] + products + settings_deps),
        settings_clang = repr(settings_clang),
        settings_swift = repr(settings_swift),
        settings_inputs = repr(settings_inputs),
        platform = platform,
        srcs = repr(srcs),
        exclude = repr(exclude),
        public_hdrs = repr(public_hdrs),
        textual_hdrs = repr(textual_hdrs),
        own_textual = repr(own_textual),
        own = repr([target.dir + "/**"]),
        includes = repr(_unique(target.includes + resources.includes)),
        clang_copts = _configured(target.clang_copts, shell_quote_copt),
        cxxopts = _configured(target.cxxopts, shell_quote_copt),
        conlyopts = _configured(target.conlyopts, shell_quote_copt),
        swift_copts = _configured(target.swift_copts, _make_variables_escaped),
        linkopts = _configured(linkopts, _make_variables_escaped),
    ) + kept_build

# What the plugin's module of a library whose defines come from the app is
# named: `<package>_apple_<platform>` is the marker that stands for it.
APP_LIBRARY_SUFFIX = "__app"

_APP_SETTINGS = """
flutter_swiftpm_app_settings(
    name = "{name}",
    manifest = "{manifest}",
    manifest_path = "{manifest}",
    reference = "{reference}",
    package = "{package}",
    target = "{target}",
    platform = "{platform}",
    configuration = select({{
        "@rules_flutter//flutter/private:swiftpm_release": "release",
        "//conditions:default": "debug",
    }}),
    tags = ["manual"],
)
"""

_APP_LIBRARY = """
flutter_swiftpm_app_library(
    name = "{name}",
    library = "{name}{suffix}",
    visibility = ["//visibility:public"],
)
"""

# A library whose defines come from the app, and which cannot be built: the
# stand-in is both what its `flutter_plugin_platform`'s `lib` names and what the build's list holds.
_APP_LIBRARY_STAND_IN = """
alias(
    name = "{name}{suffix}",
    actual = ":{name}",
    visibility = ["//visibility:public"],
)
"""

_KEPT_SYMBOLS = """
flutter_apple_kept_symbols(
    name = "{name}",
    deps = [":{library}"],
    visibility = ["//visibility:public"],
)
"""

def _legacy_library(name, platform, layout):
    """A `flutter_apple_plugin_library` of a plugin without a `Package.swift`."""
    return """
flutter_apple_plugin_library(
    name = "{name}_apple_{platform}",
    srcs = glob({srcs}, allow_empty = True),
    includes = {includes},
    module_name = "{name}",
    platform = "{platform}",
    visibility = ["//visibility:public"],
)
""".format(
        name = name,
        platform = platform,
        srcs = repr([
            "{}/**/*.{}".format(d, ext)
            for d in layout["srcs_dirs"]
            for ext in _LEGACY_EXTENSIONS
        ]),
        includes = repr(layout["include_dirs"]),
    )

def _stand_in(name, platform, message):
    return """
flutter_unbuilt_plugin_library(
    name = "{name}_apple_{platform}",
    message = {message},
    visibility = ["//visibility:public"],
)
""".format(name = name, platform = platform, message = repr(message))

def _swift_packages(ctx):
    """The root's pins: `struct(pins, resolved)` (`swift_packages.bzl`)."""
    data = json.decode(ctx.read(sibling_path(ctx, SWIFT_PACKAGES_REPO, SWIFT_PACKAGES_FILE)))
    return struct(pins = pins_from_listing(data["pins"]), resolved = data["resolved"])

_PLATFORM_NAMES = {"ios": "iOS", "macos": "macOS"}

def _package_line(identity, remote):
    """The root `Package.swift`'s line for a remote package, from a plugin's requirement."""
    if identity not in remote:
        return "a dependency on `{}`".format(identity)
    url, requirement = remote[identity]
    return '.package(url: "{}", {}),'.format(url, requirement_swift(requirement))

def _unpinned_message(package, version, platform, manifest, unpinned, remote, resolved):
    return (
        "package:{pkg} {version} depends for {platform} on Swift packages that the root " +
        "module's `Package.resolved` does not pin ({manifest}):\n    {unpinned}\n" +
        "The root module declares the Swift packages plugins depend on, with " +
        "rules_swift_package_manager's `swift_deps.from_package`. Add each to the " +
        "`dependencies` of your root `Package.swift`:\n    {lines}\n" +
        "then run `bazel run @swift_package//:update` and `bazel mod tidy`, and add to " +
        "MODULE.bazel:\n    inject_repo(flutter_pub, {repos})\n" +
        "`bazel run @<hub>//swift:packages`, <hub> being the `name` of your " +
        "`flutter_pub.from_lock`, prints every line the plugins need.{read}"
    ).format(
        pkg = package,
        version = version,
        platform = _PLATFORM_NAMES[platform],
        manifest = manifest,
        unpinned = "\n    ".join([
            "{} ({})".format(identity, requirement_text(remote[identity][1])) if identity in remote else identity
            for identity in unpinned
        ]),
        lines = "\n    ".join([_package_line(identity, remote) for identity in unpinned]),
        repos = ", ".join(['"{}"'.format(swift_package_repo(identity)) for identity in unpinned]),
        read = (
            " The build reads " + ", ".join(resolved) + ": name the root's in " +
            "`flutter_pub.from_lock(swift_package_resolved = ...)`."
        ) if resolved else (
            " No `flutter_pub.from_lock` names a `Package.resolved`: name the root's in " +
            "its `swift_package_resolved`."
        ),
    )

def _violation_message(package, version, platform, manifest, violations, remote, resolved):
    return (
        "package:{pkg} {version} requires for {platform} Swift packages at versions the " +
        "root module's `Package.resolved` ({resolved}) does not pin ({manifest}):\n    {violations}\n" +
        "Make the root `Package.swift` ask for what the plugin requires:\n    {lines}\n" +
        "then run `bazel run @swift_package//:update`. `bazel run @<hub>//swift:packages` " +
        "prints the requirements of every plugin of the hub together."
    ).format(
        pkg = package,
        version = version,
        platform = _PLATFORM_NAMES[platform],
        manifest = manifest,
        resolved = ", ".join(resolved),
        violations = "\n    ".join([
            "{} {}; {}".format(identity, requirement_text(remote[identity][1]), why)
            for identity, why in violations
        ]),
        lines = "\n    ".join([_package_line(identity, remote) for identity, _ in violations]),
    )

def _apple_plugin_repo_impl(ctx):
    package = ctx.attr.package_name
    info_path = sibling_path(ctx, source_repo(package, ctx.attr.prefix), APPLE_PLUGIN_FILE)
    if not info_path.exists:
        # A package with no Apple library: nothing to build or report.
        ctx.file(SWIFT_REQUIREMENTS_FILE, json.encode({"package": package, "version": ctx.attr.version, "platforms": {}}))
        ctx.file("BUILD.bazel", _SWIFT_REQUIREMENTS_TARGET)
        return ctx.repo_metadata(reproducible = True)
    info = json.decode(ctx.read(info_path))
    plugin_root = info_path.dirname

    # The plugin's Apple directories, as they are in its source repository,
    # so the libraries' paths are the plugin's own.
    for directory in ("ios", "macos", "darwin"):
        if plugin_root.get_child(directory).exists:
            ctx.symlink(plugin_root.get_child(directory), directory)

    dumps = {}

    # What `swift:packages` reports: each platform's remote packages, with
    # the manifest's requirement of each.
    reported = {}
    swift_packages = None
    targets = []
    for platform in sorted(info["platforms"].keys()):
        layout = info["platforms"][platform]
        manifest_dir = layout["manifest_dir"]
        if not manifest_dir:
            targets.append(_legacy_library(package, platform, layout))
            continue
        manifest = manifest_dir + "/Package.swift"

        # A manifest that decides its defines from the app is evaluated for
        # each app in the build, and here only for the rest of what it says.
        app_settings = None
        if layout.get("app_settings"):
            app_settings = struct(
                manifest = manifest,
                reference = "_swiftpm/{}_{}.json".format(package, platform),
            )
        if manifest_dir not in dumps:
            dumps[manifest_dir] = _dump_package(ctx, plugin_root.get_child(manifest_dir))
        if app_settings:
            ctx.file(app_settings.reference, json.encode(dumps[manifest_dir]))
        built = swift_package_targets(dumps[manifest_dir], package, platform, manifest_dir, defines = not app_settings)
        if built.problems:
            targets.append(_stand_in(package, platform, swift_package_message(
                package,
                ctx.attr.version,
                platform,
                manifest,
                built.problems,
            )))
            if app_settings:
                targets.append(_APP_LIBRARY_STAND_IN.format(name = "{}_apple_{}".format(package, platform), suffix = APP_LIBRARY_SUFFIX))
            continue

        # The remote packages' products, from the root's repositories of them.
        remote = [p for t in built.targets for p in t.remote_products]
        requirements = _remote_requirements(dumps[manifest_dir])
        reported[platform] = [
            {"identity": identity, "url": requirements[identity][0], "requirement": requirements[identity][1]}
            for identity in sorted({i: None for i, _ in remote})
            if identity in requirements
        ]
        if remote and swift_packages == None:
            swift_packages = _swift_packages(ctx)
        unpinned = []
        violations = []
        for identity, _ in remote:
            pin = swift_packages.pins.get(identity)
            if not pin:
                if identity not in unpinned:
                    unpinned.append(identity)
                continue
            why = requirement_violation(requirements[identity][1], pin) if identity in requirements else ""
            if why and (identity, why) not in violations:
                violations.append((identity, why))
        problem = None
        if unpinned:
            problem = _unpinned_message(package, ctx.attr.version, platform, manifest, unpinned, requirements, swift_packages.resolved)
        elif violations:
            problem = _violation_message(package, ctx.attr.version, platform, manifest, violations, requirements, swift_packages.resolved)
        if problem:
            targets.append(_stand_in(package, platform, problem))
            if app_settings:
                targets.append(_APP_LIBRARY_STAND_IN.format(name = "{}_apple_{}".format(package, platform), suffix = APP_LIBRARY_SUFFIX))
            continue
        products = {}
        for identity, product in remote:
            if (identity, product) in products:
                continue
            products[(identity, product)] = "{}_apple_{}__{}__{}".format(package, platform, swift_package_repo(identity), product)
            targets.append(_SWIFT_PACKAGE_PRODUCT.format(
                name = products[(identity, product)],
                product = swift_product_label(identity, product),
                package = package,
                version = ctx.attr.version,
            ))
        for target in built.targets:
            labels = [":" + products[p] for p in target.remote_products]
            targets.append(_swift_package_library(ctx, package, platform, target, built.main, manifest_dir, labels, built.dynamic, app_settings))
        if app_settings:
            targets.append(_APP_LIBRARY.format(name = "{}_apple_{}".format(package, platform), suffix = APP_LIBRARY_SUFFIX))

    ctx.file("BUILD.bazel", """\
load("@rules_apple//apple:resources.bzl", "apple_resource_bundle")
load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")
load(
    "@rules_flutter//flutter/private:generated_repos.bzl",
    "flutter_apple_kept_symbols",
    "flutter_swift_package_product",
    "flutter_swiftpm_app_library",
    "flutter_swiftpm_app_settings",
    "flutter_unbuilt_plugin_library",
)
{targets}{requirements}""".format(
        targets = "".join(targets),
        requirements = _SWIFT_REQUIREMENTS_TARGET,
    ))
    ctx.file(SWIFT_REQUIREMENTS_FILE, json.encode({"package": package, "version": ctx.attr.version, "platforms": reported}))

    # What `dump-package` evaluates depends on the host's Xcode.
    return ctx.repo_metadata(reproducible = False)

# What `swift:packages` reads: the remote Swift packages each platform's
# library depends on, and what the manifest requires of each.
SWIFT_REQUIREMENTS_FILE = "swift_requirements.json"

_SWIFT_REQUIREMENTS_TARGET = """
exports_files(["swift_requirements.json"])
"""

_SWIFT_PACKAGE_PRODUCT = """
flutter_swift_package_product(
    name = "{name}",
    product = "{product}",
    package = "{package}",
    version = "{version}",
)
"""

def _remote_requirements(dump):
    """Each remote package a manifest depends on: identity to `(url, requirement)`."""
    found = {}
    for dep in dump.get("dependencies", []):
        for entry in dep.get("sourceControl", []):
            remote = (entry.get("location") or {}).get("remote") or [{}]
            found[entry.get("identity", "")] = (remote[0].get("urlString", ""), entry.get("requirement") or {})
    return found

flutter_apple_plugin_repo = repository_rule(
    implementation = _apple_plugin_repo_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "prefix": attr.string(
            default = SPOKE_PREFIX,
            doc = "What the build's repositories are named by (`source_repo`).",
        ),
        "version": attr.string(doc = "The package's version, for messages."),
    },
    doc = "The iOS and macOS libraries of a pub plugin, built as its `Package.swift` says. See the module docstring.",
)
