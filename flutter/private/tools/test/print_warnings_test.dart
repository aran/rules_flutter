import 'dart:io';

import 'package:test/test.dart';

import '../print_warnings.dart';

void main() {
  late Directory temp;
  late String stamp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('print_warnings_test');
    stamp = '${temp.path}/warnings.stamp';
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('prints each warning as given, and writes the stamp', () {
    final err = StringBuffer();
    const warning =
        'Package fed:android references fed_android:android as the default '
        'plugin, but the package does not exist, or is not a plugin package.\n'
        'Ask the maintainers of fed to either avoid referencing a default '
        'implementation via `platforms: android: default_package: '
        'fed_android` or create a plugin named fed_android.\n';
    printWarnings(['--warning', warning, '--stamp', stamp], err);
    expect(err.toString(), warning);
    expect(File(stamp).existsSync(), isTrue);
  });

  test('ends each warning with a newline', () {
    final err = StringBuffer();
    printWarnings(
      ['--stamp', stamp, '--warning', 'one', '--warning', 'two\n'],
      err,
    );
    expect(err.toString(), 'one\ntwo\n');
  });

  test('prints nothing without warnings', () {
    final err = StringBuffer();
    printWarnings(['--stamp', stamp], err);
    expect(err.toString(), isEmpty);
    expect(File(stamp).existsSync(), isTrue);
  });

  test('refuses an unknown argument', () {
    expect(
      () => printWarnings(['--stamp', stamp, '--wat', 'x'], StringBuffer()),
      throwsArgumentError,
    );
  });
}
