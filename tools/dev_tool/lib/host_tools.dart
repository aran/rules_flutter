/// Locating the external programs the dev tool drives.
///
/// The dev tool shells out to binaries it does not own: `lldb` for a physical
/// iOS device, and Chrome. They belong to the user's machine, so searching
/// their conventional locations and PATH is legitimate — *guessing* is not.
/// Some it runs are not the machine's: Flutter's own `iproxy`, which the tool
/// carries in its runfiles as flutter_tools carries it in its cache, and the
/// Android SDK's `adb` and `aapt2`, which the workspace builds (see
/// `android_sdk.dart`).
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

import 'runfiles_helper.dart';

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
    final tried = _tried;
    throw MissingHostToolException(
      'Could not find $name, which is needed to $purpose.\n'
      '${tried.isEmpty ? '' : 'Tried:\n$tried\n'}'
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

/// Where Flutter's iproxy is in the dev tool's runfiles
/// (`@flutter_ios_usb//:iproxy`).
const iproxyRunfile = 'flutter_ios_usb/libusbmuxd/iproxy';

/// The directories of the libraries iproxy loads, beside its own in
/// `@flutter_ios_usb`: the archives flutter_tools puts on its
/// `DYLD_LIBRARY_PATH` for it (`IosUsbArtifacts`).
const _iproxyLibraryDirs = ['libusbmuxd', 'libplist', 'libimobiledeviceglue'];

/// The usbmuxd port forwarder a *wired* iOS device's VM service is reached
/// through: Flutter's own build, which the dev tool carries, never one on
/// PATH. A wirelessly attached device is dialed at its own address and needs
/// no forward — see `IOSDevice.requiredHostTools`.
HostTool iproxyTool() {
  final carried = resolveRunfile(iproxyRunfile);
  return HostTool(
    name: 'iproxy',
    purpose: 'forward the Dart VM service port off a cabled iOS device',
    candidates: [?carried],
    pathNames: const [],
    remedy: hasRunfilesContext
        ? "flutter_bazel carries Flutter's own iproxy in its runfiles, as "
              '$iproxyRunfile, and this build of it has none: it dropped a '
              'declared data dependency. Rebuild it with `bazel build '
              '@rules_flutter//tools/dev_tool:flutter_bazel` on macOS.'
        : "flutter_bazel carries Flutter's own iproxy in its runfiles, and "
              'this one is not running from any. Run it with `bazel run '
              '@rules_flutter//tools/dev_tool:flutter_bazel`.',
  );
}

/// The environment iproxy at [executable] runs with: its libraries' directories
/// on `DYLD_LIBRARY_PATH`, found from its real path, since runfiles hold only
/// links to the files.
Map<String, String> iproxyEnvironment(String executable) {
  final root = p.dirname(
    p.dirname(File(executable).resolveSymbolicLinksSync()),
  );
  return {
    'DYLD_LIBRARY_PATH': [
      for (final dir in _iproxyLibraryDirs) p.join(root, dir),
    ].join(':'),
  };
}

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

String _exeName(String name) =>
    Platform.isWindows && p.extension(name).isEmpty ? '$name.exe' : name;
