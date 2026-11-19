"""Integration tests: `package:integration_test` suites run in an app on a device, reported per test.

An integration test is run as the application with its test as the program
(`flutter_application_variant`, whose `main` is the generated
`flutter_integration_bootstrap`), and the host drives the suite it runs over the
app's VM service, as `flutter test integration_test/x_test.dart -d <device>`
does, or, for a web app, which has none, over the browser's DevTools protocol. Each `testWidgets` is a test case: `--test_filter`, `shard_count` and the
JUnit report see each one.

Tier 1, the convenience macros: one per platform, each composing the bootstrap,
the variant, the platform's app rule and the test.

- `flutter_macos_integration_test`
- `flutter_windows_integration_test`
- `flutter_linux_integration_test`
- `flutter_web_integration_test`
- `flutter_android_integration_test`
- `flutter_ios_simulator_integration_test`

Tier 2, the composable rules:

- `flutter_integration_bootstrap`: the program an integration test file runs as.
- `flutter_application_variant`: a `flutter_application` rebuilt with another
  `main`, plus extra `srcs`, `deps` and `defines`.
- `flutter_desktop_app_integration_test`: runs a desktop app on the host's desktop.
- `flutter_desktop_runner`: where it runs, and on Linux the runtime it runs with.
- `flutter_web_app_integration_test`: runs a web bundle in a headless Chrome.
- `flutter_chrome_runner`: a headless Chrome of its own, where a web test runs.
- `flutter_linux_runtime`: on Linux, the X server, GTK, Mesa and libraries a
  runner runs the app or browser with, from pinned Debian packages.
- `flutter_android_app_integration_test`: runs an Android app on an emulator or
  an attached device.
- `flutter_android_emulator_runner`: an emulator of the test's own, of a pinned
  emulator and system image.
- `flutter_android_system_image`: a system image that emulator boots.
- `flutter_android_device_runner`: an attached device, and which `adb` drives it.
- `flutter_ios_app_integration_test`: runs an iOS app on a simulator of its own.
- `flutter_ios_simulator_runner`: which simulator that is.
"""

load("//flutter:android.bzl", "flutter_android_app")
load("//flutter:ios.bzl", "flutter_ios_app")
load("//flutter:linux.bzl", "flutter_linux_app")
load("//flutter:macos.bzl", "flutter_macos_app")
load("//flutter:web.bzl", "flutter_web_app")
load("//flutter:windows.bzl", "flutter_windows_app")
load("//flutter/private:flutter_android_emulator.bzl", _flutter_android_system_image = "flutter_android_system_image")
load("//flutter/private:flutter_application_variant.bzl", _flutter_application_variant = "flutter_application_variant")
load("//flutter/private:flutter_integration_bootstrap.bzl", _flutter_integration_bootstrap = "flutter_integration_bootstrap")
load("//flutter/private:flutter_integration_test.bzl", _flutter_android_app_integration_test = "flutter_android_app_integration_test", _flutter_android_device_runner = "flutter_android_device_runner", _flutter_android_emulator_runner = "flutter_android_emulator_runner", _flutter_chrome_runner = "flutter_chrome_runner", _flutter_desktop_app_integration_test = "flutter_desktop_app_integration_test", _flutter_desktop_runner = "flutter_desktop_runner", _flutter_ios_app_integration_test = "flutter_ios_app_integration_test", _flutter_ios_simulator_runner = "flutter_ios_simulator_runner", _flutter_web_app_integration_test = "flutter_web_app_integration_test")
load("//flutter/private:flutter_linux_runtime.bzl", _flutter_linux_runtime = "flutter_linux_runtime")
load("//flutter/private:flutter_test.bzl", _flutter_test = "flutter_test")
load("//flutter/private:test_config.bzl", "find_test_config")

flutter_application_variant = _flutter_application_variant
flutter_integration_bootstrap = _flutter_integration_bootstrap
flutter_desktop_app_integration_test = _flutter_desktop_app_integration_test
flutter_desktop_runner = _flutter_desktop_runner
flutter_chrome_runner = _flutter_chrome_runner
flutter_linux_runtime = _flutter_linux_runtime
flutter_web_app_integration_test = _flutter_web_app_integration_test
flutter_android_app_integration_test = _flutter_android_app_integration_test
flutter_android_device_runner = _flutter_android_device_runner
flutter_android_emulator_runner = _flutter_android_emulator_runner
flutter_android_system_image = _flutter_android_system_image
flutter_ios_app_integration_test = _flutter_ios_app_integration_test
flutter_ios_simulator_runner = _flutter_ios_simulator_runner

# What an integration test's program imports beyond the application.
_REQUIRED_PACKAGES = ["integration_test", "flutter_test"]

def _find_test_config(name, src):
    """The `flutter_test_config.dart` `flutter test` would find for `src`, or None.

    The same search `flutter_test` runs, over this package: a `src` in another
    package has none found, and names its own with `test_config`.
    """
    if type(src) not in ("string", "Label"):
        return None
    label = native.package_relative_label(src)
    here = native.package_relative_label(":" + name)
    if (label.repo_name, label.package) != (here.repo_name, here.package):
        return None
    return find_test_config(
        label.name,
        # `allow_empty`: the lookup asks whether each candidate config exists,
        # and most tests have none.
        lambda path: bool(native.glob([path], allow_empty = True)),
    )

def _golden_service(name, deps, srcs, test_config, application = None, package = None):
    """The `flutter_test` that compares the test's goldens on the host.

    The host runner has no `dart:ui`, which comparing two pictures needs, so a
    `flutter_test` of the rule's own (`flutter/private/goldens/service.dart`)
    does it, as `flutter test` runs a `flutter_tester` to compare for the tool.
    The hub is the one of the `flutter_test` among `deps`.

    Without a `flutter_test_config.dart` the service needs `package:flutter_test`
    and nothing else, so it is one per pub hub, `@<hub>//goldens:service`, which
    every integration test of the hub shares: the test it compares for is named
    to it when it is started.

    With one, the service runs the config before it compares, as `flutter test`
    does in its comparator's bootstrap, so a comparator or tolerance the config
    sets applies. Like `flutter test`'s, that service is compiled in the app's
    package, so the config imports the app's libraries as `package:<app>/…`:
    the `application`'s, or for a test that has none, the `package` whose
    sources are among `srcs`. It is built with the config, the test's `deps`
    and the `srcs` it may import, and shared by the tests of the package that
    name all of the same.

    Args:
        name: The test's name.
        deps: The test's `deps`.
        srcs: The test's `srcs`.
        test_config: The test's `flutter_test_config.dart`, or None.
        application: The application the test runs, whose package the service
            is compiled in.
        package: The `dart_package_metadata` of the package the service is
            compiled in, for a test with no `application`.

    Returns:
        The label of the service.
    """
    hub = None
    for dep in deps:
        label = native.package_relative_label(dep)
        if label.name == "flutter_test":
            hub = label
            break
    if hub == None:
        fail((
            "%s: `deps` has no `flutter_test` (`@<hub>//:flutter_test`), which an " +
            "integration test needs to run its suite and compare its goldens."
        ) % native.package_relative_label(":" + name))
    if not test_config:
        return "@@%s//goldens:service" % hub.repo_name

    # One per config and what it is built with: tests that name the same config
    # with different `deps` or `srcs` cannot share one that compiles with only
    # one of them.
    config = native.package_relative_label(test_config)
    compiled_in = {"application": application} if application else {"package": package}
    built_with = [str(native.package_relative_label(d)) for d in sorted(deps)] + \
                 [str(native.package_relative_label(f)) for f in sorted(srcs)] + \
                 [str(native.package_relative_label(application or package))]
    service = "__golden_service_%s_%d" % (
        "".join([c if c.isalnum() else "_" for c in config.name.elems()]),
        abs(hash(str(config) + "|" + "|".join(built_with))),
    )
    if not native.existing_rule(service):
        _flutter_test(
            name = service,
            main = str(Label("//flutter/private/goldens:service.dart")),
            srcs = srcs + [str(Label("//flutter/private/goldens:comparator.dart"))],
            test_config = test_config,
            deps = deps,
            # Its `srcs` and `deps` are what the config may import, not what
            # the service loads, so only the strict half of the import check
            # applies.
            features = ["-dart_unused_deps"],
            tags = ["manual"],
            testonly = True,
            visibility = ["//visibility:private"],
            **compiled_in
        )
    return ":" + service

def _program(name, src, application, deps, srcs, test_config, src_import = None):
    """Declares the bootstrap and the variant that is the test's program.

    Returns the label of the program: the application with the bootstrap as its
    `main` and `src` among its sources. Both are the macro's own, named
    `__<name>_…`, so the user never names them. `src_import` is the
    bootstrap's, for a web program: a web compile mounts no file-system root to
    name the test under.
    """
    bootstrap = "__%s_bootstrap" % name
    program = "__%s_program" % name
    private = {
        "tags": ["manual"],
        "testonly": True,
        "visibility": ["//visibility:private"],
    }
    _flutter_integration_bootstrap(
        name = bootstrap,
        src = src,
        test_config = test_config,
        **(private | ({"src_import": src_import} if src_import else {}))
    )
    _flutter_application_variant(
        name = program,
        application = application,
        main = ":%s.dart" % bootstrap,
        # The test, what it imports, and its config.
        srcs = [src] + srcs + ([test_config] if test_config else []),
        # The bootstrap and the support library staged beside it are the rule's
        # own files: what they import is not the user's `deps` to list.
        unchecked_srcs = [":" + bootstrap],
        deps = deps,
        requires_packages = _REQUIRED_PACKAGES,
        **private
    )
    return ":" + program

def flutter_macos_integration_test(
        name,
        src,
        application,
        bundle_id,
        deps = [],
        srcs = [],
        test_config = None,
        env = {},
        data = [],
        include_tags = [],
        exclude_tags = [],
        size = "medium",
        runner = None,
        tags = [],
        timeout = None,
        shard_count = None,
        flaky = None,
        visibility = None,
        **macos_app_kwargs):
    """Runs a `package:integration_test` file on macOS: the application with the test as its program.

    The app is built in debug mode and launched on the host's own desktop, which
    needs an unlocked, awake session; the test fails, saying so, when it is not
    one. One target per test file, as upstream launches the app once per file.

    Intermediate targets `__<name>_bootstrap`, `__<name>_program` and
    `__<name>_app` are this macro's: do not name them.

    Args:
        name: The test's name.
        src: The test file. Its `main` declares the tests, as for `flutter create`:
            `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and
            `testWidgets`, calling the app's own `main()`.
        application: The `flutter_application` the test runs. It may be in another
            package.
        bundle_id: The bundle identifier of the app, which is the application's own.
        deps: What the test imports beyond the application's own `deps`. It must
            name `@<hub>//:flutter_test` itself, which says whose golden service
            compares the test's goldens: without it the BUILD file fails to
            load. `integration_test` (`@<hub>//:integration_test`) may come
            from here or from the application's `deps`, and analysis fails
            without it, naming it.
        srcs: Dart files `src` imports by relative path.
        test_config: The suite's `flutter_test_config.dart`. By default the one
            `flutter_test` would find for `src`, in this package.
        env: Environment variables for the runner and the app.
        data: Files the test reads at run time, and its golden files:
            `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the
            directory of `src`, compared on the host. `bazel run :<name> --
            --update-goldens` writes them.
        include_tags: `package:test` tag selectors a case must match to run (`@Tags` on
            `src` and `tags:` on a `testWidgets` give a case its tags), as
            `dart_test.yaml`'s `include_tags`: one boolean selector per entry, and a case
            must match every entry. Not Bazel's `tags`, which choose targets. A target
            none of whose cases match fails; `--test_env=DART_TEST_TAGS=...` narrows
            further for one run.
        exclude_tags: Tag selectors that drop a case, as `dart_test.yaml`'s `exclude_tags`:
            a case matching any entry does not run. `--test_env=DART_TEST_EXCLUDE_TAGS=...`
            drops more for one run.
        size: The test size. `medium`: a window is launched and drawn.
        runner: A `flutter_desktop_runner`, to run the test with something other than
            the host's own desktop.
        tags: Tags of the test.
        timeout: The test's `timeout`.
        shard_count: The test's `shard_count`: the tests of the file are divided
            among the shards.
        flaky: The test's `flaky`.
        visibility: The test's visibility.
        **macos_app_kwargs: Passed to `flutter_macos_app`: `app_name`,
            `entitlements`, and the rest.
    """
    if test_config == None:
        test_config = _find_test_config(name, src)
    program = _program(name, src, application, deps, srcs, test_config)

    app = "__%s_app" % name
    flutter_macos_app(
        name = app,
        application = program,
        bundle_id = bundle_id,
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
        **macos_app_kwargs
    )

    test_kwargs = {}
    if runner != None:
        test_kwargs["runner"] = runner
    _flutter_desktop_app_integration_test(
        name = name,
        app = ":" + app,
        src = src,
        golden_service = _golden_service(name, deps, srcs, test_config, application = application),
        env = env,
        data = data,
        include_tags = include_tags,
        exclude_tags = exclude_tags,
        size = size,
        tags = tags,
        timeout = timeout,
        shard_count = shard_count,
        flaky = flaky,
        visibility = visibility,
        target_compatible_with = ["@platforms//os:macos"],
        **test_kwargs
    )

def flutter_windows_integration_test(
        name,
        src,
        application,
        deps = [],
        srcs = [],
        test_config = None,
        env = {},
        data = [],
        include_tags = [],
        exclude_tags = [],
        size = "medium",
        runner = None,
        tags = [],
        timeout = None,
        shard_count = None,
        flaky = None,
        visibility = None,
        **windows_app_kwargs):
    """Runs a `package:integration_test` file on Windows: the application with the test as its program.

    The app is built in debug mode and launched in the session the test runs in,
    which is where its window is created. Windows that overlap keep drawing, so
    tests need no turns on the screen. One target per test file, as upstream
    launches the app once per file.

    Intermediate targets `__<name>_bootstrap`, `__<name>_program` and
    `__<name>_app` are this macro's: do not name them.

    Args:
        name: The test's name.
        src: The test file. Its `main` declares the tests, as for `flutter create`:
            `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and
            `testWidgets`, calling the app's own `main()`.
        application: The `flutter_application` the test runs. It may be in another
            package.
        deps: What the test imports beyond the application's own `deps`. It must
            name `@<hub>//:flutter_test` itself, which says whose golden service
            compares the test's goldens: without it the BUILD file fails to
            load. `integration_test` (`@<hub>//:integration_test`) may come
            from here or from the application's `deps`, and analysis fails
            without it, naming it.
        srcs: Dart files `src` imports by relative path.
        test_config: The suite's `flutter_test_config.dart`. By default the one
            `flutter_test` would find for `src`, in this package.
        env: Environment variables for the runner and the app.
        data: Files the test reads at run time, and its golden files:
            `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the
            directory of `src`, compared on the host. `bazel run :<name> --
            --update-goldens` writes them.
        include_tags: `package:test` tag selectors a case must match to run (`@Tags` on
            `src` and `tags:` on a `testWidgets` give a case its tags), as
            `dart_test.yaml`'s `include_tags`: one boolean selector per entry, and a case
            must match every entry. Not Bazel's `tags`, which choose targets. A target
            none of whose cases match fails; `--test_env=DART_TEST_TAGS=...` narrows
            further for one run.
        exclude_tags: Tag selectors that drop a case, as `dart_test.yaml`'s `exclude_tags`:
            a case matching any entry does not run. `--test_env=DART_TEST_EXCLUDE_TAGS=...`
            drops more for one run.
        size: The test size. `medium`: a window is launched and drawn.
        runner: A `flutter_desktop_runner`, to run the test with something other than
            the host's own desktop.
        tags: Tags of the test.
        timeout: The test's `timeout`.
        shard_count: The test's `shard_count`: the tests of the file are divided
            among the shards.
        flaky: The test's `flaky`.
        visibility: The test's visibility.
        **windows_app_kwargs: Passed to `flutter_windows_app`: `app_name`, and the
            rest.
    """
    if test_config == None:
        test_config = _find_test_config(name, src)
    program = _program(name, src, application, deps, srcs, test_config)

    app = "__%s_app" % name
    flutter_windows_app(
        name = app,
        application = program,
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
        # An app is for Windows, so is its test: another host skips both.
        target_compatible_with = ["@platforms//os:windows"],
        **windows_app_kwargs
    )

    test_kwargs = {}
    if runner != None:
        test_kwargs["runner"] = runner
    _flutter_desktop_app_integration_test(
        name = name,
        app = ":" + app,
        src = src,
        golden_service = _golden_service(name, deps, srcs, test_config, application = application),
        env = env,
        data = data,
        include_tags = include_tags,
        exclude_tags = exclude_tags,
        size = size,
        tags = tags,
        timeout = timeout,
        shard_count = shard_count,
        flaky = flaky,
        visibility = visibility,
        target_compatible_with = ["@platforms//os:windows"],
        **test_kwargs
    )

def flutter_linux_integration_test(
        name,
        src,
        application,
        application_id,
        deps = [],
        srcs = [],
        test_config = None,
        env = {},
        data = [],
        include_tags = [],
        exclude_tags = [],
        size = "medium",
        runner = None,
        tags = [],
        timeout = None,
        shard_count = None,
        flaky = None,
        visibility = None,
        **linux_app_kwargs):
    """Runs a `package:integration_test` file on Linux: the application with the test as its program.

    The app is built in debug mode and drawn on an X server the test starts for
    itself, with the GTK, software OpenGL and fonts of a pinned runtime rather
    than the host's, so the test needs no desktop session and runs the same on a
    workstation, over SSH and in CI. Tests do not share a screen. One target per
    test file, as upstream launches the app once per file.

    Intermediate targets `__<name>_bootstrap`, `__<name>_program` and
    `__<name>_app` are this macro's: do not name them.

    Args:
        name: The test's name.
        src: The test file. Its `main` declares the tests, as for `flutter create`:
            `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and
            `testWidgets`, calling the app's own `main()`.
        application: The `flutter_application` the test runs. It may be in another
            package.
        application_id: The app's `application_id`, as `flutter_linux_app` takes it.
            Required.
        deps: What the test imports beyond the application's own `deps`. It must
            name `@<hub>//:flutter_test` itself, which says whose golden service
            compares the test's goldens: without it the BUILD file fails to
            load. `integration_test` (`@<hub>//:integration_test`) may come
            from here or from the application's `deps`, and analysis fails
            without it, naming it.
        srcs: Dart files `src` imports by relative path.
        test_config: The suite's `flutter_test_config.dart`. By default the one
            `flutter_test` would find for `src`, in this package.
        env: Environment variables for the runner and the app.
        data: Files the test reads at run time, and its golden files:
            `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the
            directory of `src`, compared on the host. `bazel run :<name> --
            --update-goldens` writes them.
        include_tags: `package:test` tag selectors a case must match to run (`@Tags` on
            `src` and `tags:` on a `testWidgets` give a case its tags), as
            `dart_test.yaml`'s `include_tags`: one boolean selector per entry, and a case
            must match every entry. Not Bazel's `tags`, which choose targets. A target
            none of whose cases match fails; `--test_env=DART_TEST_TAGS=...` narrows
            further for one run.
        exclude_tags: Tag selectors that drop a case, as `dart_test.yaml`'s `exclude_tags`:
            a case matching any entry does not run. `--test_env=DART_TEST_EXCLUDE_TAGS=...`
            drops more for one run.
        size: The test size. `medium`: a window is launched and drawn.
        runner: A `flutter_desktop_runner`, to run the test with a runtime other
            than the pinned one of the host's architecture.
        tags: Tags of the test.
        timeout: The test's `timeout`.
        shard_count: The test's `shard_count`: the tests of the file are divided
            among the shards.
        flaky: The test's `flaky`.
        visibility: The test's visibility.
        **linux_app_kwargs: Passed to `flutter_linux_app`: `app_name` and the rest.
    """
    if test_config == None:
        test_config = _find_test_config(name, src)
    program = _program(name, src, application, deps, srcs, test_config)

    app = "__%s_app" % name
    flutter_linux_app(
        name = app,
        application = program,
        application_id = application_id,
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
        # An app is for Linux, so is its test: another host skips both.
        target_compatible_with = ["@platforms//os:linux"],
        **linux_app_kwargs
    )

    test_kwargs = {}
    if runner != None:
        test_kwargs["runner"] = runner
    _flutter_desktop_app_integration_test(
        name = name,
        app = ":" + app,
        src = src,
        golden_service = _golden_service(name, deps, srcs, test_config, application = application),
        env = env,
        data = data,
        include_tags = include_tags,
        exclude_tags = exclude_tags,
        size = size,
        tags = tags,
        timeout = timeout,
        shard_count = shard_count,
        flaky = flaky,
        visibility = visibility,
        target_compatible_with = ["@platforms//os:linux"],
        **test_kwargs
    )

def flutter_web_integration_test(
        name,
        src,
        application,
        deps,
        srcs = [],
        test_config = None,
        env = {},
        data = [],
        include_tags = [],
        exclude_tags = [],
        size = "medium",
        runner = None,
        tags = [],
        timeout = None,
        shard_count = None,
        flaky = None,
        visibility = None,
        target_compatible_with = [],
        use_local_canvaskit = True,
        **web_app_kwargs):
    """Runs a `package:integration_test` file in headless Chrome: the web app with the test as its program.

    The app is built in debug mode and run in a pinned Chrome for Testing
    headless shell, which `flutter test` cannot do: it refuses web devices. The
    suite is driven over the browser's DevTools protocol, so each `testWidgets`
    is a case in Bazel's test report, which `flutter drive -d chrome` cannot
    give. One target per test file, as upstream launches the app once per file.

    The test's program is the application with the test as its `main`
    (`flutter_application_variant`), built as a web app of its own and so
    compiled again for each test.

    Intermediate targets `__<name>_bootstrap`, `__<name>_program` and
    `__<name>_app` are this macro's: do not name them.

    Args:
        name: The test's name.
        src: The test file. Its `main` declares the tests, as for `flutter create`:
            `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and
            `testWidgets`, calling the app's own `main()`.
        application: The `flutter_application` the test runs. It may be in another
            package.
        deps: What the test imports beyond the application's own `deps`. It must
            name `@<hub>//:flutter_test` itself, which says whose golden service
            compares the test's goldens: without it the BUILD file fails to
            load. `integration_test` (`@<hub>//:integration_test`) may come
            from here or from the application's `deps`, and analysis fails
            without it, naming it.
        srcs: The files `src` imports by relative path.
        test_config: The suite's `flutter_test_config.dart`. By default the one
            `flutter_test` would find for `src`, in this package.
        env: Environment variables for the host runner.
        data: Files the test reads at run time, and its golden files:
            `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the
            directory of `src`, compared on the host. `bazel run :<name> --
            --update-goldens` writes them.
        include_tags: `package:test` tag selectors a case must match to run (`@Tags` on
            `src` and `tags:` on a `testWidgets` give a case its tags), as
            `dart_test.yaml`'s `include_tags`: one boolean selector per entry, and a case
            must match every entry. Not Bazel's `tags`, which choose targets. A target
            none of whose cases match fails; `--test_env=DART_TEST_TAGS=...` narrows
            further for one run.
        exclude_tags: Tag selectors that drop a case, as `dart_test.yaml`'s `exclude_tags`:
            a case matching any entry does not run. `--test_env=DART_TEST_EXCLUDE_TAGS=...`
            drops more for one run.
        size: The test size. `medium`: a browser is launched and the app drawn.
        runner: A `flutter_chrome_runner`, to run the test in a browser other than
            the pinned one.
        tags: Tags of the test.
        timeout: The test's `timeout`.
        shard_count: The test's `shard_count`: the tests of the file are divided
            among the shards.
        flaky: The test's `flaky`.
        visibility: The test's visibility.
        target_compatible_with: The test's `target_compatible_with`. A host the pinned
            browser has no build for is incompatible whatever this says.
        use_local_canvaskit: Whether the app loads its renderer from its own
            bundle, as `flutter test --platform chrome` does, so the test needs
            no network. False loads it from Google's CDN, as `flutter drive`
            does by default.
        **web_app_kwargs: Passed to `flutter_web_app`: `web_dir`, `base_href`,
            and the rest. Not `testonly`.
    """
    if test_config == None:
        test_config = _find_test_config(name, src)

    app = "__%s_app" % name
    private = {
        "tags": ["manual"],
        "testonly": True,
        "visibility": ["//visibility:private"],
    }

    # A web compile mounts no file-system root to name the test under.
    program = _program(name, src, application, deps, srcs, test_config, src_import = "relative")
    flutter_web_app(
        name = app,
        application = program,
        use_local_canvaskit = use_local_canvaskit,
        **(private | web_app_kwargs)
    )

    test_kwargs = {}
    if runner != None:
        test_kwargs["runner"] = runner
    _flutter_web_app_integration_test(
        name = name,
        app = ":" + app,
        src = src,
        golden_service = _golden_service(name, deps, srcs, test_config, application = application),
        env = env,
        data = data,
        include_tags = include_tags,
        exclude_tags = exclude_tags,
        size = size,
        tags = tags,
        timeout = timeout,
        shard_count = shard_count,
        flaky = flaky,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
        **test_kwargs
    )

def flutter_android_integration_test(
        name,
        src,
        application,
        application_id,
        deps = [],
        srcs = [],
        test_config = None,
        env = {},
        data = [],
        include_tags = [],
        exclude_tags = [],
        size = "large",
        runner = None,
        abi = None,
        tags = [],
        timeout = None,
        shard_count = None,
        flaky = None,
        visibility = None,
        target_compatible_with = [],
        **android_app_kwargs):
    """Runs a `package:integration_test` file on an Android device: the application with the test as its program.

    The app is built in debug mode for `abi`, installed on the device, started,
    and its suite driven through its VM service. One target per test file, as
    upstream launches the app once per file.

    Without a `runner`, the device is an emulator the test boots for itself
    (`flutter_android_emulator_runner`), of the emulator and system image pinned
    for the host (macOS on Apple silicon, Linux on x86_64; on other hosts the
    test is skipped), and the app is built for the image's ABI. It needs the
    host's hypervisor, and nothing attached or installed. With
    `--@rules_flutter//flutter/integration_test:android_device=attached` it is
    instead the attached phone or running emulator
    (`flutter_android_device_runner`; `--test_env=ANDROID_SERIAL=<serial>` names
    one when several are attached), and the app is built for arm64-v8a: with
    none attached, or several and none named, the test fails naming
    `adb devices`. The app stays installed on an attached device afterwards.

    Android's `integration_test` library needs `androidx.test:runner`,
    `androidx.test:rules`, `androidx.test.espresso:espresso-core` and
    `com.google.guava:guava` in the workspace's `maven.install` of
    `rules_flutter_maven`; analysis names the ones that are missing.

    Intermediate targets `__<name>_bootstrap`, `__<name>_program`, `__<name>_app`
    and, without a `runner`, `__<name>_emulator` and `__<name>_device` are this
    macro's: do not name them.

    Args:
        name: The test's name.
        src: The test file. Its `main` declares the tests, as for `flutter create`:
            `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and
            `testWidgets`, calling the app's own `main()`.
        application: The `flutter_application` the test runs. It may be in another
            package.
        application_id: The application id of the app, as `flutter_android_app`
            takes it.
        deps: What the test imports beyond the application's own `deps`. It must
            name `@<hub>//:flutter_test` itself, which says whose golden service
            compares the test's goldens: without it the BUILD file fails to
            load. `integration_test` (`@<hub>//:integration_test`) may come
            from here or from the application's `deps`, and analysis fails
            without it, naming it.
        srcs: Dart files `src` imports by relative path.
        test_config: The suite's `flutter_test_config.dart`. By default the one
            `flutter_test` would find for `src`, in this package.
        env: Refused when not empty: an app on a device cannot be handed an
            environment. Pass `defines` to the application instead.
        data: Files the test reads at run time, and its golden files:
            `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the
            directory of `src`, compared on the host. `bazel run :<name> --
            --update-goldens` writes them.
        include_tags: `package:test` tag selectors a case must match to run (`@Tags` on
            `src` and `tags:` on a `testWidgets` give a case its tags), as
            `dart_test.yaml`'s `include_tags`: one boolean selector per entry, and a case
            must match every entry. Not Bazel's `tags`, which choose targets. A target
            none of whose cases match fails; `--test_env=DART_TEST_TAGS=...` narrows
            further for one run.
        exclude_tags: Tag selectors that drop a case, as `dart_test.yaml`'s `exclude_tags`:
            a case matching any entry does not run. `--test_env=DART_TEST_EXCLUDE_TAGS=...`
            drops more for one run.
        size: The test size. `large`: an APK is built, installed and started.
        runner: A `flutter_android_emulator_runner` or a
            `flutter_android_device_runner`. By default the emulator of the host,
            or the attached device under
            `--@rules_flutter//flutter/integration_test:android_device=attached`,
            either driven with the `adb` of `@androidsdk`, the Android SDK the
            app builds with.
        abi: The ABI the app is built for, which the device must run: `arm64-v8a`
            for a phone or an Apple-silicon emulator, `x86_64` for an emulator
            on an x86_64 host, `armeabi-v7a` for a 32-bit ARM device. By
            default the ABI of the default runner's device: the host's emulator
            image's, or arm64-v8a for an attached device.
        tags: Tags of the test.
        timeout: The test's `timeout`.
        shard_count: The test's `shard_count`: the tests of the file are divided
            among the shards.
        flaky: The test's `flaky`.
        visibility: The test's visibility.
        target_compatible_with: The test's `target_compatible_with`.
        **android_app_kwargs: Passed to `flutter_android_app`: `permissions`,
            `namespace`, `manifest`, and the rest. Not `testonly`.
    """
    if test_config == None:
        test_config = _find_test_config(name, src)
    program = _program(name, src, application, deps, srcs, test_config)

    app = "__%s_app" % name
    private = {
        "tags": ["manual"],
        "visibility": ["//visibility:private"],
    }
    flutter_android_app(
        name = app,
        application = program,
        application_id = application_id,
        testonly = True,
        **(private | android_app_kwargs)
    )

    if runner == None:
        # Both are declared and only the one the flag selects is analysed, so
        # a test on an attached device fetches no emulator. The SDK is that of
        # the workspace the test is declared in: the `@androidsdk` of the one
        # SDK this workspace builds its APKs with.
        _flutter_android_emulator_runner(
            name = "__%s_emulator" % name,
            sdk = "@androidsdk//:sdk",
            emulator = Label("//flutter/integration_test:android_emulator"),
            system_image = Label("//flutter/integration_test:android_system_image"),
            # On Linux the emulator loads the X client libraries it links from
            # the pinned runtime, as a Linux test's app does.
            linux_runtime = select({
                Label("//flutter/integration_test:linux_x64"): Label("@flutter_linux_runtime_amd64//:runtime"),
                "//conditions:default": None,
            }),
            **private
        )
        _flutter_android_device_runner(
            name = "__%s_device" % name,
            sdk = "@androidsdk//:sdk",
            **private
        )
        runner = select({
            Label("//flutter/integration_test:android_on_attached_device"): ":__%s_device" % name,
            "//conditions:default": ":__%s_emulator" % name,
        })
        if abi == None:
            abi = select({
                Label("//flutter/integration_test:android_on_x86_64_emulator"): "x86_64",
                "//conditions:default": "arm64-v8a",
            })
    if abi == None:
        abi = "arm64-v8a"

    _flutter_android_app_integration_test(
        name = name,
        app = ":" + app,
        src = src,
        golden_service = _golden_service(name, deps, srcs, test_config, application = application),
        runner = runner,
        abi = abi,
        env = env,
        data = data,
        include_tags = include_tags,
        exclude_tags = exclude_tags,
        size = size,
        tags = tags,
        timeout = timeout,
        shard_count = shard_count,
        flaky = flaky,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

def flutter_ios_simulator_integration_test(
        name,
        src,
        application,
        bundle_id,
        deps = [],
        srcs = [],
        test_config = None,
        env = {},
        data = [],
        include_tags = [],
        exclude_tags = [],
        size = "large",
        runner = None,
        tags = [],
        timeout = None,
        shard_count = None,
        flaky = None,
        visibility = None,
        **ios_app_kwargs):
    """Runs a `package:integration_test` file on an iOS simulator: the application with the test as its program.

    The app is built in debug mode for the simulator, and the test makes a
    simulator of its own, boots it, installs and starts the app and drives its
    suite through its VM service, then shuts the simulator down and deletes it,
    however the test ends. A host with no iOS simulator runtime fails the test,
    saying `xcodebuild -downloadPlatform iOS`. One target per test file, as
    upstream launches the app once per file.

    Intermediate targets `__<name>_bootstrap`, `__<name>_program` and
    `__<name>_app` are this macro's: do not name them.

    Args:
        name: The test's name.
        src: The test file. Its `main` declares the tests, as for `flutter create`:
            `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and
            `testWidgets`, calling the app's own `main()`.
        application: The `flutter_application` the test runs. It may be in another
            package.
        bundle_id: The bundle identifier of the app, as `flutter_ios_app` takes it.
        deps: What the test imports beyond the application's own `deps`. It must
            name `@<hub>//:flutter_test` itself, which says whose golden service
            compares the test's goldens: without it the BUILD file fails to
            load. `integration_test` (`@<hub>//:integration_test`) may come
            from here or from the application's `deps`, and analysis fails
            without it, naming it.
        srcs: Dart files `src` imports by relative path.
        test_config: The suite's `flutter_test_config.dart`. By default the one
            `flutter_test` would find for `src`, in this package.
        env: Refused when not empty: an app on a simulator cannot be handed an
            environment. Pass `defines` to the application instead.
        data: Files the test reads at run time, and its golden files:
            `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the
            directory of `src`, compared on the host. `bazel run :<name> --
            --update-goldens` writes them.
        include_tags: `package:test` tag selectors a case must match to run (`@Tags` on
            `src` and `tags:` on a `testWidgets` give a case its tags), as
            `dart_test.yaml`'s `include_tags`: one boolean selector per entry, and a case
            must match every entry. Not Bazel's `tags`, which choose targets. A target
            none of whose cases match fails; `--test_env=DART_TEST_TAGS=...` narrows
            further for one run.
        exclude_tags: Tag selectors that drop a case, as `dart_test.yaml`'s `exclude_tags`:
            a case matching any entry does not run. `--test_env=DART_TEST_EXCLUDE_TAGS=...`
            drops more for one run.
        size: The test size. `large`: an app is built, a simulator booted and the
            app installed.
        runner: A `flutter_ios_simulator_runner`, to run on another device type or
            runtime than the default (an iPhone 16 on the newest installed iOS).
        tags: Tags of the test.
        timeout: The test's `timeout`.
        shard_count: The test's `shard_count`: the tests of the file are divided
            among the shards, each on a simulator of its own.
        flaky: The test's `flaky`.
        visibility: The test's visibility.
        **ios_app_kwargs: Passed to `flutter_ios_app`: `app_name`, `entitlements`,
            and the rest. Not `testonly`.
    """
    if test_config == None:
        test_config = _find_test_config(name, src)
    program = _program(name, src, application, deps, srcs, test_config)

    app = "__%s_app" % name
    private = {
        "tags": ["manual"],
        "visibility": ["//visibility:private"],
    }
    flutter_ios_app(
        name = app,
        application = program,
        bundle_id = bundle_id,
        testonly = True,
        **(private | ios_app_kwargs)
    )

    test_kwargs = {}
    if runner != None:
        test_kwargs["runner"] = runner
    _flutter_ios_app_integration_test(
        name = name,
        app = ":" + app,
        src = src,
        golden_service = _golden_service(name, deps, srcs, test_config, application = application),
        env = env,
        data = data,
        include_tags = include_tags,
        exclude_tags = exclude_tags,
        size = size,
        tags = tags,
        timeout = timeout,
        shard_count = shard_count,
        flaky = flaky,
        visibility = visibility,
        target_compatible_with = ["@platforms//os:macos"],
        **test_kwargs
    )
