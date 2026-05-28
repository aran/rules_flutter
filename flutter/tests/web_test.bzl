"""Unit tests for web application helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:validation.bzl", "escape_html", "is_valid_web_compiler_renderer")

def _html_title_escaping_test_impl(ctx):
    """Test that HTML special characters in titles are properly escaped."""
    env = unittest.begin(ctx)

    test_cases = [
        ("My App", "My App"),
        ("App & Co", "App &amp; Co"),
        ("<script>", "&lt;script&gt;"),
        ('He said "hi"', "He said &quot;hi&quot;"),
        ("Normal Title", "Normal Title"),
    ]

    for title, expected in test_cases:
        asserts.equals(env, expected, escape_html(title), "Escaping '%s'" % title)

    return unittest.end(env)

def _web_compiler_renderer_validation_test_impl(ctx):
    """Test that invalid compiler+renderer combos are rejected."""
    env = unittest.begin(ctx)

    # Valid combinations.
    asserts.true(env, is_valid_web_compiler_renderer("dart2wasm", "skwasm"), "dart2wasm+skwasm should be valid")
    asserts.true(env, is_valid_web_compiler_renderer("dart2wasm", "canvaskit"), "dart2wasm+canvaskit should be valid")
    asserts.true(env, is_valid_web_compiler_renderer("dart2js", "canvaskit"), "dart2js+canvaskit should be valid")

    # Invalid: dart2js cannot use skwasm (skwasm requires wasm).
    asserts.false(env, is_valid_web_compiler_renderer("dart2js", "skwasm"), "dart2js+skwasm should be invalid")

    return unittest.end(env)

_t0_test = unittest.make(_html_title_escaping_test_impl)
_t1_test = unittest.make(_web_compiler_renderer_validation_test_impl)

def web_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test)
