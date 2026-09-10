"""Unit tests for the Flutter SDK spoke's generated BUILD content.

The fidelity claim under test: pub writes a `languageVersion` for every
Flutter SDK package, derived from that package's own `environment.sdk`.
Measured against a real `flutter pub get` (Flutter 3.41.6, whose
`packages/flutter/pubspec.yaml` declares `^3.9.0-0`): pub wrote
`"languageVersion": "3.9"` for `flutter`, `flutter_test`, `sky_engine`,
`flutter_localizations` and `flutter_web_plugins` alike. A spoke that
emits no language version hands those packages the *current* SDK's
language version instead — silently more permissive than pub.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "derive_language_version")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint")
load("//flutter/private:flutter_sdk_package.bzl", "make_flutter_sdk_build_content")

# Verbatim `packages/flutter/pubspec.yaml` from the pinned Flutter 3.47.2.
# Kept whole rather than trimmed to a minimal case: the shapes that break a
# line-based parser are all here — comments *inside* the dependency block, a
# nested `sky_engine: {sdk: flutter}` entry, and a `dev_dependencies:` section
# whose members must not be mistaken for runtime deps.
_FLUTTER_PUBSPEC = """\
name: flutter
description: A framework for writing Flutter applications
homepage: https://flutter.dev

environment:
  sdk: ^3.11.0-0

resolution: workspace

dependencies:
  # To update these, use "flutter update-packages --force-upgrade".
  #
  # For detailed instructions, refer to:
  # https://github.com/flutter/flutter/blob/main/docs/infra/Updating-dependencies-in-Flutter.md
  characters: ^1.4.1
  collection: ^1.19.1
  # This is not unpinned currently.
  # See https://github.com/flutter/flutter/issues/185017
  material_color_utilities: 0.13.0
  meta: ^1.18.3
  vector_math: ^2.4.0
  sky_engine:
    sdk: flutter

dev_dependencies:
  flutter_driver:
    sdk: flutter
  flutter_test:
    sdk: flutter
  fake_async: any
  web: any

# PUBSPEC CHECKSUM: i71l78
"""

def _derives_the_language_version_from_the_sdk_constraint_test_impl(ctx):
    """`^3.11.0-0` yields `3.11` — the prerelease suffix is not a language version.

    Every Flutter SDK package pins a `-0` prerelease floor so that a beta of
    the same triple satisfies it. Pub drops the suffix before formatting;
    ground-truthed above against a real lockfile-and-`pub get` pair.
    """
    env = unittest.begin(ctx)

    constraint = parse_pubspec_sdk_constraint(_FLUTTER_PUBSPEC)
    asserts.equals(env, "^3.11.0-0", constraint)
    asserts.equals(env, "3.11", derive_language_version(constraint))

    return unittest.end(env)

def _reads_runtime_deps_without_dev_deps_test_impl(ctx):
    """The shared parser sees exactly the runtime deps, comments and nesting notwithstanding.

    `sky_engine` (a nested `sdk:` entry) counts; `flutter_driver` and `web`
    (dev-only) do not.
    """
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        ["characters", "collection", "material_color_utilities", "meta", "sky_engine", "vector_math"],
        sorted(parse_pubspec_deps(_FLUTTER_PUBSPEC)),
    )

    return unittest.end(env)

def _flutter_spoke_declares_its_language_version_test_impl(ctx):
    """`package:flutter` builds a flutter_library carrying the derived version."""
    env = unittest.begin(ctx)

    content = make_flutter_sdk_build_content(
        name = "flutter",
        deps = ["@hub__meta//:meta"],
        language_version = "3.11",
    )

    asserts.true(env, "flutter_library(" in content, content)
    asserts.true(env, 'language_version = "3.11",' in content, content)

    # The shader channel is what makes this spoke a flutter_library rather
    # than a dart_library; adding a language version must not disturb it.
    asserts.true(env, 'shaders = glob(["lib/src/material/shaders/*.frag"])' in content, content)
    asserts.true(env, '"@hub__meta//:meta",' in content, content)

    return unittest.end(env)

def _non_flutter_spoke_declares_its_language_version_test_impl(ctx):
    """`package:flutter_test` and friends are plain dart_library spokes."""
    env = unittest.begin(ctx)

    content = make_flutter_sdk_build_content(
        name = "flutter_test",
        deps = [],
        language_version = "3.11",
    )

    asserts.true(env, "dart_library(" in content, content)
    asserts.true(env, "flutter_library(" not in content, content)
    asserts.true(env, 'language_version = "3.11",' in content, content)

    # No deps means no `deps` attribute at all, not an empty list.
    asserts.true(env, "deps = [" not in content, content)

    return unittest.end(env)

def _pubspec_without_environment_yields_no_language_version_test_impl(ctx):
    """A pubspec with no `environment.sdk` must not invent a version.

    `derive_language_version` answers `"2.7"` for a *missing* constraint —
    pub's own default. That answer is only correct when a pubspec was read
    and found to have no constraint. When there is no pubspec at all the
    spoke passes `""`, and the emitted empty string is what makes
    `dart_library` omit the `languageVersion` key downstream.
    """
    env = unittest.begin(ctx)

    asserts.equals(env, "", parse_pubspec_sdk_constraint("name: flutter\n"))

    content = make_flutter_sdk_build_content(
        name = "flutter_test",
        deps = [],
        language_version = "",
    )
    asserts.true(env, 'language_version = "",' in content, content)

    return unittest.end(env)

_derives_the_language_version_from_the_sdk_constraint_test = unittest.make(
    _derives_the_language_version_from_the_sdk_constraint_test_impl,
)
_reads_runtime_deps_without_dev_deps_test = unittest.make(
    _reads_runtime_deps_without_dev_deps_test_impl,
)
_flutter_spoke_declares_its_language_version_test = unittest.make(
    _flutter_spoke_declares_its_language_version_test_impl,
)
_non_flutter_spoke_declares_its_language_version_test = unittest.make(
    _non_flutter_spoke_declares_its_language_version_test_impl,
)
_pubspec_without_environment_yields_no_language_version_test = unittest.make(
    _pubspec_without_environment_yields_no_language_version_test_impl,
)

def flutter_sdk_package_test_suite(name):
    unittest.suite(
        name,
        _derives_the_language_version_from_the_sdk_constraint_test,
        _reads_runtime_deps_without_dev_deps_test,
        _flutter_spoke_declares_its_language_version_test,
        _non_flutter_spoke_declares_its_language_version_test,
        _pubspec_without_environment_yields_no_language_version_test,
    )
