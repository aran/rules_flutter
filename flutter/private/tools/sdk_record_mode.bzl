"""A `flutter_sdk_record` built for each build mode, for the test that holds the stock artifacts to the check."""

load("//flutter:providers.bzl", "FlutterSdkRecordInfo")

visibility("//flutter/...")

def _mode_impl(settings, attr):
    return {
        "//command_line_option:compilation_mode": "dbg" if attr.mode == "debug" else "opt",
        str(Label("//flutter:profile")): attr.mode == "profile",
        "//command_line_option:platforms": [attr.platform] if attr.platform else settings["//command_line_option:platforms"],
    }

_mode_transition = transition(
    implementation = _mode_impl,
    inputs = ["//command_line_option:platforms"],
    outputs = [
        "//command_line_option:compilation_mode",
        str(Label("//flutter:profile")),
        "//command_line_option:platforms",
    ],
)

def _record_in_mode_impl(ctx):
    return [DefaultInfo(files = ctx.attr.record[0][DefaultInfo].files)]

record_in_mode = rule(
    implementation = _record_in_mode_impl,
    attrs = {
        "mode": attr.string(mandatory = True, values = ["debug", "profile", "release"]),
        "platform": attr.string(doc = "The target platform to build the record for, as a label; the command line's when empty."),
        "record": attr.label(cfg = _mode_transition, providers = [FlutterSdkRecordInfo]),
    },
    doc = "The record of an SDK, built for one build mode (`-c dbg`, `-c opt` with the profile flag, `-c opt`) and, with `platform`, one target platform.",
)
