"""A plugin's dependency on a product of a Swift package the root module declares.

A plugin's Apple repository names the product by the repository the root's
rules_swift_package_manager declares for the package (`swift_packages.bzl`),
which the pub extension sees only when the root module injects it:

    inject_repo(flutter_pub, "swiftpkg_firebase_ios_sdk")

`flutter_swift_package_product` is the plugin library's dependency on it: an
alias of the product when the root injected the repository, and otherwise a
target that fails the build of whatever links the plugin, naming the line to
add. Bazel's own failure for a repository nobody injected names neither the
plugin nor `inject_repo`.
"""

visibility("//flutter/...")

def _flutter_missing_swift_package_impl(ctx):
    fail(ctx.attr.message)

flutter_missing_swift_package = rule(
    implementation = _flutter_missing_swift_package_impl,
    attrs = {"message": attr.string(mandatory = True)},
    doc = "Fails the build of anything that depends on it with `message`.",
)

def is_visible_label(label):
    """Whether `label`'s repository is visible from the package that converted it.

    `native.package_relative_label` gives a repository no mapping names an
    unknown-repository marker in place of a name, and fails on reading its
    `repo_name`, so its text is all there is to read.

    That text is Bazel's rendering of such a label, which no API promises:
    `@@[unknown repo '<name>' requested from @@<repo>]//<package>:<name>`.
    `swift_packages_test`'s `label_rendering` test pins it, so a Bazel that
    renders it otherwise fails that test rather than turning the `inject_repo`
    message back into Bazel's own.
    """
    return not str(label).startswith("@@[unknown repo ")

def missing_swift_package_message(package, version, product, repo):
    """What the build fails with when the root did not inject `repo`."""
    return (
        "package:{pkg} {version} depends on the Swift package product `{product}` of " +
        "`@{repo}`, and the root module does not hand that repository to rules_flutter. The " +
        "root's rules_swift_package_manager declares the Swift packages plugins depend " +
        "on; add the repository to the pub extension in your root MODULE.bazel:\n" +
        "    inject_repo(flutter_pub, \"{repo}\")\n" +
        "naming your `use_extension` of rules_flutter's pub extension in place of " +
        "`flutter_pub`. `bazel run @<hub>//swift:packages` prints every line the " +
        "plugins need."
    ).format(
        pkg = package,
        version = version,
        product = product,
        repo = repo,
    )

def flutter_swift_package_product(name, product, package, version, **kwargs):
    """The product `product` (a label string), or a target that fails saying how to inject it.

    Args:
        name: The target's name.
        product: The product's label, `@swiftpkg_<identity>//:<Product>`.
        package: The plugin's pub package name, for the message.
        version: Its version, for the message.
        **kwargs: Common attributes of the target.
    """
    label = native.package_relative_label(product)
    if is_visible_label(label):
        native.alias(name = name, actual = label, **kwargs)
        return
    repo, target = product[1:].split("//:", 1)
    flutter_missing_swift_package(
        name = name,
        message = missing_swift_package_message(package, version, target, repo),
        **kwargs
    )
