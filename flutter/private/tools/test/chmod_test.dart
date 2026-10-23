// chmodFile sets POSIX mode bits without spawning a process.
import 'dart:io';

import 'package:test/test.dart';

import '../chmod.dart';

void main() {
  group('chmodFile', () {
    test('sets the exact mode bits it is given', () {
      final dir = Directory.systemTemp.createTempSync('chmod_test_');
      try {
        final file = File('${dir.path}/run.sh')
          ..writeAsStringSync('#!/bin/sh\nexit 0\n');
        chmodFile(file.path, 0x1ed);
        expect(file.statSync().mode & 0x1ff, equals(0x1ed));
        chmodFile(file.path, 0x1a4);
        expect(file.statSync().mode & 0x1ff, equals(0x1a4));
      } finally {
        dir.deleteSync(recursive: true);
      }
    }, testOn: '!windows');
  });
}
