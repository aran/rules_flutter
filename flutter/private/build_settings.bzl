"""Build settings (command-line flags) exposed by rules_flutter."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":validation.bzl", "validate_dart_defines")

def _dart_defines_flag_impl(ctx):
    validate_dart_defines(ctx.build_setting_value, "--%s" % ctx.label)
    return BuildSettingInfo(value = ctx.build_setting_value)

dart_defines_flag = rule(
    implementation = _dart_defines_flag_impl,
    # repeatable: each --flag=KEY=VALUE occurrence appends one whole list
    # element, so values may contain commas (skylib's string_list_flag would
    # split them).
    build_setting = config.string_list(flag = True, repeatable = True),
    doc = "A repeatable list of Dart environment defines (KEY=VALUE). " +
          "Each flag occurrence contributes one define, appended after any " +
          "target-level `defines`, so the command line wins on key collisions.",
)
