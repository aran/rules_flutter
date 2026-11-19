/// Checks the xcframeworks of Apple add-to-app against what `flutter build
/// ios-framework` and `macos-framework` make.
///
/// Usage: `add_to_app_apple_test --platform=P --mode=M --plugins=A,B
/// --code-assets=C TARGET`, `P` `ios` or `macos`, `M` `debug`, `profile` or
/// `release`, `TARGET` the name of a `flutter_ios_xcframeworks` or
/// `flutter_macos_xcframeworks` in the test's runfiles. The test runs its
/// `bazel run` program, which writes `<Mode>/` of the mode only, its
/// xcframeworks, and above it the registrant's sources (and on iOS in debug
/// the LLDB files), as `flutter build ios-framework` lays them out, and
/// checks what it wrote.
///
///
/// Properties, per xcframework:
///
/// * `App.xcframework`: a slice per library identifier of its `Info.plist`
///   (iOS: the device and the simulator; macOS: arm64). The device or macOS
///   binary is the AOT snapshot in profile and release, with its dSYM in
///   `dSYMs/`, and a stub without one in debug, the kernel and VM snapshots
///   then in `flutter_assets/`. The iOS simulator slice is a debug build in
///   every mode. Every binary's install name is `@rpath/App.framework/App`,
///   and it is built for its platform. A macOS framework is versioned, its
///   links in place.
/// * One xcframework per plugin of `--plugins` (and no other), each slice a
///   framework of the plugin's own code: its binary links Flutter at
///   `@rpath` and holds none of it, and has the framework's install name.
///   Its module compiles: an Objective-C file that `@import`s every plugin,
///   and a Swift file that `import`s every plugin with a Swift interface,
///   type-check against each slice.
/// * One xcframework per code asset of `--code-assets`: on iOS a framework
///   per slice, on macOS the library itself.
/// * Each profile or release slice of a plugin or code asset has a dSYM of
///   its binary in `dSYMs/`, as `flutter build ios-framework` makes one; a
///   debug slice, the iOS simulator's in every mode, has none. A code
///   asset's binary is stripped of its local symbols and debugging map, as
///   upstream strips it; a plugin's is not. With `--line-tables=true` (a
///   build in `-c opt`, whose links keep their debugging maps, with
///   `--apple_generate_dsym`, which compiles with debug information), each
///   dSYM has DWARF compile units, and each plugin's binary still has its
///   map.
/// * iOS: `FlutterPluginRegistrant.xcframework`, a static framework that
///   defines `GeneratedPluginRegistrant` and none of the plugins it
///   registers, and the `GeneratedPluginRegistrant.h` and `.m` beside it.
/// * The Swift package of the mode, as `flutter build swift-package` writes
///   it: `FlutterPluginRegistrant` links to the mode, SwiftPM reads its
///   manifest, and every xcframework is a binary target of it.
/// * With `--signed=true`, every xcframework's signature verifies as the
///   export wrote it; Flutter's engine keeps Flutter's, the others are
///   signed (ad hoc). Without, only Flutter's engine is signed.
/// * `Flutter.xcframework` and `FlutterMacOS.xcframework`: Flutter's
///   signature verifies, so the copy is byte for byte and link for link the
///   one Flutter signed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/add_to_app.dart';
import 'package:rules_flutter_e2e_testing/plist.dart';

final _failures = <String>[];

void _check(bool ok, String message) {
  if (!ok) _failures.add(message);
}

String _run(String executable, List<String> args) {
  final result = Process.runSync(executable, args);
  if (result.exitCode != 0) {
    _failures.add('$executable ${args.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout.toString();
}

/// The `LC_BUILD_VERSION` platform number of [binary]: 1 macOS, 2 iOS, 7
/// the iOS simulator.
String _platformOf(String binary) {
  final match = RegExp(
    r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\d+)',
  ).firstMatch(_run('otool', ['-l', binary]));
  return match?.group(1) ?? 'none';
}

String _installName(String binary) =>
    _run('otool', ['-D', binary]).trim().split('\n').last;

bool _hasSnapshot(String binary) =>
    _run('nm', [binary]).contains('_kDartSnapshot');

void _checkApp(String xcframework, String platform, String mode) {
  final libraries = [
    for (final l
        in Plist.read('$xcframework/Info.plist').values['AvailableLibraries']!
            as List<Object?>)
      l! as Map<String, Object?>,
  ];
  final ids = {for (final l in libraries) l['LibraryIdentifier']! as String};
  final expected = platform == 'ios'
      ? {'ios-arm64', 'ios-arm64-simulator'}
      : {'macos-arm64'};
  _check(
    ids.length == expected.length && ids.containsAll(expected),
    'App.xcframework has the slices $ids, not $expected',
  );
  for (final library in libraries) {
    final id = library['LibraryIdentifier']! as String;
    final slice = '$xcframework/$id';
    final binary = '$slice/${library['BinaryPath']}';
    final simulator = id.endsWith('-simulator');
    final debug = mode == 'debug' || simulator;
    _check(
      File(binary).existsSync(),
      '$id has no binary at ${library['BinaryPath']}',
    );
    if (!File(binary).existsSync()) continue;
    _check(
      _installName(binary) == '@rpath/App.framework/App',
      '$id: the install name of App is ${_installName(binary)}',
    );
    final want = platform == 'macos' ? '1' : (simulator ? '7' : '2');
    _check(
      _platformOf(binary) == want,
      '$id: App is built for platform ${_platformOf(binary)}, not $want',
    );
    _check(
      _hasSnapshot(binary) == !debug,
      '$id: App ${debug ? 'is not a stub' : 'has no AOT snapshot'} in $mode',
    );
    final assets = platform == 'macos'
        ? '$slice/App.framework/Versions/A/Resources/flutter_assets'
        : '$slice/App.framework/flutter_assets';
    for (final name in [
      'kernel_blob.bin',
      'vm_snapshot_data',
      'isolate_snapshot_data',
    ]) {
      _check(
        File('$assets/$name').existsSync() == debug,
        '$id: flutter_assets/$name is ${debug ? 'missing' : 'there'} in $mode',
      );
    }
    _check(
      File('$assets/AssetManifest.bin').existsSync(),
      '$id: flutter_assets has no AssetManifest.bin',
    );
    final dsym = Directory('$slice/dSYMs/App.framework.dSYM');
    _check(
      dsym.existsSync() == !debug,
      '$id: dSYMs/App.framework.dSYM is ${debug ? 'there' : 'missing'} in $mode',
    );
    _check(
      (library['DebugSymbolsPath'] == 'dSYMs') == !debug,
      '$id: Info.plist DebugSymbolsPath is ${library['DebugSymbolsPath']}',
    );
    if (platform == 'macos') _checkVersioned('$slice/App.framework', 'App');
  }
}

/// The links of a versioned framework: `Versions/Current -> A`, and the
/// binary and `Resources` through it.
void _checkVersioned(String framework, String name) {
  String? target(String path) {
    final link = Link('$framework/$path');
    return link.existsSync() ? link.targetSync() : null;
  }

  _check(
    target('Versions/Current') == 'A',
    '$framework: Versions/Current is not a link to A',
  );
  _check(
    target(name) == 'Versions/Current/$name',
    '$framework: $name is not a link into Versions/Current',
  );
  _check(
    target('Resources') == 'Versions/Current/Resources',
    '$framework: Resources is not a link into Versions/Current',
  );
}

void _checkEngine(String xcframework, String platform) {
  final result = Process.runSync('codesign', [
    '--verify',
    '--deep',
    '--strict',
    xcframework,
  ]);
  _check(
    result.exitCode == 0,
    '${xcframework.split('/').last}: Flutter signature does not verify:\n'
    '${result.stderr}',
  );
  if (platform == 'macos') {
    _checkVersioned(
      '$xcframework/macos-arm64_x86_64/FlutterMacOS.framework',
      'FlutterMacOS',
    );
  }
}

/// The library identifiers of [xcframework]'s slices, with each entry of its
/// `Info.plist`.
Map<String, Map<String, Object?>> _libraries(String xcframework) => {
  for (final l
      in Plist.read('$xcframework/Info.plist').values['AvailableLibraries']!
          as List<Object?>)
    (l! as Map<String, Object?>)['LibraryIdentifier']! as String:
        l as Map<String, Object?>,
};

/// Checks the debug information of a slice's [binary], as `flutter build
/// ios-framework` leaves it. Unless [debug], the slice's
/// `dSYMs/<bundle>.dSYM` has the binary's UUID, and DWARF compile units with
/// [lineTables]; a [stripped] binary has no debugging map and no local
/// symbols, and with [lineTables] any other keeps its map. With [debug],
/// there is no dSYM.
void _checkSymbols(
  String what,
  String slice,
  Map<String, Object?> library,
  String binary,
  String bundle, {
  required bool debug,
  required bool stripped,
  required bool lineTables,
}) {
  final symbols = !debug;
  final dsym = Directory('$slice/dSYMs/$bundle.dSYM');
  _check(
    dsym.existsSync() == symbols,
    '$what: dSYM ${symbols ? 'missing' : 'there'}',
  );
  _check(
    (library['DebugSymbolsPath'] == 'dSYMs') == symbols,
    '$what: DebugSymbolsPath is ${library['DebugSymbolsPath']}',
  );
  if (!symbols || !dsym.existsSync()) return;
  final dwarf = Directory(
    '${dsym.path}/Contents/Resources/DWARF',
  ).listSync().whereType<File>().toList();
  _check(dwarf.length == 1, '$what: the dSYM has ${dwarf.length} DWARF files');
  if (dwarf.length != 1) return;
  final units = RegExp(
    'DW_TAG_compile_unit',
  ).allMatches(_run('dwarfdump', ['--debug-info', dwarf.single.path])).length;
  if (lineTables) {
    _check(units > 0, '$what: the dSYM has no compile units');
  }
  String uuid(String path) =>
      _run('dwarfdump', ['--uuid', path]).split(' ').skip(1).first;
  _check(
    uuid(binary) == uuid(dwarf.single.path),
    '$what: the dSYM is not of the binary',
  );
  final table = _run('nm', ['-ap', binary]);
  if (!stripped) {
    if (lineTables) {
      _check(
        table.contains(' OSO '),
        '$what: the binary lost its debugging map',
      );
    }
    return;
  }
  _check(
    !table.contains(' OSO '),
    '$what: the binary keeps its debugging map',
  );
  final locals = _run(
    'nm',
    ['-m', binary],
  ).split('\n').where((l) => l.contains('(__TEXT,__text) non-external')).length;
  _check(locals == 0, '$what: the binary keeps $locals local text symbols');
}

void _checkPlugin(
  String xcframework,
  String platform,
  String mode, {
  required bool lineTables,
}) {
  final name = xcframework.split('/').last.replaceAll('.xcframework', '');
  final engine = platform == 'ios' ? 'Flutter' : 'FlutterMacOS';
  for (final MapEntry(key: id, value: library) in _libraries(
    xcframework,
  ).entries) {
    final slice = '$xcframework/$id';
    final binary = '$slice/${library['BinaryPath']}';
    final debug = mode == 'debug' || id.endsWith('-simulator');
    final versioned = platform == 'macos' ? 'Versions/A/' : '';
    _check(
      _installName(binary) == '@rpath/$name.framework/$versioned$name',
      '$name $id: install name ${_installName(binary)}',
    );
    final linked = _run('otool', ['-L', binary]);
    _check(
      linked.contains('@rpath/$engine.framework/'),
      '$name $id: does not link $engine at @rpath:\n$linked',
    );
    _check(
      !_run('nm', ['-U', binary]).contains(r'_OBJC_CLASS_$_FlutterEngine'),
      '$name $id: holds the Flutter engine',
    );
    _check(
      File('$slice/$name.framework/Modules/module.modulemap').existsSync(),
      '$name $id: no module map',
    );
    _checkSymbols(
      '$name $id in $mode',
      slice,
      library,
      binary,
      '$name.framework',
      debug: debug,
      stripped: false,
      lineTables: lineTables,
    );
    if (platform == 'macos') _checkVersioned('$slice/$name.framework', name);
  }
}

void _checkCodeAsset(
  String xcframework,
  String platform,
  String mode, {
  required bool lineTables,
}) {
  final name = xcframework.split('/').last.replaceAll('.xcframework', '');
  for (final MapEntry(key: id, value: library) in _libraries(
    xcframework,
  ).entries) {
    final binary = '$xcframework/$id/${library['BinaryPath']}';
    final want = platform == 'ios' ? '$name.framework/$name' : '$name.dylib';
    _check(
      library['BinaryPath'] == want,
      '$name $id: binary ${library['BinaryPath']}, not $want',
    );
    _checkSymbols(
      '$name $id in $mode',
      '$xcframework/$id',
      library,
      binary,
      platform == 'ios' ? '$name.framework' : '$name.dylib',
      debug: mode == 'debug' || id.endsWith('-simulator'),
      stripped: true,
      lineTables: lineTables,
    );
    if (platform == 'ios') {
      _check(
        _installName(binary) == '@rpath/$name.framework/$name',
        '$name $id: install name ${_installName(binary)}',
      );
    }
  }
}

/// Type-checks a host's use of every plugin's module against each slice:
/// Objective-C `@import`s them all, Swift `import`s those with a Swift
/// interface.
void _checkModules(
  List<String> plugins,
  String engine,
  String platform,
) {
  final dir = Directory.systemTemp.createTempSync('add_to_app_modules');
  try {
    final names = [
      for (final p in plugins) p.split('/').last.replaceAll('.xcframework', ''),
    ];
    final objc = File('${dir.path}/host.m')
      ..writeAsStringSync(
        [for (final n in names) '@import $n;'].join('\n'),
      );
    final swiftNames = names.where(
      (n) => plugins.any(
        (p) =>
            p.endsWith('/$n.xcframework') &&
            Directory(p)
                .listSync(recursive: true)
                .any((e) => e.path.endsWith('.swiftinterface')),
      ),
    );
    final swift = File('${dir.path}/host.swift')
      ..writeAsStringSync([for (final n in swiftNames) 'import $n'].join('\n'));
    final slices = platform == 'ios'
        ? {
            'ios-arm64': ('iphoneos', 'arm64-apple-ios15.0'),
            'ios-arm64-simulator': (
              'iphonesimulator',
              'arm64-apple-ios15.0-simulator',
            ),
          }
        : {'macos-arm64': ('macosx', 'arm64-apple-macos12.0')};
    final engineSlices = Directory(engine)
        .listSync()
        .whereType<Directory>()
        .where((d) => !d.path.split('/').last.startsWith('_'));
    for (final MapEntry(key: id, value: (sdk, target)) in slices.entries) {
      final engineSlice = engineSlices.firstWhere(
        (d) => id.endsWith('-simulator') == d.path.endsWith('-simulator'),
      );
      final search = [
        '-F${engineSlice.path}',
        for (final p in plugins) '-F$p/$id',
      ];
      final clang = Process.runSync('xcrun', [
        '-sdk',
        sdk,
        'clang',
        '-fmodules',
        '-fsyntax-only',
        '-target',
        target,
        ...search,
        objc.path,
      ]);
      _check(
        clang.exitCode == 0,
        '$id: an Objective-C host cannot import the plugins:\n${clang.stderr}',
      );
      final swiftc = Process.runSync('xcrun', [
        '-sdk',
        sdk,
        'swiftc',
        '-typecheck',
        '-target',
        target,
        ...search,
        swift.path,
      ]);
      _check(
        swiftc.exitCode == 0,
        '$id: a Swift host cannot import the plugins:\n${swiftc.stderr}',
      );
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void _checkRegistrant(String xcframework) {
  for (final MapEntry(key: id, value: library) in _libraries(
    xcframework,
  ).entries) {
    final binary = '$xcframework/$id/${library['BinaryPath']}';
    _check(
      _run('file', [binary]).contains('ar archive'),
      'FlutterPluginRegistrant $id: not a static archive',
    );
    final defined = _run('nm', ['-U', binary]);
    _check(
      defined.contains(r'_OBJC_CLASS_$_GeneratedPluginRegistrant'),
      'FlutterPluginRegistrant $id: does not define GeneratedPluginRegistrant',
    );
    _check(
      !defined.contains(r'_OBJC_CLASS_$_MXDMixedPlugin'),
      'FlutterPluginRegistrant $id: holds plugin code',
    );
  }
}

/// A signed layout: every xcframework's signature verifies as it was written
/// out, links made again included; Flutter's engine keeps Flutter's
/// (TeamIdentifier `S8QB4VV633`), the others are signed ad hoc. Unsigned:
/// only the engine is signed.
void _checkSignature(String xcframework, {required bool signed}) {
  final name = xcframework.split('/').last;
  final engine =
      name == 'Flutter.xcframework' || name == 'FlutterMacOS.xcframework';
  final details = Process.runSync('codesign', ['-dv', xcframework]);
  final text = details.stderr.toString();
  if (!signed && !engine) {
    _check(
      text.contains('not signed at all'),
      '$name: signed in an unsigned build',
    );
    return;
  }
  final verify = Process.runSync('codesign', [
    '--verify',
    '--deep',
    '--strict',
    xcframework,
  ]);
  _check(
    verify.exitCode == 0,
    '$name: its signature does not verify:\n${verify.stderr}',
  );
  _check(
    engine
        ? text.contains('TeamIdentifier=S8QB4VV633')
        : text.contains('adhoc'),
    '$name: signed by the wrong identity:\n$text',
  );
}

/// The Swift package: `FlutterPluginRegistrant` links to the mode, whose
/// manifest SwiftPM reads, its registrant a source target over a binary
/// target per xcframework but FlutterPluginRegistrant's, each one there.
void _checkSwiftPackage(String layout, String mode) {
  final link = Link('$layout/FlutterPluginRegistrant');
  _check(
    link.existsSync() && link.targetSync() == mode,
    'FlutterPluginRegistrant does not link to $mode',
  );
  final dumped = Process.runSync('xcrun', [
    'swift',
    'package',
    // SwiftPM cannot sandbox the manifest inside the test's sandbox.
    '--disable-sandbox',
    '--package-path',
    '$layout/FlutterPluginRegistrant',
    'dump-package',
  ]);
  _check(
    dumped.exitCode == 0,
    'SwiftPM cannot read the package:\n${dumped.stderr}',
  );
  if (dumped.exitCode != 0) return;
  final manifest = jsonDecode(dumped.stdout.toString()) as Map<String, Object?>;
  final targets = [
    for (final t in manifest['targets']! as List<Object?>)
      t! as Map<String, Object?>,
  ];
  final binaries = [
    for (final t in targets)
      if (t['type'] == 'binary') t['path']! as String,
  ];
  final onDisk = [
    for (final e in Directory('$layout/$mode').listSync())
      if (e.path.endsWith('.xcframework') &&
          !e.path.endsWith('/FlutterPluginRegistrant.xcframework'))
        e.path.split('/').last,
  ];
  _check(
    binaries.toSet().length == onDisk.length &&
        binaries.toSet().containsAll(onDisk),
    'the package binary targets are $binaries, not $onDisk',
  );
  _check(
    File(
      '$layout/$mode/Sources/FlutterPluginRegistrant/'
      'GeneratedPluginRegistrant.swift',
    ).existsSync(),
    'the package has no registrant source',
  );
}

void main(List<String> args) {
  String? platform;
  String? mode;
  var plugins = <String>{};
  var codeAssets = <String>{};
  final looseFiles = <String>{};
  final xcframeworks = <String>[];
  String? layout;
  var signed = false;
  var lineTables = false;
  for (final arg in args) {
    if (arg.startsWith('--platform=')) {
      platform = arg.substring('--platform='.length);
    } else if (arg.startsWith('--mode=')) {
      mode = arg.substring('--mode='.length);
    } else if (arg.startsWith('--signed=')) {
      signed = arg == '--signed=true';
    } else if (arg.startsWith('--line-tables=')) {
      lineTables = arg == '--line-tables=true';
    } else if (arg.startsWith('--plugins=')) {
      plugins = arg.substring('--plugins='.length).split(',').toSet();
    } else if (arg.startsWith('--code-assets=')) {
      codeAssets = arg.substring('--code-assets='.length).split(',').toSet();
    } else {
      layout = exportXcframeworks(arg);
    }
  }
  if (layout != null && mode != null) {
    final modeDirectory = mode[0].toUpperCase() + mode.substring(1);
    _checkSwiftPackage(layout, modeDirectory);
    for (final entry in Directory(layout).listSync()) {
      final name = entry.path.split('/').last;
      if (name == 'FlutterPluginRegistrant') continue;
      if (entry is! Directory) {
        looseFiles.add(name);
      } else if (name != modeDirectory) {
        _failures.add('$name/: the layout of a $mode build has no other mode');
      } else {
        for (final xcframework in Directory(entry.path).listSync()) {
          if (xcframework.path.endsWith('.xcframework')) {
            xcframeworks.add(xcframework.path);
          }
        }
      }
    }
  }
  if (platform == null || mode == null || xcframeworks.isEmpty) {
    stderr.writeln(
      'usage: --platform=<ios|macos> '
      '--mode=<debug|profile|release> <xcframework>...',
    );
    exit(64);
  }
  final found = <String>{};
  final pluginPaths = <String>[];
  String? engine;
  for (final xcframework in xcframeworks) {
    final name = xcframework.split('/').last.replaceAll('.xcframework', '');
    found.add(name);
    switch (name) {
      case 'App':
        _checkApp(xcframework, platform, mode);
      case 'FlutterPluginRegistrant' when platform == 'ios':
        _checkRegistrant(xcframework);
      case 'Flutter' || 'FlutterMacOS':
        engine = xcframework;
        _checkEngine(xcframework, platform);
      case _ when plugins.contains(name):
        pluginPaths.add(xcframework);
        _checkPlugin(xcframework, platform, mode, lineTables: lineTables);
      case _ when codeAssets.contains(name):
        _checkCodeAsset(xcframework, platform, mode, lineTables: lineTables);
      case _:
        _failures.add('$name.xcframework: not expected');
    }
  }
  final expected = {
    'App',
    if (platform == 'ios') ...{'Flutter', 'FlutterPluginRegistrant'},
    if (platform == 'macos') 'FlutterMacOS',
    ...plugins,
    ...codeAssets,
  };
  for (final name in expected.difference(found)) {
    _failures.add('$name.xcframework: missing');
  }
  final loose = platform == 'ios'
      ? {
          'GeneratedPluginRegistrant.h',
          'GeneratedPluginRegistrant.m',
          if (mode == 'debug') ...{
            'flutter_lldbinit',
            'flutter_lldb_helper.py',
          },
        }
      : {'GeneratedPluginRegistrant.swift'};
  _check(
    looseFiles.length == loose.length && looseFiles.containsAll(loose),
    'the files beside the xcframeworks are $looseFiles, not $loose',
  );
  for (final xcframework in xcframeworks) {
    _checkSignature(xcframework, signed: signed);
  }
  if (engine != null && pluginPaths.isNotEmpty) {
    _checkModules(pluginPaths, engine, platform);
  }
  if (_failures.isNotEmpty) {
    stderr.writeln(_failures.join('\n'));
    exit(1);
  }
  stdout.writeln(
    '${xcframeworks.length} $platform xcframeworks ($mode) are as '
    'upstream makes them.',
  );
}
