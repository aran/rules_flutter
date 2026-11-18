"""A bundle and its program describe one version.

`flutter build --build-name 2.1.0` gives the bundle's version fields and the
program's `appBuildName` the same value. Here the program is a
`flutter_application`, compiled once, and a platform app is built over it: each
has a `build_name` and a `build_number`. A bundle that said 2.1.0 while its code
reported 1.0.0 would ship a version nobody chose, so the application states the
version and the platform app takes it. An app may state it too, and then the
application must state the same: an application that says nothing reports the
defaults, and a bundle that says otherwise disagrees with it.

Every other place a bundle's version can be written is held to the same rule:
an iOS or macOS app's `version` target, an Android app's `manifest_values`
`versionCode` and `versionName`, the version attributes of the app's own
`AndroidManifest.xml` or keys of its `Info.plist`, and the `version` and
`build_number` of a web app's own `version.json`. Each may say what the
application says, and the build fails, naming both, where it says otherwise.

`--@rules_flutter//flutter:build_name` and `--@rules_flutter//flutter:build_number`
set the version for one build, as `flutter build --build-name` and
`--build-number` do: each replaces every application's attribute. An app's
`build_name` or `build_number` argument, which may only repeat its
application's, follows the setting with it, as `flutter create`'s
`$(FLUTTER_BUILD_NUMBER)` and `flutter.versionCode` follow the flag. A value an
app writes as it is (a `versionCode` in `manifest_values`, a version file or
target that states its own numbers, a literal in a plist, manifest or
version.json) cannot follow, so it must be the version the setting gives, or
the build fails naming both.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//flutter:providers.bzl", "FlutterApplicationInputsInfo")
load("//flutter/private:app_version.bzl", "DEFAULT_BUILD_NAME", "DEFAULT_BUILD_NUMBER")

visibility("//flutter/...")

# The settings that replace an application's version for one build, as the
# user writes them on the command line, by the attribute each replaces.
VERSION_SETTINGS = {
    "build_name": "--@rules_flutter//flutter:build_name",
    "build_number": "--@rules_flutter//flutter:build_number",
}

# For a rule that compiles a program: the settings, read by `program_version`.
VERSION_SETTING_ATTRS = {
    "_build_name_setting": attr.label(
        doc = "`--@rules_flutter//flutter:build_name`, which replaces `build_name` when set.",
        default = Label("//flutter:build_name"),
        providers = [BuildSettingInfo],
    ),
    "_build_number_setting": attr.label(
        doc = "`--@rules_flutter//flutter:build_number`, which replaces `build_number` when set.",
        default = Label("//flutter:build_number"),
        providers = [BuildSettingInfo],
    ),
}

def program_version(ctx):
    """A program's version: its `build_name` and `build_number`, unless the settings replace them.

    Args:
        ctx: The context of a rule that compiles a program. Its `build_name`
            and `build_number`, and `VERSION_SETTING_ATTRS`, are read when it
            has them.

    Returns:
        struct(build_name, build_number, stated_build_name,
        stated_build_number, settings): the version the program has, each
        empty for the default; the rule's own attributes; and the
        `VERSION_SETTINGS` entries of the settings that are set, by attribute.
    """
    values = {}
    settings = {}
    for attribute in ["build_name", "build_number"]:
        stated = getattr(ctx.attr, attribute, "")
        setting = getattr(ctx.attr, "_%s_setting" % attribute, None)
        value = setting[BuildSettingInfo].value if setting else ""
        if value:
            settings[attribute] = VERSION_SETTINGS[attribute]
        values[attribute] = value or stated
        values["stated_" + attribute] = stated
    return struct(settings = settings, **values)

def version_names(settings):
    """How a version error names each value: the setting that gave it, else the attribute.

    Args:
        settings: The `settings` of `program_version`, or of `application_version`.

    Returns:
        A dict for the `names` of `app_version.bzl`'s checks.
    """
    return {attribute: "`%s`" % setting for attribute, setting in settings.items()}

# For a rule that takes the version from the application it is built over.
APPLICATION_VERSION_ATTR = {
    "application": attr.label(
        doc = "The `flutter_application` the app is built over, whose " +
              "`build_name` and `build_number` the app takes when it sets none " +
              "of its own.",
        providers = [FlutterApplicationInputsInfo],
    ),
}

def shown_label(label):
    """`label`, a `Label` or its string, as a BUILD file in the main repository writes it."""
    text = str(label)
    return text[2:] if text.startswith("@@//") else text

_DEFAULTS = {"build_name": DEFAULT_BUILD_NAME, "build_number": DEFAULT_BUILD_NUMBER}

def application_version(label, application, build_name, build_number, stated_as = {}):
    """The version an app has: its own, else its application's.

    The app's `build_name` and `build_number` may only repeat the
    application's attributes, so where a setting replaces those, it replaces
    the app's too. A value in `stated_as` is one the app writes as it is, which
    no setting changes: it must be the application's version as the build
    gives it, the settings' included.

    Args:
        label: The rule's label, for the message.
        application: The `application` target, or None for an app with none.
        build_name: The rule's `build_name`; empty is unset.
        build_number: The rule's `build_number`; empty is unset.
        stated_as: How the app writes a value it states as it is, rather than
            as the attribute of the same name, by attribute: for example
            `{"build_number": "`versionCode` in `manifest_values`"}`.

    Returns:
        struct(build_name, build_number, settings): each value empty when
        neither the app nor its application sets it, and the `VERSION_SETTINGS`
        entries of the settings that gave one. Fails when the app sets one that
        is not the application's.
    """
    if application == None:
        return struct(build_name = build_name, build_number = build_number, settings = {})
    program = application[FlutterApplicationInputsInfo].inputs
    values = {}
    for attribute, mine in [("build_name", build_name), ("build_number", build_number)]:
        theirs = getattr(program, "stated_" + attribute)
        setting = program.version_settings.get(attribute)
        if mine and setting and attribute in stated_as:
            if mine != getattr(program, attribute):
                fail((
                    "%s: %s = %r, and `%s=%s` gives the application %s that version " +
                    "for this build. The bundle's version and what the program reports " +
                    "as its own would disagree, and %s is written as it is, so it cannot " +
                    "follow the setting. Remove it, and leave the version to the application."
                ) % (
                    label,
                    stated_as[attribute],
                    mine,
                    setting,
                    getattr(program, attribute),
                    application.label,
                    stated_as[attribute],
                ))
        elif mine and mine != (theirs or _DEFAULTS[attribute]):
            fail((
                "%s: %s = %r, and the application %s it is built over has %s = %r%s. " +
                "The bundle's version and what the program reports as its own " +
                "would disagree. Set it on the application alone, or give both the same value."
            ) % (
                label,
                stated_as.get(attribute, attribute),
                mine,
                application.label,
                attribute,
                theirs or _DEFAULTS[attribute],
                "" if theirs else ", the default",
            ))
        values[attribute] = getattr(program, attribute) if setting else (mine or theirs)
    return struct(settings = program.version_settings, **values)
