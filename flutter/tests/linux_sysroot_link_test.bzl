"""Unit tests for the Linux runner's GTK3 link inputs.

Regression coverage for the two-sysroot link failure: the Chromium sysroot's
`usr/lib/<triple>/` holds GNU ld scripts for the C runtime (`libm.so`,
`libc.so`, `libtermcap.so`) whose absolute `GROUP(/lib/...)` paths lld rewrites
only for scripts found under `--sysroot`. Putting that directory on the `-l`
search path lets it answer the cc toolchain's own `-lm`, and the link dies with
`cannot open /lib/x86_64-linux-gnu/libm.so.6` for a file that exists.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_linux_application.bzl", "gtk3_sysroot_link_inputs")

_LIB_DIR = "external/sysroot/usr/lib/x86_64-linux-gnu"

def _fake_file(dirname, basename):
    return struct(dirname = dirname, basename = basename, path = dirname + "/" + basename)

def _sysroot_files():
    """A stand-in for the sysroot filegroup: GTK3 plus the C runtime ld scripts."""
    names = [
        "libgtk-3.so",
        "libgdk-3.so",
        "libpangocairo-1.0.so",
        "libpango-1.0.so",
        "libharfbuzz.so",
        "libatk-1.0.so",
        "libcairo-gobject.so",
        "libcairo.so",
        "libgdk_pixbuf-2.0.so",
        "libgio-2.0.so",
        "libgobject-2.0.so",
        "libglib-2.0.so",
        # The landmines.
        "libc.so",
        "libm.so",
        "libtermcap.so",
        # Versioned sonames, present in the same directory.
        "libgtk-3.so.0",
        "libm.so.6",
    ]
    return [_fake_file(_LIB_DIR, n) for n in names] + [
        _fake_file("external/sysroot/usr/include/gtk-3.0/gtk", "gtk.h"),
    ]

def _selects_only_gtk3_libraries_test_impl(ctx):
    env = unittest.begin(ctx)
    result = gtk3_sysroot_link_inputs(_sysroot_files(), _LIB_DIR)
    selected = [f.basename for f in result.libs]
    asserts.equals(env, 12, len(selected))
    for landmine in ["libc.so", "libm.so", "libtermcap.so", "libm.so.6"]:
        asserts.false(
            env,
            landmine in selected,
            "the C runtime entry {} must never be linked by rules_flutter".format(landmine),
        )
    asserts.true(env, "libgtk-3.so" in selected)
    return unittest.end(env)

def _never_adds_a_library_search_path_test_impl(ctx):
    env = unittest.begin(ctx)
    result = gtk3_sysroot_link_inputs(_sysroot_files(), _LIB_DIR)
    for flag in result.link_flags:
        asserts.false(
            env,
            flag.startswith("-L") or flag.startswith("-Wl,-L"),
            "the sysroot must never join the -l search path, got: " + flag,
        )
        asserts.false(
            env,
            flag.startswith("-l"),
            "GTK3 is linked as files, not with -l, got: " + flag,
        )
    asserts.equals(
        env,
        ["-Wl,-rpath-link," + _LIB_DIR, "-Wl,--allow-shlib-undefined"],
        result.link_flags,
    )
    return unittest.end(env)

def _ignores_matching_names_outside_the_lib_dir_test_impl(ctx):
    env = unittest.begin(ctx)
    files = _sysroot_files() + [_fake_file("external/sysroot/usr/lib", "libgtk-3.so")]
    result = gtk3_sysroot_link_inputs(files, _LIB_DIR)
    for f in result.libs:
        asserts.equals(env, _LIB_DIR, f.dirname)
    return unittest.end(env)

_selects_only_gtk3_libraries_test = unittest.make(_selects_only_gtk3_libraries_test_impl)
_never_adds_a_library_search_path_test = unittest.make(_never_adds_a_library_search_path_test_impl)
_ignores_matching_names_outside_the_lib_dir_test = unittest.make(_ignores_matching_names_outside_the_lib_dir_test_impl)

def linux_sysroot_link_test_suite(name):
    unittest.suite(
        name,
        _selects_only_gtk3_libraries_test,
        _never_adds_a_library_search_path_test,
        _ignores_matching_names_outside_the_lib_dir_test,
    )
