"""What a Flutter program rule hands rules_dart's analysis: its own Dart files.

A program (`flutter_application`, `flutter_application_variant`,
`flutter_test`, `flutter_web_application`) is a bundle, not a library, so no
`DartInfo` names its files. `program_analyzable_info` is the one place each
of them says which files are its own, and `StagedSourcesInfo` is how a rule
that stages copies of source files into a program names the sources.
"""

load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_analyzable_info", "package_info_from_metadata", "package_lib_prefix")

visibility("//flutter/...")

StagedSourcesInfo = provider(
    doc = "The source files a target's Dart outputs are copies of. A program " +
          "compiles the copies, and analysis checks these in their place: " +
          "analysis checks no generated file.",
    fields = {
        "sources": "Depset of source Files, each staged under the same basename beside its siblings, so their relative imports resolve alike.",
    },
)

BundledProgramInfo = provider(
    doc = "The program a part of a platform's app bundle is built from, for " +
          "the app to pass on what the bundle rule (rules_apple's, " +
          "rules_android's `android_binary`) passes on " +
          "nothing of: the program's Dart files, for rules_dart's analysis, " +
          "and the split debug info of the snapshot it ships.",
    fields = {
        "info": "The program's `DartAnalyzableInfo`, or None.",
        "debug_info": "Depset of the program's `debug_info` output group: " +
                      "its `.symbols`, built in the bundle's configuration.",
    },
)

def bundled_program_info(application):
    """The `BundledProgramInfo` of a bundle part built from `application`.

    Args:
      application: The part's `flutter_application` (or variant) Target.

    Returns:
      A list of one `BundledProgramInfo`.
    """
    groups = application[OutputGroupInfo] if OutputGroupInfo in application else None
    return [BundledProgramInfo(
        info = application[DartAnalyzableInfo] if DartAnalyzableInfo in application else None,
        debug_info = groups.debug_info if groups and "debug_info" in groups else depset(),
    )]

def _bundled_program_aspect_impl(_target, ctx):
    # The parts of the bundle, as the bundle rule configured them, so the
    # program found is the one the app ships. Each part that has one names the
    # same application.
    attrs = ctx.rule.attr
    parts = list(getattr(attrs, "deps", [])) + list(getattr(attrs, "additional_contents", {}).keys())
    for part in parts:
        if BundledProgramInfo in part:
            return [part[BundledProgramInfo]]
    return []

# Applied to an Apple bundle or an `android_binary` alone, without
# propagating: it reads the `BundledProgramInfo` of the bundle's direct parts.
bundled_program_aspect = aspect(
    implementation = _bundled_program_aspect_impl,
    doc = "Finds the program among an app bundle's direct parts (`deps`, `additional_contents`).",
)

# Analysis-only. `package:sky_engine`'s `lib/_embedder.yaml` is the whole of how
# the analyzer resolves `dart:ui`. An implicit attribute, because needing it is
# a property of analyzing Flutter Dart, not a choice a BUILD file makes; it
# reaches only `program_analyzable_info`, so no compile action's inputs change.
def program_sky_engine_attr(cfg = "target"):
    """The implicit `_sky_engine` attribute of a program rule.

    Args:
      cfg: The configuration `sky_engine` is built in. It must be the one the
        rule's `deps` are built in: a library reaches `sky_engine` through
        its own dependencies, and the analyzer reads one SDK, so a second
        copy of it in another configuration is a second SDK.

    Returns:
      An `attr.label`.
    """
    return attr.label(
        default = Label("@flutter_sky_engine//:sky_engine"),
        providers = [DartInfo],
        cfg = cfg,
    )

def staged_sources(targets):
    """The sources `targets` staged copies of, from their `StagedSourcesInfo`.

    Args:
      targets: Targets, some of which may provide `StagedSourcesInfo`.

    Returns:
      A list of source Files.
    """
    return depset(transitive = [
        t[StagedSourcesInfo].sources
        for t in targets
        if StagedSourcesInfo in t
    ]).to_list()

def program_analyzable_info(ctx, package, package_root, deps, files):
    """The `DartAnalyzableInfo` of a program in `package`, over its own `files`.

    Built by `dart_analyzable_info` rather than the package-less constructor:
    a program names its package, and its sources import that package's `lib/`
    by `package:<self>/…`, which a package-less closure reports as
    `uri_does_not_exist`. `package_root` is the root the compile path names,
    so the analyzer and the compiler agree on what `package:<self>/…` is.

    Files are split by path. One under the package's `lib/` is reachable as
    `package:<self>/…` and is among `srcs`; any other (a `test/` or
    `integration_test/` entry point, a `main` beside `web/`, a staged file) is
    an entry source. Generated files may be among them: analysis stages them
    for imports to resolve and checks only sources.

    Args:
      ctx: The rule context. Reads `_sky_engine` (`program_sky_engine_attr`),
        which joins the analyzer's closure and nothing else.
      package: The program's `DartPackageMetadataInfo`.
      package_root: The package's root, as the compile path takes it.
      deps: The program's dependencies, providing `DartInfo`.
      files: The program's own Dart files: its `main`, its sources, and the
        sources of whatever it compiles copies of.

    Returns:
      A `DartAnalyzableInfo`.
    """
    prefix = package_lib_prefix(package_root)

    # A list when the rule gives the attribute a configuration transition.
    sky_engine = ctx.attr._sky_engine
    if type(sky_engine) == "list":
        sky_engine = sky_engine[0]
    return dart_analyzable_info(
        label = ctx.label,
        # The declaration the compile path names, so the analyzer reads the
        # language version the compiler does.
        packages = [package_info_from_metadata(ctx.label, package, package_root)],
        deps = deps + [sky_engine],
        srcs = [f for f in files if f.short_path.startswith(prefix)],
        entry_srcs = [f for f in files if not f.short_path.startswith(prefix)],
    )
