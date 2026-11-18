"""An app's version: Flutter's build name and build number, for every platform.

`flutter build --build-name <name> --build-number <number>` (or the
`version: <name>+<number>` of `pubspec.yaml`) sets one version, and each
platform's build turns it into its own fields:

    Android        versionName                  versionCode
    iOS, macOS     CFBundleShortVersionString   CFBundleVersion
    Web            version.json "version"       version.json "build_number"
    Windows        Runner.rc FileVersion "<name>+<number>",
                   FILEVERSION MAJOR,MINOR,PATCH,<number>

The app macros take the same two arguments. Unset, they are `flutter create`'s
`1.0.0+1`: build name `1.0.0`, build number `1`.

Each platform checks the value the way `flutter_tools` does (`build_info.dart`,
`validatedBuildNameForPlatform` and `validatedBuildNumberForPlatform`), with
one difference: where `flutter_tools` quietly rewrites a value it cannot use
(`1.0-beta` becomes `1.0.0` on iOS; `0` becomes `1` on Android), the build
fails here and says what the platform accepts. The one rewrite kept is Apple's
padding of a build name to three numbers (`2.1` becomes `2.1.0`), which
`flutter build` does to every valid build name.

The checks run at analysis, in the rules that use the values, so a value may
be a `select()`. Inside one, an empty string or `None` picks the default.

Every function returns a struct of the platform's values and an `error`
string, `None` when the values are good; the rule fails with the error. That
keeps the checks testable without failing a build. An error names a value as
its attribute, or as `names` gives it: a value that
`--@rules_flutter//flutter:build_number` set is named as that setting.
"""

visibility("//flutter/...")

DEFAULT_BUILD_NAME = "1.0.0"
DEFAULT_BUILD_NUMBER = "1"

# Google Play's largest versionCode.
# https://developer.android.com/studio/publish/versioning#versioningsettings
ANDROID_MAX_VERSION_CODE = 2100000000

# What rules_apple's plisttool accepts for either Apple version key: at most
# four numbers, at most 18 characters. Past these the bundle fails to build.
_APPLE_MAX_SEGMENTS = 4
_APPLE_MAX_LENGTH = 18

_APPLE_KEYS_DOC = "https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion"
_ANDROID_DOC = "https://developer.android.com/studio/publish/versioning"

def version_arg(value):
    """A macro's `build_name` or `build_number` argument as an attribute value.

    `None` and a `select()` pass through; a number becomes its decimal
    string, so `build_number = 42` reads as `flutter build --build-number 42`.

    Args:
        value: The argument.

    Returns:
        The attribute value.
    """
    if type(value) == "int":
        return str(value)
    return value

def _result(error = None, **values):
    return struct(error = error, **values)

def _is_digits(s):
    return s != "" and s.isdigit()

def _apple_value(value, arg, key):
    """`value` as an Apple version key, or why it cannot be one."""
    segments = value.split(".")
    if not all([_is_digits(s) for s in segments]):
        return None, (
            "%s = %r is not a valid %s. On iOS and macOS it is numbers " +
            "separated by periods, such as \"2.1.0\". See %s"
        ) % (arg, value, key, _APPLE_KEYS_DOC)
    if len(segments) > _APPLE_MAX_SEGMENTS or len(value) > _APPLE_MAX_LENGTH:
        return None, (
            "%s = %r is too long for %s: Apple bundles take at most %d " +
            "numbers and %d characters."
        ) % (arg, value, key, _APPLE_MAX_SEGMENTS, _APPLE_MAX_LENGTH)
    return segments, None

def _name(names, attribute):
    return names.get(attribute, attribute)

def apple_version(build_name, build_number, names = {}):
    """The Info.plist version keys of an iOS or macOS app.

    Args:
        build_name: The build name, or "" for the default.
        build_number: The build number, or "" for the default.
        names: How the error names a value, by attribute, where not as the
            attribute.

    Returns:
        struct(short_version_string, build_version, error).
    """
    name_segments, error = _apple_value(
        build_name or DEFAULT_BUILD_NAME,
        _name(names, "build_name"),
        "CFBundleShortVersionString",
    )
    if error:
        return _result(error = error)

    # flutter_tools pads the build name to three numbers.
    short_version_string = ".".join(name_segments + ["0"] * (3 - len(name_segments)))
    if len(short_version_string) > _APPLE_MAX_LENGTH:
        return _result(error = (
            "%s = %r is too long for CFBundleShortVersionString: " +
            "padded to three numbers, %r is over %d characters."
        ) % (_name(names, "build_name"), build_name, short_version_string, _APPLE_MAX_LENGTH))
    number = build_number or DEFAULT_BUILD_NUMBER
    _, error = _apple_value(number, _name(names, "build_number"), "CFBundleVersion")
    if error:
        return _result(error = error)
    return _result(
        short_version_string = short_version_string,
        build_version = number,
    )

def android_version(build_name, build_number, names = {}):
    """The manifest version attributes of an Android app.

    Args:
        build_name: The build name, or "" for the default.
        build_number: The build number, or "" for the default.
        names: How the error names a value, by attribute, where not as the
            attribute.

    Returns:
        struct(version_name, version_code, error).
    """
    number = build_number or DEFAULT_BUILD_NUMBER
    if not _is_digits(number) or number.startswith("0") or int(number) > ANDROID_MAX_VERSION_CODE:
        return _result(error = (
            "%s = %r is not a valid Android versionCode: a whole " +
            "number from 1 to %d, written without leading zeros. See %s"
        ) % (_name(names, "build_number"), number, ANDROID_MAX_VERSION_CODE, _ANDROID_DOC))
    return _result(
        version_name = build_name or DEFAULT_BUILD_NAME,
        version_code = number,
    )

def web_version(build_name, build_number):
    """The `version` and `build_number` of a web app's version.json.

    Flutter writes both as given.

    Args:
        build_name: The build name, or "" for the default.
        build_number: The build number, or "" for the default.

    Returns:
        struct(version, build_number, error).
    """
    return _result(
        version = build_name or DEFAULT_BUILD_NAME,
        build_number = build_number or DEFAULT_BUILD_NUMBER,
    )

# A VERSIONINFO number is 16 bits; the resource compiler keeps the low ones of
# a larger value.
_WINDOWS_MAX_VERSION_PART = 65535

_WINDOWS_DOC = "https://learn.microsoft.com/windows/win32/menurc/versioninfo-resource"

def _is_identifiers(s):
    """Whether `s` is semver's dot-separated identifiers, as in `beta.1`."""
    for part in s.split("."):
        if part == "" or not all([c.isalnum() or c == "-" for c in part.elems()]):
            return False
    return True

def windows_version(build_name, build_number, names = {}):
    """The version `flutter create`'s `Runner.rc` gives a Windows app.

    `flutter build windows` parses `<build_name>+<build_number>` as a semantic
    version and defines `FLUTTER_VERSION` (the whole) and
    `FLUTTER_VERSION_MAJOR`, `_MINOR`, `_PATCH` and `_BUILD` (the four numbers
    of the executable's FILEVERSION). Where it falls back to `1.0.0` for a
    version it cannot parse, or to a build of 0 for a build number that is not
    a whole number, the build fails here.

    Args:
        build_name: The build name, or "" for the default.
        build_number: The build number, or "" for the default.
        names: How the error names a value, by attribute, where not as the
            attribute.

    Returns:
        struct(version, major, minor, patch, build, error).
    """
    name = build_name or DEFAULT_BUILD_NAME
    number = build_number or DEFAULT_BUILD_NUMBER
    core, _, prerelease = name.partition("-")
    parts = core.split(".")
    if ("+" in name or len(parts) != 3 or not all([_is_digits(p) for p in parts]) or
        (prerelease != "" and not _is_identifiers(prerelease)) or name.endswith("-")):
        return _result(error = (
            "%s = %r is not a valid Windows version: it is three " +
            "numbers separated by periods, such as \"2.1.0\", with an optional " +
            "prerelease such as \"2.1.0-beta.1\"."
        ) % (_name(names, "build_name"), name))
    if not _is_digits(number):
        return _result(error = (
            "%s = %r is not a valid Windows build number: a whole " +
            "number, the last of the executable's four version numbers."
        ) % (_name(names, "build_number"), number))
    numbers = [int(p, 10) for p in parts] + [int(number, 10)]
    for arg, value, too_large in [
        ("build_name", name, any([n > _WINDOWS_MAX_VERSION_PART for n in numbers[:3]])),
        ("build_number", number, numbers[3] > _WINDOWS_MAX_VERSION_PART),
    ]:
        if too_large:
            return _result(error = (
                "%s = %r is too large for a Windows version: each of its " +
                "four numbers is at most %d. See %s"
            ) % (_name(names, arg), value, _WINDOWS_MAX_VERSION_PART, _WINDOWS_DOC))
    return _result(
        version = "%s+%s" % (name, number),
        major = numbers[0],
        minor = numbers[1],
        patch = numbers[2],
        build = numbers[3],
    )

def version_target_conflict(owner, version, build_name, build_number):
    """Why an Apple app's `version` and version arguments cannot both be set.

    Args:
        owner: The macro call, for the message, such as
            `flutter_ios_app(name = "app")`.
        version: The macro's `version` argument.
        build_name: The macro's `build_name` argument.
        build_number: The macro's `build_number` argument.

    Returns:
        The error, or None.
    """
    given = [
        arg
        for arg, value in [("build_name", build_name), ("build_number", build_number)]
        if value != None
    ]
    if version == None or not given:
        return None
    return (
        "%s sets both `version` and `%s`, two sources for the bundle's " +
        "version. Pass `build_name` and `build_number`, or give the " +
        "`apple_bundle_version` (or `flutter_apple_bundle_version`) that " +
        "`version` names the values instead."
    ) % (owner, "` and `".join(given))

# The manifest_values keys flutter_android_app sets from its own arguments.
_ANDROID_ALWAYS_SET = {
    "applicationId": "application_id",
    "minSdkVersion": "min_sdk_version",
    "targetSdkVersion": "target_sdk_version",
}
_ANDROID_VERSION_KEYS = {
    "versionCode": "build_number",
    "versionName": "build_name",
}

def manifest_values_conflict(owner, manifest_values, build_name, build_number):
    """Why an Android app's `manifest_values` cannot be used as given.

    `applicationId`, `minSdkVersion` and `targetSdkVersion` always come from
    the macro's arguments. `versionCode` and `versionName` may come from
    `manifest_values` when `build_number` and `build_name` are unset.

    Args:
        owner: The macro call, for the message.
        manifest_values: The macro's `manifest_values` argument.
        build_name: The macro's `build_name` argument.
        build_number: The macro's `build_number` argument.

    Returns:
        The error, or None.
    """
    if type(manifest_values) != "dict":
        return (
            "%s: `manifest_values` must be a dict, not a %s: the macro adds " +
            "its own keys to it. To vary the version by configuration, give " +
            "`build_name` and `build_number` a select()."
        ) % (owner, type(manifest_values))
    given = {"build_name": build_name != None, "build_number": build_number != None}
    for key in sorted(manifest_values.keys()):
        arg = _ANDROID_ALWAYS_SET.get(key)
        if arg == None:
            arg = _ANDROID_VERSION_KEYS.get(key)
            if arg == None or not given[arg]:
                continue
        return (
            "%s sets `%s` twice: in `manifest_values` and through `%s`. " +
            "Set it with `%s` alone."
        ) % (owner, key, arg, arg)
    return None
