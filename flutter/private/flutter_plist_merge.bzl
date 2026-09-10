"""XML property list merging — the additive seam rules_apple does not provide.

`rules_apple` merges `infoplists` natively but takes exactly *one*
`entitlements` file, so an app needing one extra `com.apple.security.*` key
would otherwise have to take over the whole `flutter create` scaffold file
and hand-maintain it. This rule runs the strict rules_flutter plist merger
(`merge_plists.dart`) over a base plist and one or more additions.

Two explicit modes, both never-wrong:

  `strict-add` — additions may only add. A key the base already declares
      with an identical value dedupes silently; a different value is a hard
      error naming the key and both files. This backs the
      `additional_entitlements` attribute of `flutter_macos_app` /
      `flutter_ios_app`.

  `supplement` — the base always wins and same-key string arrays are
      unioned. This backs rules_flutter's own dev-only iOS Dart VM service
      keys, so an app that declares its own `NSBonjourServices` or
      `NSLocalNetworkUsageDescription` keeps them and still gets a
      debuggable VM service.
"""

_TOOL = Label("//flutter/private/tools:merge_plists.dart")

def _flutter_plist_merge_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    tool = ctx.file._merge_tool
    output = ctx.actions.declare_file(
        "%s/%s" % (ctx.label.name, ctx.attr.output_basename),
    )

    arguments = [tool.path, "--mode", ctx.attr.mode]
    inputs = [tool]
    if ctx.file.base:
        arguments += ["--base", ctx.file.base.path]
        inputs.append(ctx.file.base)
    for addition in ctx.files.additions:
        arguments += ["--addition", addition.path]
        inputs.append(addition)
    for key in ctx.attr.drop_empty_keys:
        arguments += ["--drop-empty", key]
    arguments += ["--output", output.path]

    ctx.actions.run(
        executable = flutter_sdk_info.dart,
        arguments = arguments,
        inputs = depset(
            direct = inputs,
            transitive = [flutter_sdk_info.tool_files],
        ),
        outputs = [output],
        mnemonic = "FlutterPlistMerge",
        progress_message = "Merging plist %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([output]))]

flutter_plist_merge = rule(
    implementation = _flutter_plist_merge_impl,
    attrs = {
        "base": attr.label(
            doc = "The plist the additions merge into. May be omitted — iOS " +
                  "apps legitimately ship no entitlements file — in which " +
                  "case the additions merge into an empty plist.",
            allow_single_file = True,
        ),
        "additions": attr.label_list(
            doc = "Plist files whose root-dictionary keys merge into `base`, " +
                  "in order. May be empty when `drop_empty_keys` is the only " +
                  "job.",
            allow_files = True,
        ),
        "drop_empty_keys": attr.string_list(
            doc = "Keys to remove from `base` when their value is an empty " +
                  "string. For the `flutter create` scaffold's own " +
                  "placeholders: the macOS `Info.plist` declares " +
                  "`CFBundleIconFile` as `<string></string>` for Xcode to " +
                  "fill in, and Apple's plisttool refuses that against the " +
                  "value `macos_application` generates from an app icon " +
                  "catalog. A key with a real value is left alone, so a " +
                  "genuine conflict is still reported.",
        ),
        "mode": attr.string(
            doc = "How a key present in both the base and an addition is " +
                  "resolved. See the module docstring.",
            mandatory = True,
            values = ["strict-add", "supplement"],
        ),
        "output_basename": attr.string(
            doc = "File name of the merged plist. Apple's rules select " +
                  "behaviour by extension, so the caller names it.",
            mandatory = True,
        ),
        "_merge_tool": attr.label(
            default = _TOOL,
            allow_single_file = True,
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ],
    doc = "Merges plist additions into a base plist under an explicit mode, " +
          "and drops the scaffold placeholders named by `drop_empty_keys`.",
)

def flutter_entitlements_merge(name, additions, base = None, **kwargs):
    """Merges entitlement additions into a base entitlements file.

    The `strict-add` arm of `flutter_plist_merge`, and the rule behind the
    `additional_entitlements` attribute of `flutter_macos_app` and
    `flutter_ios_app`. Use it directly when assembling a `macos_application`
    or `ios_application` yourself (Tier 2).

    Additions may only *add* keys: a key the base already declares with an
    identical value dedupes silently, a different value is a hard error.
    That dedupe is what lets one addition file be merged into both
    `DebugProfile.entitlements` (which already grants some of what an app
    adds) and `Release.entitlements`.

    Args:
        name: Target name. Pass to `entitlements` on the bundle rule.
        additions: Entitlement plist files to merge in, in order.
        base: The entitlements file to merge into. Omit for an app that
            ships none (valid on iOS), in which case the additions are the
            entitlements. May be a `select()`.
        **kwargs: Additional arguments (e.g. visibility, tags). `tags`
            defaults to `["manual"]`.
    """
    tags = kwargs.pop("tags", ["manual"])
    flutter_plist_merge(
        name = name,
        base = base,
        additions = additions,
        mode = "strict-add",
        output_basename = "Merged.entitlements",
        tags = tags,
        **kwargs
    )
