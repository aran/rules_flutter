"""The Flutter SDKs the `flutter` extension declared, for the `pub` extension.

The locks are another extension's (`pub`), so that a lock it refuses
fails the hubs and not the toolchains. The hubs still build each SDK's
framework packages, so that extension needs what this one decided about the
SDKs: each one's release and framework source. It reads them here, from
`sdks.json`, rather than from the toolchain tags it cannot see.
"""

def _flutter_sdks_repo_impl(ctx):
    ctx.file("BUILD.bazel", "")

    # Each framework by its canonical label, which the `pub` extension can
    # name it by: the `flutter` extension names the frameworks it declares
    # itself by their names within it.
    sdks = json.decode(ctx.attr.sdks)
    for name, label in ctx.attr.frameworks.items():
        sdks[name]["framework"] = str(label)
    ctx.file(SDKS_FILE, json.encode(sdks))
    return ctx.repo_metadata(reproducible = True)

flutter_sdks_repo = repository_rule(
    implementation = _flutter_sdks_repo_impl,
    attrs = {
        "sdks": attr.string(
            doc = "JSON: each SDK's name to its `version` (empty when its " +
                  "framework and engine are both given). `encode_sdks` writes it.",
            mandatory = True,
        ),
        "frameworks": attr.string_keyed_label_dict(
            doc = "The `flutter_framework.json` of each SDK whose framework is not the release's.",
        ),
    },
    doc = "Writes `sdks.json`, the SDKs the `flutter` extension's tags declared.",
)

SDKS_FILE = "sdks.json"

def encode_sdks(sdks):
    """`sdks` (structs by name, as the `flutter` extension holds them) as JSON, but for their frameworks.

    A framework goes in `frameworks`, whose labels Bazel makes canonical.
    """
    return json.encode({
        name: {"version": sdk.version or "", "framework": ""}
        for name, sdk in sdks.items()
    })

def decode_sdks(text):
    """The SDKs `flutter_sdks_repo` wrote, as structs with `name`, `version`, `framework`."""
    return {
        name: struct(
            name = name,
            version = fields["version"] or None,
            framework = Label(fields["framework"]) if fields["framework"] else None,
        )
        for name, fields in json.decode(text).items()
    }
