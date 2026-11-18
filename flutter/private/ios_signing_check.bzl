"""Fails the build of an iOS device app that has no provisioning profile."""

load("@apple_support//lib:apple_support.bzl", "apple_support")

visibility("//flutter/...")

def _impl(ctx):
    if apple_support.target_environment_from_rule_ctx(ctx) == "device" and not ctx.attr.provisioning_profile:
        fail((
            "%s is built for an iOS device (--ios_multi_cpus=arm64) and has no " +
            "provisioning_profile.\n\n" +
            "rules_apple needs the profile for every device build, even one that is " +
            "not signed here (--features=disable_legacy_signing, to sign later from " +
            "the combined_dossier_zip output group): the profile supplies the " +
            "bundle's embedded.mobileprovision and the identifiers its entitlements " +
            "are signed with. Xcode's " +
            "`flutter build ios --no-codesign` instead leaves the profile out, " +
            "which rules_apple's sign-later model does not support.\n\n" +
            "Pass provisioning_profile = a local_provisioning_profile target. See " +
            "the README, \"Running on an iOS device\"."
        ) % ctx.attr.app_label)
    return [DefaultInfo()]

flutter_ios_signing_check = rule(
    implementation = _impl,
    attrs = dict(
        apple_support.platform_constraint_attrs(),
        app_label = attr.string(
            doc = "The label of the app, for the message.",
            mandatory = True,
        ),
        provisioning_profile = attr.label(
            doc = "The app's provisioning profile, `None` where it names " +
                  "none. A `select()` is read in the app's configuration.",
            allow_single_file = True,
        ),
    ),
    fragments = ["apple"],
    doc = """Fails analysis when the app is built for an iOS device without a provisioning profile.

Put it in the `deps` of the `ios_application`, whose transition decides whether
this is a device build; the macro that declares the app cannot know.""",
)
