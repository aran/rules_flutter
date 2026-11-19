/// Which operating systems CI runs each e2e workspace on, and the matrix
/// `.github/workflows/ci.yaml` builds from it.
///
/// This table is the one place that says so. A job costs runner time, so each
/// one has to earn it: a workspace runs on a system only where it exercises
/// something there that no other job does, and its entry says what. That is an
/// OS-specific path (a runner, a toolchain, a bundle layout, a plugin's
/// implementation for that platform, how the host loads a library), or, for a
/// workspace whose subject does not depend on the OS, the one run it needs at
/// all, on the cheapest system that builds it. Everywhere else it names why it
/// does not run: what covers it instead, or that the system cannot build it.
///
/// Every workspace under `e2e/` must be listed and must account for each of the
/// three systems. A workspace added without an entry fails the `plan` job, as
/// does an entry for a workspace that is gone, a run without a purpose, or the
/// same purpose given for two systems (which says the second adds nothing).
///
/// The `deep` tier (each workspace's `.bazelrc`) is not in a plain
/// `bazel test //...`, so the runs above never reach it. A workspace with
/// `deep` targets says in [E2eWorkspace.deep] what its weekly run of them
/// exercises, and the `E2E deep` job runs them; one with `deep` targets and no
/// such entry fails the `plan` job.
library;

/// An operating system a CI job runs on.
enum Os {
  macos('macos-latest'),
  linux('ubuntu-latest'),
  windows('windows-latest');

  const Os(this.runner);

  /// The `runs-on` label of the GitHub-hosted runner.
  final String runner;
}

/// One e2e workspace and what CI does with it on each operating system.
class E2eWorkspace {
  const E2eWorkspace(
    this.name, {
    this.runs = const {},
    this.skips = const {},
    this.command = 'test',
    this.commands = const {},
    this.testsNamed = const {},
    this.deep,
  });

  /// The directory under `e2e/`, with `/` separators.
  final String name;

  /// The systems it runs on, each with what it exercises there that no other
  /// job does.
  final Map<Os, String> runs;

  /// The systems it does not run on, each with why: the job that covers it
  /// instead, or that the system cannot build it.
  final Map<Os, String> skips;

  /// The Bazel command run in the workspace: `test`, or `build` where a
  /// workspace has no test targets (`bazel test` exits 4 for those).
  final String command;

  /// The systems that run another Bazel command than [command]: a workspace
  /// that only builds on most systems can test on one.
  final Map<Os, String> commands;

  /// The name prefixes that select what each system runs the command on, where
  /// that is not `//...`: a workspace whose `//...` holds tests that need
  /// hardware or a desktop session runs the ones a runner can run, and a
  /// system that adds only some of a workspace's subject runs only those. Every
  /// `<prefix>...test` target of the workspace root package is run, so a test
  /// added under a prefix is picked up without touching the table.
  /// [targetProblems] holds each prefix to matching something.
  final Map<Os, List<String>> testsNamed;

  /// What the workspace's `deep`-tagged tests exercise that nothing else in CI
  /// does, when the weekly `E2E deep` job runs them; null for a workspace with
  /// none. They run on Linux only: the job has no other system's setup, and
  /// what they need (a JDK, the Android SDK) Bazel downloads on any host, so
  /// the cheapest runner will do.
  final String? deep;

  /// The Bazel command CI runs in the workspace on [os].
  String commandOn(Os os) => commands[os] ?? command;

  /// The target patterns CI runs [commandOn] on in the workspace on [os], given
  /// the text of the workspace's `BUILD.bazel`.
  List<String> targetsOn(Os os, String buildFile) {
    final prefixes = testsNamed[os];
    if (prefixes == null) return const ['//...'];
    final names = {
      for (final prefix in prefixes) ...testsFor(buildFile, prefix),
    }.toList()..sort();
    return [for (final name in names) '//:$name'];
  }
}

/// The names of the `*_test` targets in [buildFile] that start with [prefix].
List<String> testsFor(String buildFile, String prefix) => [
  for (final match in RegExp(
    r'name\s*=\s*"(' + RegExp.escape(prefix) + r'[\w.-]*_test)"',
  ).allMatches(buildFile))
    match.group(1)!,
];

const _appleOnly =
    'every test is target_compatible_with macOS: it builds Apple bundles, '
    'which no other host can analyse';

const _consumerQuery =
    'it has no targets; the `consumer-query` job queries the whole module '
    'from it instead';

const _webElsewhere =
    'web bundles are platform-neutral; hello_world builds one on this host, '
    'which is what depends on it (the host web compilers and wasm-opt)';

const _customEngineJob =
    'its targets are manual: the `custom-engine` job builds and checks them '
    'with the stand-in checkout through the dev tool e2e test, on macOS';

const e2eWorkspaces = <E2eWorkspace>[
  // The BCR presubmit module (.bcr/presubmit.yml), which BCR runs on Debian,
  // Ubuntu, macOS and Windows before it accepts a release. Each job is the
  // minimal consumer's toolchain resolving on that host, with none of the
  // modules a fuller workspace declares to hide a gap. About a minute each.
  E2eWorkspace(
    'smoke',
    runs: {
      Os.macos: 'the BCR presubmit module resolving its toolchain on a Mac',
      Os.linux:
          'the BCR presubmit module resolving its toolchain on Linux (BCR '
          'runs Debian and Ubuntu)',
      Os.windows: 'the BCR presubmit module resolving its toolchain on Windows',
    },
  ),
  // Not an E2E job: the `consumer-query` job in ci.yaml queries
  // `@rules_flutter//...` from it, on all three systems.
  E2eWorkspace(
    'external_module',
    skips: {
      Os.macos: _consumerQuery,
      Os.linux: _consumerQuery,
      Os.windows: _consumerQuery,
    },
  ),
  E2eWorkspace(
    'dual_hub',
    runs: {
      Os.linux:
          'two pub hubs over two locks: the only coverage of duplicate package '
          'records across hubs. Pure Dart, no Flutter app; one run, on the '
          'cheapest runner',
    },
    skips: {
      Os.macos: 'pure Dart with nothing OS-specific; Linux runs it',
      Os.windows: 'pure Dart with nothing OS-specific; Linux runs it',
    },
  ),
  // Also the one job per system that saves the repository cache (ci.yaml).
  E2eWorkspace(
    'hello_world',
    runs: {
      Os.macos:
          'Tier-1 flutter_macos_app and flutter_ios_app over the `flutter '
          'create` runners (entitlements, app icon), the iOS simulator bundle, '
          'Android and web built from a Mac, flutter_test under the macOS '
          'flutter_tester',
      Os.linux:
          'Tier-1 flutter_linux_app over the `flutter create` GTK runner, its '
          'profile-mode bundle (a profile AOT snapshot builds only on its own '
          'OS), Android and web built from Linux, flutter_test under the Linux '
          'flutter_tester',
      Os.windows:
          'Tier-1 flutter_windows_app over the `flutter create` Win32 runner, '
          'its profile-mode bundle (buildable only on Windows), web built from '
          'Windows, flutter_test under the Windows flutter_tester with '
          'manifest-only runfiles',
    },
  ),
  // The codegen, gen-l10n and golden tests here are platform-neutral and ride
  // along; what each system adds is how its flutter_tester loads a native
  // library, which only this workspace tests.
  E2eWorkspace(
    'codegen',
    runs: {
      Os.macos:
          'Native Assets under the macOS flutter_tester (a .dylib by runfiles '
          'path in flutter_test, by DYLD_LIBRARY_PATH in flutter_tester_binary), '
          'and the Bazel-generated macOS runner over a source-assembled '
          '(.pkgsrcs) package, the build half of codegen hot reload',
      Os.linux:
          'Native Assets under the Linux flutter_tester: a .so by runfiles path '
          'in flutter_test, by LD_LIBRARY_PATH in flutter_tester_binary, and '
          'under a platform transition',
      Os.windows:
          'Native Assets under the Windows flutter_tester: a .dll found through '
          'manifest-only runfiles in flutter_test, and by PATH in '
          'flutter_tester_binary',
    },
  ),
  E2eWorkspace(
    'plugin_example',
    runs: {
      Os.macos:
          'pub plugins\' Apple implementations (SwiftPM path_provider_foundation, '
          'shared_preferences_foundation, url_launcher_macos) and their privacy '
          'manifests in the macOS and iOS simulator bundles',
      Os.linux:
          'pub plugins\' Linux implementations (C++ url_launcher_linux, Dart '
          'path_provider_linux and shared_preferences_linux) registered in the '
          '`flutter create` Linux runner',
      Os.windows:
          'pub plugins\' Windows implementations (C++ url_launcher_windows, Dart '
          'path_provider_windows and shared_preferences_windows) registered in '
          'the `flutter create` Win32 runner and linked into it; and one arm64 '
          'APK, whose AAR resources are the longest paths aapt2 opens on a '
          'Windows host (ci.yaml, `D:/b`). Its other Android targets add '
          'nothing here: android_example\'s Windows job builds Android on a '
          'Windows host, and this workspace\'s Linux and macOS jobs build its '
          'plugins\' Android side',
    },
    // `windows_*_test`: the bundle and its plugin's link libraries;
    // `android_bundle_build_test`: the arm64 APK.
    testsNamed: {
      Os.windows: ['windows_', 'android_bundle_'],
    },
    deep:
        'a real Gradle consumer of the add-to-app output: gradle_host_test '
        'builds a native host app with Gradle, offline, against the debug, '
        'profile and release repositories of the module and checks each APK\'s '
        'native libraries per ABI, dexed plugin classes and merged manifest; '
        'and gradle_module_metadata_live_test, the pinned Gradle module '
        'metadata against the live Maven repositories',
  ),
  E2eWorkspace(
    'ffi_example',
    runs: {
      Os.macos:
          'native_deps libraries and Native Assets code assets linked by the '
          'Apple toolchain into the macOS .app\'s Frameworks and the iOS '
          'simulator bundle, and, in //plugin_class, a flutter_plugin that '
          'carries native_deps with a dart_plugin_class, statically linked '
          'into the iOS app',
      Os.linux:
          'native_deps libraries and Native Assets code assets as ELF shared '
          'libraries (with -ldl) in the Linux bundle\'s lib/, and, in '
          '//plugin_class, a flutter_plugin that carries native_deps with a '
          'dart_plugin_class, its library bundled into the app',
      Os.windows:
          'native_deps libraries and Native Assets code assets as DLLs beside '
          'the Windows bundle\'s .exe; //plugin_class builds no Windows '
          'bundle, and its platform-neutral targets build here too',
    },
  ),
  E2eWorkspace(
    'web_example',
    runs: {
      Os.linux:
          'the web bundle\'s variants (wasm with JS fallback, wasm-only, '
          'subpath, PWA and service worker, browser allow-list, compiler flags, '
          'profile): platform-neutral, so one run, on the cheapest runner; '
          'and the render check, the app in the pinned headless Chrome with '
          'the pinned Linux runtime\'s libraries',
    },
    skips: {Os.macos: _webElsewhere, Os.windows: _webElsewhere},
  ),
  // Not an E2E job: every target that exercises the checkout is manual, and
  // the `custom-engine` job in ci.yaml runs them through the dev tool's
  // custom_engine_e2e_test, which builds them with the checkout selected.
  E2eWorkspace(
    'custom_engine',
    skips: {
      Os.macos: _customEngineJob,
      Os.linux: _customEngineJob,
      Os.windows: _customEngineJob,
    },
    deep:
        'a real Gradle consumer of a custom engine\'s add-to-app output: '
        'gradle_host_test builds a native host app with Gradle, offline, '
        'against the stand-in engine\'s module, from a repository with no '
        '`io.flutter` artifact of its own, and checks that the APK\'s '
        'libflutter.so is the one the module\'s repository carries',
  ),
  E2eWorkspace(
    'pub_resolve',
    runs: {
      Os.linux:
          'a monorepo\'s path pub packages, and a fork of a hosted one, built '
          'from the workspace targets `flutter_pub.from_lock(resolve = ...)` '
          'maps: platform-neutral, so one run, on the cheapest runner; with the '
          'render check in the pinned headless Chrome',
    },
    skips: {Os.macos: _webElsewhere, Os.windows: _webElsewhere},
  ),
  E2eWorkspace(
    'android_example',
    runs: {
      Os.linux:
          'Android app variants (a second app, permissions, the Bazel-generated '
          'and custom Kotlin runners, NDK code assets): platform-neutral past '
          'the host tools, so one run, on the cheapest runner',
      Os.windows:
          'Android build on a Windows host: gen_snapshot.exe naming, '
          'engine-strip path separators, and rules_android JVMs started '
          'without committing their whole heap (the committed patch)',
    },
    skips: {
      Os.macos:
          'hello_world and plugin_example build Android from a Mac, which is '
          'what depends on the host (aapt2, the NDK, gen_snapshot)',
    },
  ),
  // Pins `--platforms=linux_x64` for every command, so it has no test
  // targets: CI builds it.
  E2eWorkspace(
    'cross_compile_example',
    runs: {
      Os.macos:
          'the Linux bundle cross-compiled from a Mac: the macOS-to-Linux C++ '
          'toolchain and the Linux sysroot, which no Linux runner uses',
    },
    skips: {
      Os.linux:
          'on a Linux host the target is an ordinary native Linux bundle, '
          'which hello_world and desktop_example build',
      Os.windows: 'the Flutter toolchain has no Windows-to-Linux pair',
    },
    command: 'build',
  ),
  E2eWorkspace(
    'macos_example',
    runs: {
      Os.macos:
          'macOS-only features: app extensions and App Intents, team signing, '
          'entitlements, two apps from one package, the Tier-2 Bazel-generated '
          'and custom runners, the profile-mode app',
    },
    skips: {Os.linux: _appleOnly, Os.windows: _appleOnly},
  ),
  // Most of its tests launch the app in a window, which needs a desktop
  // session that CI never runs a test in, or on a device (docs/TESTING.md,
  // "What CI covers"): CI builds it, and those run by hand. The Linux and web
  // tests need neither, on the pinned Linux runtime, so Linux runs them.
  E2eWorkspace(
    'integration_test',
    runs: {
      Os.macos:
          'the integration test rules building: the bootstrap, the variant of '
          'the application, the macOS, web, Android and iOS app and the test, '
          'for each case',
      Os.linux:
          'the Linux and web integration tests running headless on the pinned '
          'Linux runtime, which is fetched with every file of it, and of the '
          'Chrome that loads it, checked against the oldest supported host',
      Os.windows:
          'the Windows app and tests building (the Android tests, on an '
          'emulator pinned for macOS and Linux only, are skipped there)',
    },
    command: 'build',
    commands: {Os.linux: 'test'},
    testsNamed: {
      Os.linux: ['linux_', 'web_'],
    },
  ),
  E2eWorkspace(
    'ios_example',
    runs: {
      Os.macos:
          'iOS-only features: app extensions and App Intents, Info.plist and '
          'app icon, two apps from one package, the simulator refusing '
          'fastbuild, the Tier-2 Bazel-generated and custom runners',
    },
    skips: {Os.linux: _appleOnly, Os.windows: _appleOnly},
  ),
  E2eWorkspace(
    'multi_window_example',
    runs: {
      Os.macos:
          'a hand-written runner with two windows on one FlutterEngineGroup '
          '(two Dart entry points in one compilation), on macOS and as UIScene '
          'scenes on iOS',
    },
    skips: {Os.linux: _appleOnly, Os.windows: _appleOnly},
  ),
  // The link hooks' tests read the flutter_application's bundle, not the macOS
  // app, and the hook runs over the host's release AOT compile. The code
  // asset's dylib is macOS-only.
  E2eWorkspace(
    'package_assets',
    runs: {
      Os.linux:
          'package link hooks over the uses a release compile records, the '
          'hook\'s assets in the bundle, and the declared data assets it '
          'drops and keeps, native and web, with a package\'s own hook: '
          'platform-neutral, so one run, on the cheapest runner. The code '
          'asset\'s tests are macOS-only and skip here',
      Os.macos:
          'a dart_code_asset over a hand-linked dylib with its own install '
          'name, and a dart_data_asset in the bundle, both declared on the app '
          'package\'s own metadata, which no library in deps names; the link '
          'hook tests run here too, which costs little',
    },
    skips: {Os.windows: 'platform-neutral; Linux runs it'},
  ),
  // The flutter_assets/ tree of every platform (Android, iOS, Linux, macOS,
  // Windows, web) is built from this one host by platform transition, so what
  // it checks does not depend on the OS it runs on. Only a Mac can analyse the
  // iOS targets among them.
  E2eWorkspace(
    'asset_bundle',
    runs: {
      Os.macos:
          'every asset a pubspec declares reaching the flutter_assets/ tree '
          'under the key, variants, stored name and platform set `flutter '
          'build` gives it, for an app at the root, a library below it, one '
          'in another module and fixture-registry pub packages: '
          'platform-neutral, so one run, on the only system that can analyse '
          'its iOS targets',
    },
    skips: {
      Os.linux:
          'its platform checks bundle the same application for iOS, which '
          'no other host can analyse',
      Os.windows:
          'its platform checks bundle the same application for iOS, which '
          'no other host can analyse, and its fixture registry runs `cp` '
          'and `tar`',
    },
  ),
  // One Flutter project with `linux/` and `windows/` runners side by side. Every
  // target is compatible with its own OS only, so each runner skips the
  // other's targets and nothing is analysed on the wrong host.
  E2eWorkspace(
    'desktop_example',
    runs: {
      Os.linux:
          'Tier-2 Linux rules: the `flutter create` GTK runner, and the '
          'engine, registrant and Bazel-generated GTK runner composed by '
          'hand with its window title',
      Os.windows:
          'Tier-2 Windows rules: the `flutter create` Win32 runner, the '
          'Bazel-generated Win32 runner and a custom cc_binary runner',
    },
    skips: {
      Os.macos:
          'its targets are compatible with Linux or Windows only, so they '
          'skip cleanly here',
    },
  ),
];

/// What is wrong with [table] as a description of [found], the workspaces
/// under `e2e/` (as `e2e/<name>`, the form `findWorkspaces` returns); empty
/// when nothing is.
List<String> matrixProblems(
  List<E2eWorkspace> table,
  Iterable<String> found,
) {
  final problems = <String>[];
  final listed = <String>{};
  for (final workspace in table) {
    final name = workspace.name;
    if (!listed.add(name)) problems.add('$name is listed twice');
    for (final os in Os.values) {
      final runs = workspace.runs[os];
      final skips = workspace.skips[os];
      if (runs != null && skips != null) {
        problems.add('$name both runs and is skipped on ${os.name}');
      } else if (runs == null && skips == null) {
        problems.add(
          '$name neither runs on ${os.name} nor says why not',
        );
      } else if (runs != null && runs.trim().isEmpty) {
        problems.add(
          '$name runs on ${os.name} without saying what it exercises there '
          'that no other job does',
        );
      } else if (skips != null && skips.trim().isEmpty) {
        problems.add('$name is skipped on ${os.name} without a reason');
      }
    }
    final systems = <String, Os>{};
    for (final MapEntry(key: os, value: purpose) in workspace.runs.entries) {
      final first = systems.putIfAbsent(purpose.trim(), () => os);
      if (first != os && purpose.trim().isNotEmpty) {
        problems.add(
          '$name gives ${first.name} and ${os.name} the same purpose: say what '
          'each system adds, or run it on one',
        );
      }
    }
  }
  final existing = {for (final path in found) path.replaceFirst('e2e/', '')};
  for (final name in existing.difference(listed)) {
    problems.add(
      'e2e/$name is in no entry: add it to e2eWorkspaces in '
      'tools/ci_matrix/e2e_matrix.dart, with what it exercises on each system '
      'it runs on',
    );
  }
  for (final name in listed.difference(existing)) {
    problems.add('e2eWorkspaces lists e2e/$name, which does not exist');
  }
  return problems..sort();
}

/// The jobs of [table] as the `include` list of a GitHub Actions matrix, in
/// table order, one per workspace and system it runs on. [buildFile] returns
/// the text of `e2e/<workspace>/BUILD.bazel`.
List<Map<String, String>> matrixInclude(
  List<E2eWorkspace> table,
  String Function(String workspace) buildFile,
) => [
  for (final workspace in table)
    for (final os in Os.values)
      if (workspace.runs.containsKey(os))
        {
          'workspace': workspace.name,
          'os': os.runner,
          'command': workspace.commandOn(os),
          'targets': workspace
              .targetsOn(os, buildFile(workspace.name))
              .join(' '),
        },
];

/// The workspaces the weekly `E2E deep` job runs, as the `include` list of a
/// GitHub Actions matrix, in table order.
List<Map<String, String>> deepInclude(List<E2eWorkspace> table) => [
  for (final workspace in table)
    if (workspace.deep != null) {'workspace': workspace.name},
];

/// Whether a target in [buildFile], the text of a BUILD file, has the tag
/// `deep`: the string `"deep"` in the expression a `tags =` argument is given,
/// as in `tags = ["android", "deep"]` and `tags = ["android"] + (["deep"] if
/// profile else [])`. A string elsewhere (a target named `"deep"`) and a
/// comment are no tag. A tag list kept in a variable is not seen.
bool hasDeepTag(String buildFile) {
  final text = buildFile;

  // The string literal that starts at [i]: its value and where it ends; null
  // when none starts there.
  (String, int)? stringAt(int i) {
    final quote = text[i];
    if (quote != '"' && quote != "'") return null;
    final triple = text.startsWith(quote * 3, i);
    final width = triple ? 3 : 1;
    final value = StringBuffer();
    var j = i + width;
    while (j < text.length) {
      if (text[j] == r'\' && j + 1 < text.length) {
        value.write(text[j + 1]);
        j += 2;
      } else if (text.startsWith(quote * width, j)) {
        return (value.toString(), j + width);
      } else if (!triple && text[j] == '\n') {
        break;
      } else {
        value.write(text[j++]);
      }
    }
    return (value.toString(), j);
  }

  int endOfComment(int i) {
    final end = text.indexOf('\n', i);
    return end < 0 ? text.length : end;
  }

  final assignment = RegExp(r'\s*=(?!=)');
  final wordCharacter = RegExp(r'[A-Za-z0-9_.]');

  // Where the expression a `tags =` argument is given starts, when one does at
  // [i]; null for anything else, `test_tags =` and `tags ==` included.
  int? tagsExpressionAt(int i) {
    if (!text.startsWith('tags', i)) return null;
    if (i > 0 && wordCharacter.hasMatch(text[i - 1])) return null;
    return assignment.matchAsPrefix(text, i + 4)?.end;
  }

  var i = 0;
  while (i < text.length) {
    if (text[i] == '#') {
      i = endOfComment(i);
    } else if (stringAt(i) case (_, final end)) {
      i = end;
    } else if (tagsExpressionAt(i) case final start?) {
      // The expression runs to the `,` or the closing bracket that ends the
      // argument; a `,` inside a bracket belongs to the expression.
      var depth = 0;
      var j = start;
      while (j < text.length) {
        final c = text[j];
        if (c == '#') {
          j = endOfComment(j);
        } else if (stringAt(j) case (final value, final end)) {
          if (value == 'deep') return true;
          j = end;
        } else if ('([{'.contains(c)) {
          depth++;
          j++;
        } else if (')]}'.contains(c)) {
          if (depth == 0) break;
          depth--;
          j++;
        } else if (c == ',' && depth == 0) {
          break;
        } else {
          j++;
        }
      }
      i = j;
    } else {
      i++;
    }
  }
  return false;
}

/// What is wrong with the `deep` entries of [table]: one that says nothing, one
/// whose workspace has no `deep`-tagged target in any of its BUILD files, and a
/// workspace with such a target and no entry, whose `deep` tests no job would
/// run. [buildFiles] returns the text of every BUILD file of a workspace, the
/// subpackages' as well as the root's.
List<String> deepProblems(
  List<E2eWorkspace> table,
  Iterable<String> Function(String workspace) buildFiles,
) {
  final problems = <String>[];
  for (final workspace in table) {
    final tagged = buildFiles(workspace.name).any(hasDeepTag);
    final purpose = workspace.deep;
    if (purpose == null) {
      if (tagged) {
        problems.add(
          '${workspace.name} has `deep` targets that no CI job runs: say what '
          'they exercise in its `deep` entry',
        );
      }
    } else if (purpose.trim().isEmpty) {
      problems.add(
        '${workspace.name} runs its deep tier without saying what it '
        'exercises that no other job does',
      );
    } else if (!tagged) {
      problems.add(
        '${workspace.name} runs its deep tier, but no BUILD file of '
        'e2e/${workspace.name} has a target tagged "deep"',
      );
    }
  }
  return problems..sort();
}

/// The workspaces each `Lock files` job of ci.yaml checks with
/// `@overhead//locks:check`, as directories relative to the repository root
/// (`.` for the root), keyed by the system the job runs on.
///
/// The check runs `bazel build --nobuild //...`, which needs a host that can
/// analyse every target. A workspace whose table entry runs it on macOS may
/// have Apple targets, which only a Mac can analyse, so it is checked there;
/// so is one that runs on no system, whose CI is a job of its own that the
/// table does not describe. Every other workspace, and the root, analyses
/// `//...` on Linux in its own jobs, so it is checked on Linux, where runners
/// are cheaper and less scarce. No lock records an OS-dependent extension, so
/// the host does not change what is checked.
Map<Os, List<String>> lockCheckWorkspaces(List<E2eWorkspace> table) {
  final hosts = <Os, List<String>>{
    Os.linux: ['.'],
    Os.macos: [],
  };
  for (final workspace in table) {
    final onMac =
        workspace.runs.containsKey(Os.macos) || workspace.runs.isEmpty;
    hosts[onMac ? Os.macos : Os.linux]!.add('e2e/${workspace.name}');
  }
  for (final list in hosts.values) {
    list.sort();
  }
  return hosts;
}

/// The `Lock files` jobs of [hosts] as the `include` list of a GitHub Actions
/// matrix: one per system, with its workspaces space-separated.
List<Map<String, String>> lockCheckInclude(Map<Os, List<String>> hosts) => [
  for (final MapEntry(key: os, value: workspaces) in hosts.entries)
    if (workspaces.isNotEmpty)
      {'os': os.runner, 'workspaces': workspaces.join(' ')},
];

/// What is wrong with [hosts] as the lock checks of the workspaces whose
/// `MODULE.bazel.lock` is tracked at [lockFiles] (`/`-separated paths from the
/// repository root): a lock no job checks.
List<String> lockCheckProblems(
  Map<Os, List<String>> hosts,
  Iterable<String> lockFiles,
) {
  final checked = {for (final list in hosts.values) ...list};
  return [
    for (final file in lockFiles)
      if (!checked.contains(
        file == 'MODULE.bazel.lock'
            ? '.'
            : file.substring(0, file.length - '/MODULE.bazel.lock'.length),
      ))
        '$file is checked by no `Lock files` job: lockCheckWorkspaces in '
            'tools/ci_matrix/e2e_matrix.dart covers the root and the '
            'workspaces of its table only',
  ]..sort();
}

/// What is wrong with the test selections of [table]: a prefix that matches no
/// `*_test` target in its workspace's BUILD file, or no prefix at all.
/// [buildFile] returns the text of `e2e/<workspace>/BUILD.bazel`.
List<String> targetProblems(
  List<E2eWorkspace> table,
  String Function(String workspace) buildFile,
) {
  final problems = <String>[];
  for (final workspace in table) {
    for (final MapEntry(key: os, value: prefixes)
        in workspace.testsNamed.entries) {
      if (prefixes.isEmpty) {
        problems.add('${workspace.name} on ${os.name} selects no tests');
      }
      for (final prefix in prefixes) {
        if (testsFor(buildFile(workspace.name), prefix).isEmpty) {
          problems.add(
            '${workspace.name} on ${os.name}: no `$prefix...test` target in '
            'e2e/${workspace.name}/BUILD.bazel',
          );
        }
      }
    }
  }
  return problems..sort();
}

/// The entries of `e2e/` the release archive keeps: `smoke`, which
/// `.bcr/presubmit.yml` names as its `module_path`.
const archivedE2eEntries = {'smoke'};

/// What is wrong with [gitattributes] as the release archive's filter of
/// `e2e/`, whose top-level entries are [entries] (names, with a trailing `/`
/// for a directory); empty when nothing is. Every entry but
/// [archivedE2eEntries] needs its own `export-ignore` line, and a line for an
/// entry that does not exist is stale.
List<String> archiveProblems(Iterable<String> entries, String gitattributes) {
  final ignored = <String>{
    for (final line in gitattributes.split('\n'))
      if (RegExp(r'^/e2e/([^/\s]+/?)\s+export-ignore\s*$')
              .firstMatch(line.trim())
          case final match?)
        match.group(1)!,
  };
  final problems = <String>[];
  for (final entry in entries) {
    final name = entry.endsWith('/')
        ? entry.substring(0, entry.length - 1)
        : entry;
    if (archivedE2eEntries.contains(name)) continue;
    if (!ignored.contains(entry)) {
      problems.add(
        'e2e/$entry has no `/e2e/$entry export-ignore` line in .gitattributes, '
        'so the release archive ships it',
      );
    }
  }
  for (final entry in ignored.difference(entries.toSet())) {
    problems.add(
      '.gitattributes export-ignores /e2e/$entry, which does not exist',
    );
  }
  return problems..sort();
}
