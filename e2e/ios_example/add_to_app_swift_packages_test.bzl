"""Add-to-app makes each module of a Swift package a plugin depends on a framework of its own.

firebase_core's Package.swift is two targets, its Swift and its Objective-C,
and depends on firebase-ios-sdk, whose modules depend on GoogleUtilities' and
Promises'. `flutter build ios-framework` builds each pod a plugin depends on
as a framework beside the plugin's. Here each module is one, so the plugin's
framework holds only its own code and links the others.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_LINK_MNEMONICS = ["CppLink", "ObjcLink"]

def _xcframeworks_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    names = sorted([
        f.basename[:-len(".xcframework")]
        for f in target[DefaultInfo].files.to_list()
    ])
    asserts.equals(env, sorted(ctx.attr.xcframeworks), names)

    # Each static library is linked into one framework of a slice, so no two
    # frameworks carry a copy of the same code.
    linked_into = {}
    links = 0
    for action in target.actions:
        if action.mnemonic not in _LINK_MNEMONICS:
            continue
        links += 1
        framework = action.outputs.to_list()[0]
        for f in action.inputs.to_list():
            if f.extension in ("a", "lo"):
                linked_into.setdefault(f.path, []).append(framework.path)
    asserts.equals(env, 2 * len(ctx.attr.xcframeworks), links, "one link per framework and slice")
    for library, frameworks in sorted(linked_into.items()):
        asserts.equals(env, 1, len(frameworks), "%s is linked into %s" % (library, frameworks))
    return analysistest.end(env)

add_to_app_swift_packages_test = analysistest.make(
    _xcframeworks_test_impl,
    attrs = {
        "xcframeworks": attr.string_list(
            doc = "The names of the xcframeworks the target under test makes, without the extension.",
            mandatory = True,
        ),
    },
)
