/// Locating the external programs the dev tool drives.
///
/// The dev tool shells out to binaries it neither owns nor can vendor: the
/// Android SDK's `adb` and `aapt2`, `lldb` and `iproxy` for a physical iOS
/// device, Chrome. They belong to the user's machine, so searching the SDK's
/// own conventional locations and PATH is legitimate — *guessing* is not.
/// Handing `Process.run` a bare `'aapt2'` and hoping defers the failure into
/// the middle of a launch, where it surfaces as an unrelated fault: an APK
/// installed but never named, no activity started, and VM-service discovery
/// blamed thirty seconds later for an app that was never started.
///
/// So a tool is resolved to a real path before the work that needs it (see
/// `Device.requiredHostTools`), and absence is an error naming the binary, the
/// places searched, and what to install or set.
import 'dart:io';

import 'package:path/path.dart' as p;

/// A tool a run needs and could not find anywhere.
///
/// Extends [StateError] because that is what every other launch-blocking
/// failure in the dev tool throws, so the callers that already turn one into a
/// user-facing error need no new case.
class MissingHostToolException extends StateError {
  MissingHostToolException(super.message);
}

/// An external program the dev tool runs, and everywhere it might live.
class HostTool {
  /// What to call it in diagnostics — usually the executable's own name.
  final String name;

  /// Absolute paths tried before PATH, most authoritative first.
  final List<String> candidates;

  /// Executable names looked for in each PATH entry. Empty means this tool is
  /// never expected on PATH (a macOS application bundle, say).
  final List<String> pathNames;

  /// What the run needs it for, completing "… is needed to …".
  final String purpose;

  /// What the user should do when it is missing.
  final String remedy;

  final Map<String, String> _environment;

  HostTool({
    required this.name,
    required this.purpose,
    required this.remedy,
    this.candidates = const [],
    List<String>? pathNames,
    Map<String, String>? environment,
  }) : pathNames = pathNames ?? [name],
       _environment = environment ?? Platform.environment;

  /// The path to run, or null when this machine does not have the tool.
  String? find() {
    for (final candidate in [...candidates, ..._pathCandidates()]) {
      if (FileSystemEntity.isFileSync(candidate)) return candidate;
    }
    return null;
  }

  /// The path to run. Throws [MissingHostToolException] when there is none.
  String require() {
    final found = find();
    if (found != null) return found;
    throw MissingHostToolException(
      'Could not find $name, which is needed to $purpose.\n'
      'Tried:\n$_tried\n'
      '$remedy',
    );
  }

  /// The search as the message reports it: specific locations one per line,
  /// then PATH as a whole. Enumerating every PATH entry would bury the
  /// specific locations, which are the actual hint.
  String get _tried {
    final entries = _pathEntries();
    return [
      for (final candidate in candidates) '  $candidate',
      if (pathNames.isNotEmpty)
        '  ${pathNames.join(' / ')} on PATH'
            '${entries.isEmpty ? ' (PATH is empty)' : ''}',
    ].join('\n');
  }

  List<String> _pathEntries() {
    // Windows environment lookups are case-insensitive; a `Map` handed in by a
    // test is not, so both spellings are read.
    final path = _environment['PATH'] ?? _environment['Path'] ?? '';
    return [
      for (final entry in path.split(Platform.isWindows ? ';' : ':'))
        if (entry.isNotEmpty) entry,
    ];
  }

  List<String> _pathCandidates() => [
    for (final entry in _pathEntries())
      for (final name in pathNames) p.join(entry, _exeName(name)),
  ];
}

/// The `adb` that installs the APK, starts the activity and carries logcat.
HostTool adbTool({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  return HostTool(
    name: 'adb',
    purpose:
        'install the app on an Android device, start it, and read its '
        'logs',
    candidates: [
      for (final sdk in androidSdkRoots(env))
        p.join(sdk, 'platform-tools', _exeName('adb')),
    ],
    remedy: _androidSdkRemedy(
      env,
      component: 'the platform-tools package',
      sdkmanagerPackage: 'platform-tools',
    ),
    environment: env,
  );
}

/// The `aapt2` that reads an APK's package name and launchable activity.
///
/// Every installed build-tools version is a candidate, newest first: newest is
/// the right one to read a current APK with, and naming them all makes the
/// diagnostic show what is actually installed rather than what was expected.
HostTool aapt2Tool({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  return HostTool(
    name: 'aapt2',
    purpose: 'read the package name and launchable activity out of the APK',
    candidates: [
      for (final sdk in androidSdkRoots(env))
        for (final version in buildToolsVersions(sdk))
          p.join(sdk, 'build-tools', version, _exeName('aapt2')),
    ],
    remedy: _androidSdkRemedy(
      env,
      component: 'the build-tools package',
      sdkmanagerPackage: 'build-tools;35.0.0',
    ),
    environment: env,
  );
}

/// The debugger a physical iOS device needs before its engine will start.
HostTool lldbTool({Map<String, String>? environment}) => HostTool(
  name: 'lldb',
  purpose:
      'attach a debugger, without which a debug build will not run on '
      'a physical iOS device',
  remedy:
      'lldb ships with the Xcode command line tools: install them with '
      '`xcode-select --install`.',
  environment: environment,
);

/// The usbmuxd port forwarder a *wired* iOS device's VM service is reached
/// through. A wirelessly attached device is dialed at its own address and needs
/// no forward — see `IOSDevice.requiredHostTools`.
HostTool iproxyTool({Map<String, String>? environment}) => HostTool(
  name: 'iproxy',
  purpose: 'forward the Dart VM service port off a cabled iOS device',
  remedy:
      'iproxy comes with libimobiledevice: `brew install '
      'libimobiledevice`.',
  environment: environment,
);

/// The browser a web run opens the app in.
HostTool chromeTool({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final override = env['CHROME_EXECUTABLE'];
  return HostTool(
    name: 'Chrome',
    purpose: 'run the app in a browser',
    candidates: [
      if (override != null && override.isNotEmpty) override,
      if (Platform.isMacOS)
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      if (Platform.isWindows) ...[
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
      ],
    ],
    // Only Linux ships Chrome as something on PATH; on macOS and Windows it is
    // an installed application, and a PATH hit there would be a different
    // program with a similar name.
    pathNames: Platform.isLinux
        ? const ['google-chrome', 'chromium-browser']
        : const [],
    remedy:
        'Install Google Chrome, point CHROME_EXECUTABLE at it, or run on a '
        'desktop device (-d macos / -d linux / -d windows).',
    environment: env,
  );
}

/// Android SDK roots to search, most authoritative first.
///
/// Both env vars are the SDK's own conventions and this repo's Android builds
/// already require one of them (see README). The macOS path after them is where
/// Android Studio installs by default, and is what makes the common setup work
/// with nothing exported; no equivalent guess is made elsewhere, because on
/// those platforms an unset variable is better reported than guessed around.
List<String> androidSdkRoots(Map<String, String> environment) {
  final roots = <String>[];
  for (final key in const ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
    final value = environment[key];
    if (value != null && value.isNotEmpty) roots.add(value);
  }
  final home = environment['HOME'];
  if (Platform.isMacOS && home != null && home.isNotEmpty) {
    roots.add(p.join(home, 'Library', 'Android', 'sdk'));
  }
  return roots;
}

/// Installed `build-tools/<version>` directory names, newest first.
///
/// Ordered by numeric segment rather than lexically: `9.0.0` sorts *after*
/// `34.0.0` as a string, which would have picked a decade-old aapt2 over the
/// current one.
List<String> buildToolsVersions(String sdkRoot) {
  final dir = Directory(p.join(sdkRoot, 'build-tools'));
  if (!dir.existsSync()) return const [];
  final versions =
      dir
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .toList()
        ..sort((a, b) => _compareVersions(b, a));
  return versions;
}

int _compareVersions(String a, String b) {
  final left = _versionSegments(a);
  final right = _versionSegments(b);
  for (var i = 0; i < left.length || i < right.length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l.compareTo(r);
  }
  // Same numbers: `34.0.0-rc1` is not `34.0.0`, and a stable name sorts first
  // because the string with nothing appended is shorter.
  return b.length.compareTo(a.length);
}

List<int> _versionSegments(String version) => [
  for (final part in version.split(RegExp(r'[.\-]'))) int.tryParse(part) ?? 0,
];

String _androidSdkRemedy(
  Map<String, String> environment, {
  required String component,
  required String sdkmanagerPackage,
}) {
  final roots = androidSdkRoots(environment);
  if (roots.isEmpty) {
    return 'Neither ANDROID_HOME nor ANDROID_SDK_ROOT is set. Point one at '
        'your Android SDK root (Android Studio installs it at '
        '~/Library/Android/sdk on macOS, ~/Android/Sdk on Linux) with '
        '$component installed, or put the binary on PATH.';
  }
  return 'The Android SDK is ${roots.first} (ANDROID_HOME/ANDROID_SDK_ROOT), '
      'but $component is not installed there: add it from Android Studio\'s '
      'SDK Manager or with `sdkmanager "$sdkmanagerPackage"`, or put the '
      'binary on PATH.';
}

String _exeName(String name) =>
    Platform.isWindows && p.extension(name).isEmpty ? '$name.exe' : name;
