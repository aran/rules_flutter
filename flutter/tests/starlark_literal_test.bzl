"""Unit tests for the spoke BUILD escaping helper (`starlark_literal.bzl`).

The spoke generators paste pubspec-declared and file-system-walked names
into generated BUILD files. Each test below pins that the helper's output
is a literal the Starlark parser reads back to the exact input: the
expected value is written as a literal in this file, so equality means the
emitted text parses back to the input. Final tests pin that a quote name
(the odd class Bazel itself accepts) renders escaped (not spliced raw) in
generated `flutter_library` and `flutter_plugin` spokes, and that every
refused class fails the fetch with the package, entry and file in the
message.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "check_spoke_file_names",
    "make_flutter_library_build_content",
    "make_flutter_plugin_build_content",
)
load(
    "//flutter/private:starlark_literal.bzl",
    "check_spoke_file_name",
    "decode_starlark_escapes",
    "spoke_file_name_error",
    "spoke_file_name_problem",
    "starlark_string_literal",
)

def _literal_round_trip_test_impl(ctx):
    """Quotes, backslashes, newlines, `$` and non-ASCII survive the helper."""
    env = unittest.begin(ctx)

    cases = [
        ("plain.txt", '"plain.txt"'),
        (":assets/note.txt", '":assets/note.txt"'),
        ('say"hi.txt', '"say\\"hi.txt"'),
        ("back\\slash.txt", '"back\\\\slash.txt"'),
        ('both"and\\here.txt', '"both\\"and\\\\here.txt"'),
        ("line\nbreak.txt", '"line\\nbreak.txt"'),
        ("$HOME/x.txt", '"$HOME/x.txt"'),
        ("café.txt", '"café.txt"'),
    ]
    for inp, want in cases:
        asserts.equals(env, want, starlark_string_literal(inp), inp)

    return unittest.end(env)

literal_round_trip_test = unittest.make(_literal_round_trip_test_impl)

def _odd_name_error_names_all_three_test_impl(ctx):
    """Each refused class names the package, the declaring entry, the file."""
    env = unittest.begin(ctx)

    for entry, bad in [
        ("assets/", "assets/a:b.txt"),
        ("assets/", "assets/back\\slash.txt"),
        ("assets/", "assets/both\"and\\mix.txt"),
        ("assets/", "assets/has\nnewline.txt"),
        ("assets/", "assets/has\rcarriage.txt"),
        ("assets/", "assets/has\ttab.txt"),
        ("assets/", "/leading/slash.txt"),
        ("assets/", "assets//double/slash.txt"),
        ("assets/", "assets/./dot/seg.txt"),
        ("assets/", "assets/../up/seg.txt"),
        ("assets/", "trailing/slash/"),
        ("assets/", ""),
    ]:
        err = spoke_file_name_error("mypkg", entry, bad)
        asserts.true(env, "mypkg" in err, err)
        asserts.true(env, entry in err, err)
        asserts.true(env, starlark_string_literal(bad) in err, err)

    return unittest.end(env)

odd_name_error_names_all_three_test = unittest.make(
    _odd_name_error_names_all_three_test_impl,
)

def _refused_classes_fail_closed_test_impl(ctx):
    """The check refuses each Bazel-rejected class and passes the rest."""
    env = unittest.begin(ctx)

    for bad in [
        "assets/a:b.txt",
        "assets/back\\slash.txt",
        "assets/both\"and\\mix.txt",
        "assets/has\nnewline.txt",
        "assets/has\rcarriage.txt",
        "assets/has\ttab.txt",
        "/leading/slash.txt",
        "assets//double/slash.txt",
        "assets/./dot/seg.txt",
        "assets/../up/seg.txt",
        "trailing/slash/",
        "",
    ]:
        asserts.true(env, spoke_file_name_problem(bad) != "", bad)
    for good in ['assets/say"hi.txt', "assets/note.txt", "."]:
        asserts.equals(env, "", spoke_file_name_problem(good), good)

    return unittest.end(env)

refused_classes_fail_closed_test = unittest.make(
    _refused_classes_fail_closed_test_impl,
)

def _dir_declaration_passes_test_impl(ctx):
    """A trailing-slash declaration covers files; it is never emitted."""
    env = unittest.begin(ctx)

    block = struct(
        assets = [struct(path = "assets/odd/")],
        fonts = [],
        shaders = [],
    )
    expanded = [struct(path = "assets/odd/note.txt")]
    asserts.equals(env, None, check_spoke_file_names("p", block, expanded))

    return unittest.end(env)

dir_declaration_passes_test = unittest.make(
    _dir_declaration_passes_test_impl,
)

def _ordinary_name_passes_test_impl(ctx):
    """Bazel-accepted names (including quotes) pass the fetch-time check."""
    env = unittest.begin(ctx)

    for good in [
        "assets/note.txt",
        'assets/say"hi.txt',
        ".",
        "assets/100%.txt",
        "assets/star*name.txt",
        "assets/space name.txt",
        "assets/$HOME.txt",
        "assets/café.txt",
    ]:
        asserts.equals(env, None, check_spoke_file_name("p", "assets/", good), good)

    return unittest.end(env)

ordinary_name_passes_test = unittest.make(_ordinary_name_passes_test_impl)

def _odd_names_render_escaped_test_impl(ctx):
    """A quote name renders escaped in generated spokes, never spliced raw.

    Quotes are the odd class Bazel accepts in target names, so the fetch
    lets them through and the renderer must carry them safely. Every other
    odd class (backslash included) fails the fetch instead; those paths
    are pinned by the refusal tests above.
    """
    env = unittest.begin(ctx)

    odd = ['say"hi.txt']
    assets = {}
    for name in odd:
        assets[":" + name] = name

    library = make_flutter_library_build_content(
        name = "odd_assets",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        fonts_json_str = "",
        font_files = {},
        pkg_assets = dict(assets),
        pkg_shaders = {},
        version = "0.1.0",
    )
    plugin = make_flutter_plugin_build_content(
        name = "odd_plugin",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        plugin_platforms_json = '{"web":{"pluginClass":"WebPlugin"}}',
        apple_macos_srcs_dirs = [],
        apple_ios_srcs_dirs = [],
        apple_macos_include_dirs = [],
        apple_ios_include_dirs = [],
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
        pkg_assets = dict(assets),
        version = "0.1.0",
    )

    for name in odd:
        want = starlark_string_literal(":" + name) + ": " + starlark_string_literal(name) + ","
        asserts.true(env, want in library, want)
        asserts.true(env, want in plugin, want)
        asserts.false(env, '":' + name + '"' in library, name)
        asserts.false(env, '":' + name + '"' in plugin, name)

    return unittest.end(env)

odd_names_render_escaped_test = unittest.make(
    _odd_names_render_escaped_test_impl,
)

def _decode_simple_escapes_test_impl(ctx):
    """Every one-letter Starlark escape decodes to the character it names."""
    env = unittest.begin(ctx)

    cases = [
        ("plain", "plain"),
        ("a\\nb", "a\nb"),
        ("a\\tb", "a\tb"),
        ("a\\rb", "a\rb"),
        ("a\\\\b", "a\\b"),
        ("a\\\"b", "a\"b"),
        ("a\\'b", "a'b"),
    ]
    for source, want in cases:
        decoded = decode_starlark_escapes(source)
        asserts.equals(env, "", decoded.error, source)
        asserts.equals(env, want, decoded.text, source)

    return unittest.end(env)

decode_simple_escapes_test = unittest.make(_decode_simple_escapes_test_impl)

def _decode_code_point_escapes_test_impl(ctx):
    """`\\xHH` and octal escapes decode through the printable-ASCII lookup."""
    env = unittest.begin(ctx)

    cases = [
        ("\\x41", "A"),
        ("\\x4A", "J"),
        ("\\x0a", "\n"),
        ("\\x09", "\t"),
        ("\\x22", "\""),
        ("\\x5c", "\\"),
        ("\\101", "A"),
        ("\\141", "a"),
        ("\\12", "\n"),
        ("\\40", " "),
    ]
    for source, want in cases:
        decoded = decode_starlark_escapes(source)
        asserts.equals(env, "", decoded.error, source)
        asserts.equals(env, want, decoded.text, source)

    return unittest.end(env)

decode_code_point_escapes_test = unittest.make(
    _decode_code_point_escapes_test_impl,
)

def _decode_rejects_undecodable_test_impl(ctx):
    """Unknown escapes, a trailing backslash and odd code points fail closed."""
    env = unittest.begin(ctx)

    for bad in [
        "a\\qb",
        "a\\",
        "\\x00",
        "\\x7f",
        "\\777",
        "\\x4",
        "\\xg1",
    ]:
        decoded = decode_starlark_escapes(bad)
        asserts.true(env, decoded.error != "", bad)

    return unittest.end(env)

decode_rejects_undecodable_test = unittest.make(
    _decode_rejects_undecodable_test_impl,
)

def starlark_literal_test_suite(name):
    unittest.suite(
        name,
        literal_round_trip_test,
        odd_name_error_names_all_three_test,
        refused_classes_fail_closed_test,
        dir_declaration_passes_test,
        ordinary_name_passes_test,
        odd_names_render_escaped_test,
        decode_simple_escapes_test,
        decode_code_point_escapes_test,
        decode_rejects_undecodable_test,
    )
