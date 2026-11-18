"""Keeps the global symbols of a Swift package's `.dynamic` product in the app.

`flutter build` embeds a `.dynamic` product as a framework, whose global
symbols all stay, and Dart looks them up with `DynamicLibrary.process()`.
rules_flutter links the product's code into the app, whose release link
removes code nothing references. This rule forwards a library as it is and
adds to its link a response file of `-Wl,-u,<symbol>` for each global symbol
the archives of the plugin's package define, which makes each a root for that removal. Every
other symbol of the app is left to it.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo", "swift_clang_module_aspect")
load(
    "//flutter/private:apple_xcode.bzl",
    "XCODE_TOOL_ATTRS",
    "XCODE_TOOL_FRAGMENTS",
    "XCODE_TOOL_TOOLCHAINS",
    "run_xcode_tool",
)
load("//flutter/private:flutter_apple_plugin_library.bzl", "FlutterAppleModuleHeadersInfo", "module_headers_aspect")

visibility("//flutter/...")

def _package_archives(library, repo):
    """The static archives `library` links that are built in the repository `repo`.

    Those are the targets of the plugin's Swift package, which a `.dynamic`
    product holds whole, and not the Swift packages it depends on, which
    are repositories of their own.
    """
    archives = []
    for linker_input in library[CcInfo].linking_context.linker_inputs.to_list():
        if linker_input.owner.repo_name != repo:
            continue
        for lib in linker_input.libraries:
            archive = lib.pic_static_library or lib.static_library
            if archive:
                archives.append(archive)
    return archives

def _impl(ctx):
    if len(ctx.attr.deps) != 1:
        fail("{}: deps is the one library to forward, got {}".format(ctx.label, ctx.attr.deps))
    library = ctx.attr.deps[0]
    archives = _package_archives(library, ctx.label.repo_name)
    if not archives:
        fail("{}: {} links no static archive, so it has no symbols to keep".format(ctx.label, library.label))

    flags = ctx.actions.declare_file(ctx.label.name + ".kept_symbols")

    # `nm` prints `<archive>(<member>):`, or `<archive>:`, before each
    # member's symbols, and a blank line between members: only the symbols
    # are wanted.
    run_xcode_tool(
        ctx,
        inputs = archives,
        outputs = [flags],
        command = 'xcrun nm -g -U -j "${@:2}" | grep -v -e ":$" -e "^$" | sort -u | sed "s/^/-Wl,-u,/" > "$1"',
        arguments = [flags.path] + [a.path for a in archives],
        mnemonic = "FlutterKeptSymbols",
        progress_message = "Listing the symbols %s keeps" % ctx.label,
    )

    keep = cc_common.create_linker_input(
        owner = ctx.label,
        user_link_flags = ["@" + flags.path],
        additional_inputs = depset([flags]),
    )
    cc_info = cc_common.merge_cc_infos(cc_infos = [
        library[CcInfo],
        CcInfo(linking_context = cc_common.create_linking_context(linker_inputs = depset([keep]))),
    ])

    # The library's resources are not forwarded: `apple_resource_aspect`
    # collects them from `deps`, as it does for any target.
    return [library[DefaultInfo], cc_info, library[SwiftInfo]] + (
        [library[FlutterAppleModuleHeadersInfo]] if FlutterAppleModuleHeadersInfo in library else []
    )

flutter_apple_kept_symbols = rule(
    implementation = _impl,
    attrs = dict(
        XCODE_TOOL_ATTRS,
        deps = attr.label_list(
            doc = "The plugin's library, forwarded as it is: exactly one. Named `deps` so the resource aspect follows it.",
            mandatory = True,
            providers = [CcInfo],
            # The module of an Objective-C library as Swift sees it, and its
            # public headers, for an add-to-app framework.
            aspects = [swift_clang_module_aspect, module_headers_aspect],
        ),
    ),
    fragments = XCODE_TOOL_FRAGMENTS,
    toolchains = XCODE_TOOL_TOOLCHAINS,
    doc = "Forwards its library, and links the global symbols of the archives of its package's targets as roots.",
)
