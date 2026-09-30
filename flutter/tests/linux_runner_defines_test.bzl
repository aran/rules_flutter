"""Unit tests for the defines the built-in Linux runner compiles with.

The window title reaches the runner as a C string literal on the command line,
so a title with a quote or backslash must be escaped, not spliced in raw.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_linux_application.bzl", "linux_runner_defines")

def _plain_title_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        [
            "GTK_APP_ID=\"com.example.notes\"",
            "WINDOW_TITLE=\"Rainstorm Notes\"",
        ],
        linux_runner_defines("com.example.notes", "Rainstorm Notes"),
    )
    return unittest.end(env)

def _escapes_quotes_and_backslashes_test_impl(ctx):
    env = unittest.begin(ctx)
    defines = linux_runner_defines("com.example.x", "Say \"hi\" \\ bye\nnow")
    asserts.equals(env, "WINDOW_TITLE=\"Say \\\"hi\\\" \\\\ bye\\nnow\"", defines[1])
    return unittest.end(env)

_plain_title_test = unittest.make(_plain_title_test_impl)
_escapes_quotes_and_backslashes_test = unittest.make(_escapes_quotes_and_backslashes_test_impl)

def linux_runner_defines_test_suite(name):
    unittest.suite(
        name,
        _plain_title_test,
        _escapes_quotes_and_backslashes_test,
    )
