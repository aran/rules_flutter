"""The Material fonts a Flutter framework expects, as a repository.

A framework says which fonts archive it expects in
`bin/internal/material_fonts.version`: the archive's path under Flutter's
storage (`flutter_infra_release/flutter/fonts/<revision>/fonts.zip`), which
flutter_tools' `MaterialFonts` appends to the storage URL. The pinned releases
each name one. For a framework that is not a release, the path is looked up in
the ones the pinned releases name, and downloaded with the digest recorded for
it; a path no release names fails, naming it and the attribute that pins it
(`material_fonts_sha256` of the tag that declares the SDK).
"""

load("//flutter/private:framework_source.bzl", "framework_root", "unset_message", "write_unset_stub")
load("//flutter/private:pinned.bzl", "pinned")
load("//flutter/private:versions.bzl", "ARTIFACT_CHECKSUMS", "FLUTTER_VERSIONS")

visibility("//flutter/...")

_STORAGE = "https://storage.googleapis.com/"

def _known_archives():
    """The fonts archives the pinned releases name, by path, with the digest of each."""
    return {
        meta.material_fonts_url: ARTIFACT_CHECKSUMS.get(version, {}).get("material_fonts.zip", "")
        for version, meta in FLUTTER_VERSIONS.items()
    }

def _flutter_material_fonts_repo_impl(repository_ctx):
    known = _known_archives()
    if repository_ctx.attr.framework_json:
        unset = unset_message(repository_ctx)
        if unset:
            write_unset_stub(repository_ctx, ["material-fonts/MaterialIcons-Regular.otf"], unset)
            return
        version_file = framework_root(repository_ctx).get_child("bin").get_child("internal").get_child("material_fonts.version")
        archive = repository_ctx.read(version_file).strip()
        sha256 = repository_ctx.attr.sha256 or known.get(archive, "")
        if not sha256:
            fail((
                "The framework expects the Material fonts archive {archive} " +
                "(bin/internal/material_fonts.version), which no pinned Flutter release names. " +
                "Pin its digest with material_fonts_sha256 = \"<sha256 of {url}>\" on the " +
                "flutter.custom_framework, flutter.custom_sdk or flutter.checkout that declares the SDK."
            ).format(archive = archive, url = _STORAGE + archive))
    else:
        archive = FLUTTER_VERSIONS[repository_ctx.attr.flutter_version].material_fonts_url
        sha256 = known[archive]

    repository_ctx.download_and_extract(
        url = _STORAGE + archive,
        sha256 = pinned("material_fonts.zip", sha256),
        output = "material-fonts",
    )
    repository_ctx.file(
        "BUILD.bazel",
        'exports_files(["material-fonts/MaterialIcons-Regular.otf"], visibility = ["//visibility:public"])\n',
    )

flutter_material_fonts_repo = repository_rule(
    _flutter_material_fonts_repo_impl,
    doc = "The Material fonts archive a Flutter framework expects.",
    attrs = {
        "flutter_version": attr.string(doc = "A pinned release whose fonts these are. Unused with `framework_json`."),
        "framework_json": attr.label(
            doc = "The `flutter_framework.json` of a framework source, whose `bin/internal/material_fonts.version` names the archive.",
            allow_single_file = True,
        ),
        "sha256": attr.string(doc = "The digest of the fonts archive, for an archive no pinned release names."),
    },
)
