/// Getting a native hot patch to where a running app can load it.
///
/// A patch is built on this machine and loaded inside the app, and between the
/// two sit the device's rules: a sandboxed container on macOS and iOS, a
/// separate filesystem behind devicectl or adb on a phone, and on an iOS device
/// a code signature the kernel checks before `dlopen` maps a single page. Each
/// device answers two questions here — where the app finds the library it
/// patches, and how a file reaches the directory the app said it can load from.
///
/// The directory itself is the app's answer, not this file's (see
/// `ext.rules_flutter.nativePatchDirectory`): where an app may write and load
/// from is a fact about its sandbox that only the app knows without guessing.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'dev_tool_exception.dart';
import 'temp_dir.dart';

/// Runs a process to completion. Injected so tests see every command.
typedef DeliveryProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// How a native hot patch reaches one kind of device.
abstract class NativePatchDelivery {
  const NativePatchDelivery();

  /// This delivery, for the app the native hot patch build's [files] describe.
  ///
  /// Where a platform needs more of the build than a library's file name to
  /// find it. Only iOS does: its libraries ship in frameworks the build names
  /// (see [IosFrameworks]).
  NativePatchDelivery forBuild(Iterable<String> files) => this;

  /// The path the app opens [libraryFileName] by — the name of a bundled native
  /// library as its build wrote it (`libbridge.dylib`, `libbridge.so`).
  ///
  /// Opening a library the process already has returns that same image, which
  /// is the point: this is how the app finds the running copy, not a second one.
  String libraryLoadPath(String libraryFileName);

  /// Make [localFile] loadable by the app as [name] inside [appDirectory], and
  /// return the path the app loads it by.
  ///
  /// [name] must be new for every patch: a loader asked to open a path it has
  /// already opened hands back the image it already has, and the new code would
  /// never run.
  Future<String> deliver({
    required String localFile,
    required String appDirectory,
    required String name,
  });
}

/// A failure to deliver, naming the step and what the tool said.
class NativePatchDeliveryException implements Exception {
  final String message;

  const NativePatchDeliveryException(this.message);

  @override
  String toString() => message;
}

Future<ProcessResult> _require(
  DeliveryProcessRunner run,
  String what,
  String executable,
  List<String> arguments,
) async {
  final result = await run(executable, arguments);
  if (result.exitCode != 0) {
    throw NativePatchDeliveryException(
      'Could not $what: `$executable ${arguments.join(' ')}` exited '
              '${result.exitCode}.\n${'${result.stderr}'.trim()}'
          .trim(),
    );
  }
  return result;
}

/// A macOS app: the dev tool and the app share a filesystem, and the app's
/// container is a directory this user can write to.
class MacOSPatchDelivery extends NativePatchDelivery {
  const MacOSPatchDelivery();

  /// `native_deps` land in `Contents/Frameworks`, which is what the app's rpath
  /// names; `@executable_path` is resolved by dyld itself, so this holds
  /// wherever the bundle was launched from.
  @override
  String libraryLoadPath(String libraryFileName) =>
      '@executable_path/../Frameworks/$libraryFileName';

  @override
  Future<String> deliver({
    required String localFile,
    required String appDirectory,
    required String name,
  }) async {
    final destination = p.join(appDirectory, name);
    await File(localFile).copy(destination);
    return destination;
  }
}

/// The framework each native library of an iOS app ships in, by the library's
/// file name: `libbridge.dylib` ships as `bridge.framework/bridge`, because
/// iOS refuses loose dylibs.
///
/// The build names them (`ios_framework_names` in
/// `flutter/private/flutter_native_assets.bzl`, which renames a framework whose
/// name another library's took, as flutter_tools does) and writes them to
/// [fileName], which the hot patch aspect's group carries.
class IosFrameworks {
  /// The framework names by library file name.
  final Map<String, String> byFileName;

  const IosFrameworks(this.byFileName);

  /// None: a delivery not yet told the build.
  static const none = IosFrameworks({});

  /// The name of the file the build writes them to.
  static const fileName = 'rules_flutter_ios_frameworks.json';

  /// The framework names in a build's [files]: every [fileName] among them.
  static IosFrameworks ofBuild(Iterable<String> files) => read([
    for (final f in files)
      if (p.basename(f) == fileName) f,
  ]);

  /// The framework names of [files], every [fileName] a build wrote: one per
  /// iOS app it reached. Throws [DevToolException] when two name one library's
  /// framework differently, since the dev tool could not tell which runs.
  static IosFrameworks read(Iterable<String> files) {
    final names = <String, String>{};
    final from = <String, String>{};
    for (final path in files) {
      final decoded = json.decode(File(path).readAsStringSync()) as Map;
      for (final MapEntry(:key, :value) in decoded.entries) {
        final library = key as String;
        final framework = value as String;
        final other = names[library];
        if (other != null && other != framework) {
          throw DevToolException(
            '$library ships as $other.framework by ${from[library]} and as '
            '$framework.framework by $path, so the dev tool cannot tell which '
            'the running app has, and native edits to it need a hot restart.',
          );
        }
        names[library] = framework;
        from[library] = path;
      }
    }
    return IosFrameworks(names);
  }

  /// The framework [libraryFileName] ships in, or null when the build named
  /// none for it: a library this iOS app does not bundle.
  String? of(String libraryFileName) => byFileName[libraryFileName];
}

String _iosLoadPath(String libraryFileName, IosFrameworks frameworks) {
  final framework = frameworks.of(libraryFileName);
  if (framework == null) {
    throw DevToolException(
      'The build names no framework for $libraryFileName in the iOS app, so '
      'the dev tool cannot open the running copy of it.',
    );
  }
  return '@executable_path/Frameworks/$framework.framework/$framework';
}

/// An app on an iOS simulator: its data container is a directory on this
/// machine, and the simulator loads ad-hoc signed code.
class IOSSimulatorPatchDelivery extends NativePatchDelivery {
  final DeliveryProcessRunner _run;

  /// The framework each library ships in, as the build named them.
  final IosFrameworks frameworks;

  const IOSSimulatorPatchDelivery({
    required DeliveryProcessRunner run,
    this.frameworks = IosFrameworks.none,
  }) : _run = run;

  @override
  IOSSimulatorPatchDelivery forBuild(Iterable<String> files) =>
      IOSSimulatorPatchDelivery(
        run: _run,
        frameworks: IosFrameworks.ofBuild(files),
      );

  @override
  String libraryLoadPath(String libraryFileName) =>
      _iosLoadPath(libraryFileName, frameworks);

  @override
  Future<String> deliver({
    required String localFile,
    required String appDirectory,
    required String name,
  }) async {
    final destination = p.join(appDirectory, name);
    await File(localFile).copy(destination);
    await _require(_run, 'sign the patch for the simulator', 'codesign', [
      '--force',
      '--sign',
      '-',
      destination,
    ]);
    return destination;
  }
}

/// An app on a physical iOS device: a patch must carry a signature from the
/// same team as the app, or the kernel refuses to map it ("missing code
/// signature"), and it reaches the app's container through devicectl.
class IOSDevicePatchDelivery extends NativePatchDelivery {
  final String udid;
  final String bundleId;

  /// The installed `.app` on this machine, whose signing certificate the patch
  /// is signed with.
  final String appPath;

  final DeliveryProcessRunner _run;

  /// The framework each library ships in, as the build named them.
  final IosFrameworks frameworks;

  String? _identity;

  IOSDevicePatchDelivery({
    required this.udid,
    required this.bundleId,
    required this.appPath,
    required DeliveryProcessRunner run,
    this.frameworks = IosFrameworks.none,
  }) : _run = run;

  @override
  IOSDevicePatchDelivery forBuild(Iterable<String> files) =>
      IOSDevicePatchDelivery(
        udid: udid,
        bundleId: bundleId,
        appPath: appPath,
        run: _run,
        frameworks: IosFrameworks.ofBuild(files),
      );

  @override
  String libraryLoadPath(String libraryFileName) =>
      _iosLoadPath(libraryFileName, frameworks);

  @override
  Future<String> deliver({
    required String localFile,
    required String appDirectory,
    required String name,
  }) async {
    final relative = containerRelative(appDirectory);
    final identity = _identity ??= await _signingIdentity();
    return withTempDir('flutter_ios_patch_', (dir) async {
      final signed = p.join(dir.path, name);
      await File(localFile).copy(signed);
      await _require(
        _run,
        'sign the patch with the app\'s identity',
        'codesign',
        [
          '--force',
          '--sign',
          identity,
          signed,
        ],
      );
      await _require(_run, 'copy the patch onto the device', 'xcrun', [
        'devicectl',
        'device',
        'copy',
        'to',
        '--device',
        udid,
        '--domain-type',
        'appDataContainer',
        '--domain-identifier',
        bundleId,
        '--source',
        signed,
        '--destination',
        '$relative/$name',
      ]);
      return '$appDirectory/$name';
    });
  }

  /// [appDirectory] relative to the app's data container, which is what
  /// devicectl addresses a copy by.
  static String containerRelative(String appDirectory) {
    final match = RegExp(
      r'/Containers/Data/Application/[^/]+/(.+)$',
    ).firstMatch(appDirectory);
    if (match == null) {
      throw NativePatchDeliveryException(
        'The app reported $appDirectory as its patch directory, which is not '
        'inside an iOS app data container, so devicectl cannot copy to it.',
      );
    }
    return match.group(1)!;
  }

  /// The SHA-1 of the certificate that signed the app.
  ///
  /// A hash rather than the certificate's name: a keychain that holds a renewed
  /// certificate beside an expired one has two identities with the same name,
  /// and `codesign` refuses the ambiguous one.
  Future<String> _signingIdentity() => withTempDir('flutter_ios_cert_', (
    dir,
  ) async {
    final prefix = p.join(dir.path, 'cert');
    await _require(_run, 'read the app\'s signing certificate', 'codesign', [
      '--display',
      '--extract-certificates=$prefix',
      appPath,
    ]);
    final leaf = '${prefix}0';
    if (!File(leaf).existsSync()) {
      throw NativePatchDeliveryException(
        '$appPath carries no signing certificate, so there is no identity to '
        'sign a patch with, and the device would refuse an unsigned one.',
      );
    }
    final digest = await _require(
      _run,
      'hash the app\'s signing certificate',
      'shasum',
      [
        '-a',
        '1',
        leaf,
      ],
    );
    return '${digest.stdout}'.trim().split(RegExp(r'\s+')).first.toUpperCase();
  });
}

/// An app on an Android device or emulator: its data directory is private to
/// its uid, so a patch goes to adb's scratch directory and the app's own uid
/// copies it in (`run-as`, which every debuggable app allows).
class AndroidPatchDelivery extends NativePatchDelivery {
  final String packageName;

  /// adb's arguments up to the command, device selection included.
  final List<String> adbPrefix;
  final String adb;
  final DeliveryProcessRunner _run;

  const AndroidPatchDelivery({
    required this.packageName,
    required this.adb,
    required this.adbPrefix,
    required DeliveryProcessRunner run,
  }) : _run = run;

  /// The name alone: bionic finds a library the app already loaded by its
  /// soname, wherever the package manager extracted it.
  @override
  String libraryLoadPath(String libraryFileName) => libraryFileName;

  @override
  Future<String> deliver({
    required String localFile,
    required String appDirectory,
    required String name,
  }) async {
    final staged = '/data/local/tmp/$name';
    final destination = '$appDirectory/$name';
    await _require(_run, 'push the patch to the device', adb, [
      ...adbPrefix,
      'push',
      localFile,
      staged,
    ]);
    try {
      await _require(_run, 'copy the patch into the app', adb, [
        ...adbPrefix,
        'shell',
        'run-as',
        packageName,
        'cp',
        staged,
        destination,
      ]);
    } finally {
      await _run(adb, [...adbPrefix, 'shell', 'rm', '-f', staged]);
    }
    return destination;
  }
}
