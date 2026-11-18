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

load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")

visibility("//flutter/...")

_TOOL = Label("//flutter/private/tools:merge_plists.dart")
_SIGNING_TOOL = Label("//flutter/private/tools:signing_entitlements.dart")

_EMPTY_PLIST = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
"""

def _flutter_plist_merge_impl(ctx):
    tools = portable_tools(ctx)

    tool = ctx.file._merge_tool
    output = ctx.actions.declare_file(
        "%s/%s" % (ctx.label.name, ctx.attr.output_basename),
    )

    args = ctx.actions.args()
    args.add(tool)
    args.add("--mode", ctx.attr.mode)
    inputs = [tool, ctx.file._plist_binary]
    if ctx.file.base:
        args.add("--base", ctx.file.base)
        inputs.append(ctx.file.base)
    args.add_all(ctx.files.additions, before_each = "--addition")
    inputs.extend(ctx.files.additions)
    args.add_all(ctx.attr.drop_empty_keys, before_each = "--drop-empty")
    args.add_all(
        ["%s=%s" % (k, v) for k, v in ctx.attr.substitutions.items()],
        before_each = "--substitute",
    )
    args.add("--output", output)

    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(
            direct = inputs,
            transitive = [tools.sdk_files.run],
        ),
        outputs = [output],
        mnemonic = "FlutterPlistMerge",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
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
        "substitutions": attr.string_dict(
            doc = "Text to replace in `base` before it is read, from to " +
                  "to: the Xcode variables a `flutter create` Info.plist " +
                  "leaves for the build. Unlike `expand_template`, it reads " +
                  "a plist saved in binary form.",
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
        # Imported by the merge tool to read a binary plist.
        "_plist_binary": attr.label(
            default = "//flutter/private/tools:plist_binary.dart",
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
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

def _flutter_signing_entitlements_impl(ctx):
    # No profile in this configuration, such as the simulator branch of a
    # `select()` that names one only for a device: the bundle is not signed
    # against a profile, and keeps its own entitlements. The bundle rule takes
    # a single file, so a bundle with none gets an empty dictionary.
    if not ctx.file.provisioning_profile:
        if ctx.file.entitlements:
            return [DefaultInfo(files = depset([ctx.file.entitlements]))]
        empty = ctx.actions.declare_file("%s/Signing.entitlements" % ctx.label.name)
        ctx.actions.write(empty, _EMPTY_PLIST)
        return [DefaultInfo(files = depset([empty]))]

    tools = portable_tools(ctx)
    output = ctx.actions.declare_file("%s/Signing.entitlements" % ctx.label.name)

    args = ctx.actions.args()
    args.add(ctx.file._signing_tool)
    args.add("--profile", ctx.file.provisioning_profile)
    inputs = [
        ctx.file._signing_tool,
        ctx.file._merge_tool,
        ctx.file._plist_binary,
        ctx.file.provisioning_profile,
    ]
    if ctx.file.entitlements:
        args.add("--entitlements", ctx.file.entitlements)
        inputs.append(ctx.file.entitlements)
    args.add("--output", output)

    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(
            direct = inputs,
            transitive = [tools.sdk_files.run],
        ),
        outputs = [output],
        mnemonic = "FlutterSigningEntitlements",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Writing the signing entitlements of %{label}",
    )

    return [DefaultInfo(files = depset([output]))]

flutter_signing_entitlements = rule(
    implementation = _flutter_signing_entitlements_impl,
    attrs = {
        "entitlements": attr.label(
            doc = "The bundle's own entitlements. May be omitted: an iOS app " +
                  "with no capabilities has none.",
            allow_single_file = True,
        ),
        "provisioning_profile": attr.label(
            doc = "The profile the bundle is signed against. May be a " +
                  "`select()` that gives `None` where the bundle is not " +
                  "signed against one: there the output is the bundle's own " +
                  "entitlements.",
            allow_single_file = True,
        ),
        "_merge_tool": attr.label(
            default = _TOOL,
            allow_single_file = True,
        ),
        "_plist_binary": attr.label(
            default = "//flutter/private/tools:plist_binary.dart",
            allow_single_file = True,
        ),
        "_signing_tool": attr.label(
            default = _SIGNING_TOOL,
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = """The entitlements a bundle is signed with against a provisioning profile.

They are the bundle's own and what Xcode takes from the profile: the bundle's
`application-identifier` (`com.apple.application-identifier` on macOS), and
the profile's `com.apple.developer.team-identifier` and `beta-reports-active`,
each only where the profile grants it and the bundle's own do not set it.
rules_apple adds the profile's `get-task-allow`. Pass the output to the bundle
rule's `entitlements`, beside the same `provisioning_profile`: without it,
rules_apple signs a bundle that has no entitlements with everything the
profile grants, and one that has some without a team identifier. In a
configuration with no profile the output is the bundle's own entitlements, or
an empty dictionary for a bundle with none.""",
)
