"""A Dart package rule that reaches its code asset through an attribute of its own name.

Some rule sets put a package's dependencies behind an attribute of their own
name: an alias-like rule over `exports`, say. Its `DartInfo` still carries the
package's code asset, and the application's walk follows `exports` like any
other attribute to the target that declared it.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")

def _forwarding_package_impl(ctx):
    return [ctx.attr.exports[0][DartInfo]]

forwarding_package = rule(
    implementation = _forwarding_package_impl,
    attrs = {"exports": attr.label_list(providers = [DartInfo])},
)
