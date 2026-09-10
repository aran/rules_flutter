import 'dart:io';

import 'package:add_plugin/add_plugin.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:mul_plugin/mul_plugin.dart';

/// Minimal [QueryExecutorUser] so a raw drift executor can be opened without
/// generating a database class — this app is proving a native library loads,
/// not exercising drift's codegen.
class _Bootstrap extends QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

/// Opens an in-memory database and runs one query through it.
///
/// Nothing here names a native library, and nothing in this workspace's BUILD
/// files names a code asset: drift reaches `package:sqlite3`, whose native
/// code normally comes from a `hook/build.dart`, and the curated registry
/// binds rules_dart's Bazel-built libsqlite3 to that package. If the asset did
/// not reach the manifest, this throws where a bare build would have succeeded
/// and died on an unresolved symbol.
///
/// Returns `<echo>|<libVersion>`, where `echo` is `HELLO` — produced by
/// sqlite3's own `upper()` over a bound parameter, so it cannot be faked by
/// Dart-side code that never reached the library.
Future<String> _querySqlite() async {
  final executor = NativeDatabase.memory();
  await executor.ensureOpen(_Bootstrap());
  try {
    final rows = await executor.runSelect(
      'select upper(?) as echo, sqlite_version() as version;',
      const ['hello'],
    );
    final row = rows.single;
    return '${row['echo']}|${row['version']}';
  } finally {
    await executor.close();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Exercise all three native-library mechanisms and record the outcome to a
  // file in the app's temp dir: `add` binds via `@Native` asset-id resolution
  // (Native Assets pipeline), `mul` via classic `DynamicLibrary.open` at its
  // conventional path (`native_deps` pipeline), and sqlite3 via a code asset
  // the pub package carries on its own (curated-registry pipeline). The
  // runtime e2e tests (iOS simulator, macOS, Linux, Windows) read the file
  // back — a deterministic signal that all three libraries actually loaded and
  // the calls returned (more reliable than scraping log output). Success is
  // `ffi_example_result add(3,4)=7 mul(3,4)=12 sqlite=HELLO`; a load failure
  // records the error instead.
  String marker;
  int addResult;
  int mulResult;
  String sqliteVersion;
  try {
    addResult = add(3, 4);
    mulResult = mul(3, 4);
    final parts = (await _querySqlite()).split('|');
    sqliteVersion = parts[1];
    marker =
        'ffi_example_result add(3,4)=$addResult mul(3,4)=$mulResult '
        'sqlite=${parts[0]}';
  } on Object catch (e) {
    // Deliberately broad: a native library that fails to load throws an Error
    // (ArgumentError from asset-id resolution or DynamicLibrary.open), not an
    // Exception, and recording that failure in the marker file is exactly what
    // the runtime e2e tests read. Narrowing here would kill the app before the
    // marker is written, leaving the tests to time out with no diagnostic.
    addResult = -1;
    mulResult = -1;
    sqliteVersion = 'unavailable';
    marker = 'ffi_example_error $e';
  }
  try {
    File(
      '${Directory.systemTemp.path}/ffi_result.txt',
    ).writeAsStringSync(marker);
  } on FileSystemException {
    // Temp dir unavailable — the test will time out and report it.
  }
  debugPrint('$marker (sqlite3 $sqliteVersion)');

  runApp(
    MyApp(
      addResult: addResult,
      mulResult: mulResult,
      sqliteVersion: sqliteVersion,
    ),
  );
}

/// Root widget of the FFI example, displaying results from three native
/// libraries: two this workspace builds directly, and one that arrives as a
/// code asset attached to a pub package.
class MyApp extends StatelessWidget {
  /// Creates the FFI example's root widget from the values `main` computed.
  const MyApp({
    required this.addResult,
    required this.mulResult,
    required this.sqliteVersion,
    super.key,
  });

  /// Sum returned by the bundled `add` native library.
  final int addResult;

  /// Product returned by the bundled `multiply` native library.
  final int mulResult;

  /// Version string from the Bazel-built libsqlite3 that reaches the app as a
  /// code asset on `package:sqlite3`.
  final String sqliteVersion;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FFI Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('FFI Example'),
        ),
        body: Center(
          child: Text(
            '3 + 4 = $addResult\n3 × 4 = $mulResult\nsqlite3 $sqliteVersion',
            style: const TextStyle(fontSize: 32),
          ),
        ),
      ),
    );
  }
}
