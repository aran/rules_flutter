/// Whether a captured screenshot has anything drawn in it.
///
/// This is the assertion every screenshot e2e rests on — "the UI rendered" —
/// and a PNG byte count cannot express it. PNG filters and compresses each
/// scanline separately, so a blank image pays for every row however empty it
/// is, and the size an empty frame reaches grows with the screen.
///
/// The images here are built rather than checked in, so a uniform capture can
/// be encoded at real screen dimensions and measured. Building them also
/// exercises all five PNG scanline filters, which a captured fixture cannot —
/// a device emits whichever its encoder chose.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_bazel_dev_tool/runfiles_helper.dart';
import 'package:test/test.dart';

import 'e2e/dev_tool_e2e_harness.dart';

/// Encode [pixels] (row-major, [channels] bytes each) as a PNG whose every
/// scanline uses [filter].
///
/// A deliberately literal encoder: it exists to feed the decoder input it did
/// not produce itself, so it does the filtering by hand rather than sharing
/// any of the decoder's arithmetic.
Uint8List encodePng(
  List<int> pixels, {
  required int width,
  required int height,
  required int channels,
  int filter = 0,
}) {
  final stride = width * channels;
  final raw = BytesBuilder();
  var previous = Uint8List(stride);
  for (var row = 0; row < height; row++) {
    final line = Uint8List.fromList(
      pixels.sublist(row * stride, (row + 1) * stride),
    );
    final encoded = Uint8List(stride);
    for (var i = 0; i < stride; i++) {
      final a = i >= channels ? line[i - channels] : 0;
      final b = previous[i];
      final c = i >= channels ? previous[i - channels] : 0;
      encoded[i] =
          switch (filter) {
            0 => line[i],
            1 => line[i] - a,
            2 => line[i] - b,
            3 => line[i] - ((a + b) >> 1),
            4 => line[i] - _paethRef(a, b, c),
            _ => throw ArgumentError('no filter $filter'),
          } &
          0xff;
    }
    raw.addByte(filter);
    raw.add(encoded);
    previous = line;
  }

  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> body) {
    final length = ByteData(4)..setUint32(0, body.length);
    out.add(length.buffer.asUint8List());
    out.add(ascii.encode(type));
    out.add(body);
    out.add(const [0, 0, 0, 0]); // CRC: the decoder does not check it.
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, channels == 4 ? 6 : 2) // colour type
    ..setUint8(10, 0) // compression
    ..setUint8(11, 0) // filter method
    ..setUint8(12, 0); // interlace
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', ZLibEncoder().convert(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

int _paethRef(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

/// A [width]x[height] image of one repeated pixel.
List<int> uniform(int width, int height, List<int> pixel) => List.generate(
  width * height * pixel.length,
  (i) => pixel[i % pixel.length],
);

void main() {
  group('why a byte threshold is not enough', () {
    test('a blank phone-sized capture is far over 4 KB', () {
      // A blank 1080x2400 RGBA capture encodes to well over 4 KB, so size
      // alone cannot tell it apart from a rendered frame.
      final blank = encodePng(
        uniform(1080, 2400, [0, 0, 0, 0]),
        width: 1080,
        height: 2400,
        channels: 4,
      );
      expect(
        blank.length,
        greaterThan(4 * 1024),
        reason: 'a blank capture defeats a 4 KB threshold, which is the bug',
      );
      // And the pixel check is not fooled.
      expect(decodePngForBlankness(blank).isUniform, isTrue);
    });

    test('a small capture with content in it is not blank', () {
      // Size cuts the other way too: a 393x660 capture is small enough that a
      // rendered one can land near 2 KB, so byte count answers the wrong
      // question in both directions. Pixels answer it in neither.
      final drawn = <int>[
        ...uniform(393, 330, [255, 255, 255, 255]),
        ...uniform(393, 330, [16, 32, 48, 255]),
      ];
      final png = encodePng(drawn, width: 393, height: 660, channels: 4);
      expect(decodePngForBlankness(png).isUniform, isFalse);
    });
  });

  // The generated images above share their filter arithmetic with the
  // decoder — this file's encoder is a deliberate mirror of it — so a
  // symmetric bug in the Paeth or Average predictor would cancel in the
  // round trip and every one of those tests would still pass. This one
  // cannot cancel: the bytes were produced by `adb exec-out screencap -p`
  // on an Android emulator.
  // Tagged `runfiles`: alone in this file, these read a fixture declared in the
  // target's `data`, so they need the Bazel runfiles tree and cannot pass under
  // a bare `dart test`. The rest of the file builds its images in memory and
  // runs either way, so the tag sits on this group rather than the file.
  group(
    'the real capture that defeated the byte threshold',
    tags: 'runfiles',
    () {
      late List<int> bytes;

      setUp(() {
        const key =
            'rules_flutter/tools/dev_tool/test/fixtures/'
            'blank_android_emulator_capture.png';
        final path = resolveRunfile(key);
        if (path == null) {
          throw StateError(
            'Could not resolve $key from runfiles. This test reads a captured '
            'PNG declared in its `data`, so it needs the Bazel runfiles tree: '
            'run it with `bazel test //tools/dev_tool:screenshot_blankness_test`.',
          );
        }
        bytes = File(path).readAsBytesSync();
      });

      test('is 10,195 bytes and therefore passed a 4 KB threshold', () {
        expect(bytes.length, 10195);
        expect(bytes.length, greaterThan(4 * 1024));
      });

      test('is seen as blank once the pixels are read', () {
        final png = decodePngForBlankness(bytes);
        expect((png.width, png.height), (1080, 2400));
        expect(png.isUniform, isTrue);
      });

      test('fails expectRendered', () {
        expect(
          () => expectRendered(bytes, what: 'the emulator capture'),
          throwsA(isA<TestFailure>()),
        );
      });
    },
  );

  group('decoding', () {
    test('reads every PNG scanline filter', () {
      // One filter per row would be the realistic case, but a whole image in
      // each is what isolates a wrong predictor: Paeth and Average both look
      // right on the first row, where the row above is all zeroes.
      for (var filter = 0; filter <= 4; filter++) {
        final pixels = <int>[];
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            pixels.addAll([x * 30, y * 30, (x + y) * 15, 255]);
          }
        }
        final png = encodePng(
          pixels,
          width: 8,
          height: 8,
          channels: 4,
          filter: filter,
        );
        expect(
          decodePngForBlankness(png).isUniform,
          isFalse,
          reason: 'filter $filter',
        );
      }
    });

    test('a uniform image stays uniform through every filter', () {
      // The half that matters: an un-filter bug that invents variation turns
      // a blank capture into a passing test, which is the failure this whole
      // file exists to stop.
      for (var filter = 0; filter <= 4; filter++) {
        final png = encodePng(
          uniform(32, 32, [7, 7, 7, 255]),
          width: 32,
          height: 32,
          channels: 4,
          filter: filter,
        );
        expect(
          decodePngForBlankness(png).isUniform,
          isTrue,
          reason: 'filter $filter',
        );
      }
    });

    test('reads RGB as well as RGBA', () {
      // `scrot` and some CDP captures have no alpha channel.
      final png = encodePng(
        uniform(4, 4, [1, 2, 3]),
        width: 4,
        height: 4,
        channels: 3,
      );
      final decoded = decodePngForBlankness(png);
      expect((decoded.width, decoded.height), (4, 4));
      expect(decoded.isUniform, isTrue);
    });

    test('refuses an envelope it does not read, rather than guessing', () {
      // A decoder that waves through what it cannot actually parse gives an
      // answer that looks authoritative and is not.
      final png = encodePng(
        uniform(4, 4, [1, 2, 3, 4]),
        width: 4,
        height: 4,
        channels: 4,
      );
      final interlaced = Uint8List.fromList(png);
      // IHDR body starts at 8 (signature) + 8 (length+type); interlace is its
      // 13th byte.
      interlaced[8 + 8 + 12] = 1;
      expect(
        () => decodePngForBlankness(interlaced),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('interlace 1'), contains('guessing')),
          ),
        ),
      );
    });

    test('refuses something that is not a PNG at all', () {
      expect(
        () => decodePngForBlankness(ascii.encode('<html>not a png</html>')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Not a PNG'),
          ),
        ),
      );
    });
  });

  group('expectRendered', () {
    test('names the capture and says what a blank one means', () {
      try {
        expectRendered(
          encodePng(
            uniform(64, 64, [0, 0, 0, 0]),
            width: 64,
            height: 64,
            channels: 4,
          ),
          what: 'the plugin_android capture',
        );
        fail('should have thrown');
      } on TestFailure catch (e) {
        expect(e.message, contains('the plugin_android capture'));
        expect(e.message, contains('64x64'));
        // The reason a reader needs, not just the verdict.
        expect(e.message, contains('failed to register'));
      }
    });

    test('passes a capture with something in it', () {
      expect(
        () => expectRendered(
          encodePng(
            [
              ...uniform(8, 4, [255, 255, 255, 255]),
              ...uniform(8, 4, [0, 0, 0, 255]),
            ],
            width: 8,
            height: 8,
            channels: 4,
          ),
          what: 'a drawn capture',
        ),
        returnsNormally,
      );
    });
  });
}
