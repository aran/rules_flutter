"""Builds an app as `bazel mobile-install` does, for a `build_test`.

`bazel mobile-install` applies rules_android's aspect to the app and builds
the split APKs and launcher it hands to its deployer. A `build_test` of a
`mobile_install_build` builds the same files without a device, as
rules_android's own CI checks its sample apps: what fails there, at analysis
or in an action, fails `bazel mobile-install` before it installs anything.

It is incompatible with Windows: the aspect strips class files from jars with
the host's `zip`, which a Windows host does not have, so `bazel mobile-install`
fails there whatever the app.
"""

load("@rules_android//mobile_install:mi.bzl", "MIASPECT")

def _impl(ctx):
    groups = ctx.attr.app[OutputGroupInfo]
    return [DefaultInfo(files = depset(transitive = [
        groups.mobile_install_INTERNAL_,
        groups.mobile_install_launcher_INTERNAL_,
    ]))]

_mobile_install_build = rule(
    implementation = _impl,
    doc = "Forwards what `bazel mobile-install` builds of `app`: its split APKs and launcher.",
    attrs = {
        "app": attr.label(
            aspects = [MIASPECT],
            mandatory = True,
            doc = "The app, such as a `flutter_android_app`.",
        ),
    },
)

def mobile_install_build(name, **kwargs):
    """Forwards what `bazel mobile-install` builds of `app`, off Windows.

    Args:
        name: Target name.
        **kwargs: `app` and common attributes.
    """
    _mobile_install_build(
        name = name,
        target_compatible_with = select({
            Label("@platforms//os:windows"): [Label("@platforms//:incompatible")],
            "//conditions:default": [],
        }),
        **kwargs
    )
