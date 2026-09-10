"""`flutter_gen_l10n`: ARB files in, generated `AppLocalizations` Dart out.

Runs the gen-l10n generator vendored by `flutter_gen_l10n_repo`. Configuration
comes from rule attributes rather than an `l10n.yaml`, because Bazel must know
the output file names during analysis and a file read at action time cannot
inform that. An `l10n.yaml` in the workspace is simply not consulted.

## Why the outputs are grouped, not one-per-input

The generator emits one Dart file per **primary language subtag**, not per arb
file. `app_es.arb` and `app_es_419.arb` together produce a single
`app_localizations_es.dart` holding both `AppLocalizationsEs` and
`AppLocalizationsEs419`. Declaring one output per input would therefore promise
Bazel files the generator never writes, and the build would fail with an opaque
"output was not created" the first time anyone added a regional variant. The
grouping below is what keeps that correct.
"""

def _locale_of(basename, prefix, label):
    """The locale a template-prefixed arb filename encodes, e.g. `es_419`."""
    if not basename.endswith(".arb"):
        fail("%s: `arbs` must be .arb files, got %r." % (label, basename))
    if not basename.startswith(prefix):
        fail(
            ("%s: arb file %r does not start with %r, the prefix implied by " +
             "template_arb_file. gen-l10n identifies a file's locale by the " +
             "part of its name after that prefix, so every arb must share " +
             "it.") % (label, basename, prefix),
        )
    return basename[len(prefix):-len(".arb")]

def _primary_subtag(locale):
    """`es_419` and `zh_Hant_TW` collapse to `es` and `zh`."""
    for sep in ["_", "-"]:
        if sep in locale:
            return locale.split(sep)[0]
    return locale

def _output_names(ctx, prefix):
    """Declared output filenames: the base file plus one per primary subtag."""
    base = ctx.attr.output_localization_file
    if not base.endswith(".dart"):
        fail("%s: output_localization_file must end in .dart, got %r." % (
            ctx.label,
            base,
        ))
    stem = base[:-len(".dart")]

    subtags = []
    for src in ctx.files.arbs:
        subtag = _primary_subtag(_locale_of(src.basename, prefix, ctx.label))
        if subtag not in subtags:
            subtags.append(subtag)

    # Sorted so the declared set does not depend on `arbs` ordering.
    return [base] + ["%s_%s.dart" % (stem, s) for s in sorted(subtags)]

def _flutter_gen_l10n_impl(ctx):
    template = ctx.attr.template_arb_file
    underscore = template.rfind("_")
    if underscore < 0 or not template.endswith(".arb"):
        fail(
            ("%s: template_arb_file must look like `<prefix>_<locale>.arb` " +
             "(e.g. `app_en.arb`), got %r.") % (ctx.label, template),
        )
    prefix = template[:underscore + 1]

    srcs = ctx.files.arbs
    if not srcs:
        fail("%s: `arbs` must not be empty." % ctx.label)

    templates = [s for s in srcs if s.basename == template]
    if not templates:
        fail(
            "%s: template_arb_file %r is not among `arbs`. The template " %
            (ctx.label, template) +
            "carries the messages every other locale is checked against, so " +
            "it must be one of the inputs.",
        )

    # Outputs land beside the arb files, matching how dart_codegen places its
    # own output next to the source: the generated files import each other by
    # bare filename, so they have to be siblings.
    arb_dir = srcs[0].dirname
    for s in srcs:
        if s.dirname != arb_dir:
            fail(
                ("%s: every arb must sit in one directory (gen-l10n takes a " +
                 "single --arb-dir); %r is in %r but %r is in %r.") % (
                    ctx.label,
                    srcs[0].basename,
                    arb_dir,
                    s.basename,
                    s.dirname,
                ),
            )

    rel_dir = srcs[0].short_path[:-len(srcs[0].basename)]
    if rel_dir.startswith(ctx.label.package + "/"):
        rel_dir = rel_dir[len(ctx.label.package) + 1:]

    outs = [
        ctx.actions.declare_file(rel_dir + name)
        for name in _output_names(ctx, prefix)
    ]

    # The entrypoint parses `--key=value`, so each flag is one argv entry.
    # Everything here is known at analysis time, so a plain list is clearer
    # than an Args builder.
    argv = [
        "--project-dir=.",
        "--arb-dir=" + arb_dir,
        "--output-dir=" + outs[0].dirname,
        "--template-arb-file=" + template,
        "--output-localization-file=" + ctx.attr.output_localization_file,
        "--output-class=" + ctx.attr.output_class,
    ]
    if ctx.attr.preferred_supported_locales:
        argv.append("--preferred-supported-locales=" +
                    ",".join(ctx.attr.preferred_supported_locales))
    if ctx.attr.header:
        argv.append("--header=" + ctx.attr.header)
    if ctx.attr.use_deferred_loading:
        argv.append("--use-deferred-loading")
    if not ctx.attr.nullable_getter:
        argv.append("--no-nullable-getter")
    if ctx.attr.required_resource_attributes:
        argv.append("--required-resource-attributes")
    if ctx.attr.use_escaping:
        argv.append("--use-escaping")
    if ctx.attr.relax_syntax:
        argv.append("--relax-syntax")
    if ctx.attr.use_named_parameters:
        argv.append("--use-named-parameters")
    if ctx.attr.suppress_warnings:
        argv.append("--suppress-warnings")

    ctx.actions.run(
        executable = ctx.executable._generator,
        arguments = argv,
        inputs = srcs,
        outputs = outs,
        mnemonic = "FlutterGenL10n",
        progress_message = "Generating localizations for %{label}",
    )

    return [DefaultInfo(files = depset(outs))]

flutter_gen_l10n = rule(
    implementation = _flutter_gen_l10n_impl,
    attrs = {
        "arbs": attr.label_list(
            doc = "The `.arb` files, all in one directory, including the " +
                  "template. Their names determine the generated file names.",
            allow_files = [".arb"],
            mandatory = True,
        ),
        "template_arb_file": attr.string(
            doc = "The arb holding the source-of-truth messages. Its name " +
                  "also fixes the `<prefix>_` every other arb must share.",
            default = "app_en.arb",
        ),
        "output_localization_file": attr.string(
            doc = "Base output file name; per-locale files append the " +
                  "primary language subtag to its stem.",
            default = "app_localizations.dart",
        ),
        "output_class": attr.string(
            doc = "Name of the generated abstract class.",
            default = "AppLocalizations",
        ),
        "preferred_supported_locales": attr.string_list(
            doc = "Locales to place first in `supportedLocales`.",
        ),
        "header": attr.string(
            doc = "Comment text prepended to every generated file.",
        ),
        "use_deferred_loading": attr.bool(
            doc = "Emit deferred imports, for web code splitting.",
            default = False,
        ),
        "nullable_getter": attr.bool(
            doc = "Whether `AppLocalizations.of(context)` may return null. " +
                  "Upstream's default is True.",
            default = True,
        ),
        "required_resource_attributes": attr.bool(
            doc = "Require `@`-metadata for every message.",
            default = False,
        ),
        "use_escaping": attr.bool(
            doc = "Honour single-quote escaping in ICU messages.",
            default = False,
        ),
        "relax_syntax": attr.bool(
            doc = "Accept upstream's relaxed ICU syntax.",
            default = False,
        ),
        "use_named_parameters": attr.bool(
            doc = "Generate named rather than positional parameters.",
            default = False,
        ),
        "suppress_warnings": attr.bool(
            doc = "Silence generator warnings, including untranslated " +
                  "message reports. Off by default deliberately.",
            default = False,
        ),
        "_generator": attr.label(
            default = "//flutter/private/gen_l10n:gen_l10n",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Generates Flutter `AppLocalizations` Dart from `.arb` files.",
)
