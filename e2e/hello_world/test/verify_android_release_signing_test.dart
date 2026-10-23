/// Release signing of the overlay APK with the caller's own keystore.
///
/// `:hello_world_android_release_signed` signs with `testdata/release.p12`
/// (a throwaway PKCS#12 fixture, password file `testdata/release.pass`)
/// instead of the debug keystore. The test reads the APK Signing Block of
/// both that APK and the debug-signed `:hello_world_android`, extracts each
/// first signer certificate (scheme v3, id `0xf05368c0`, else scheme v2, id
/// `0x7109871a`), and asserts the release certificate's SHA-256 equals the
/// fixture certificate's pinned fingerprint while the debug certificate
/// differs — proving the APK was signed by the fixture key and not the
/// debug key.
///
/// The block is parsed by hand: no `apksigner` or `keytool` runs here.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifacts to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

// SHA-256 of the DER certificate inside testdata/release.p12, printed when
// the fixture was generated and pinned here.
const _releaseFingerprint =
    '0f07e36f86ce25676df4f914555b13d83826f3f69ad9e6dd871a344ad01d944d';

const _v2Id = 0x7109871a;
const _v3Id = 0xf05368c0;

class _Reader {
  _Reader(this.data, this.pos);
  final Uint8List data;
  int pos;

  int u16() {
    final value = ByteData.sublistView(data).getUint16(pos, Endian.little);
    pos += 2;
    return value;
  }

  int u32() {
    final value = ByteData.sublistView(data).getUint32(pos, Endian.little);
    pos += 4;
    return value;
  }

  int u64() {
    final value = ByteData.sublistView(data).getUint64(pos, Endian.little);
    pos += 8;
    return value;
  }

  Uint8List bytes(int length) {
    final value = data.sublist(pos, pos + length);
    pos += length;
    return value;
  }

  Uint8List block() => bytes(u32());
}

/// Reads and discards one length-prefixed block from [reader].
void _skipBlock(_Reader reader) {
  reader.block();
}

/// First signer certificate (DER) inside a v2/v3 scheme value.
///
/// v3 signers are length-prefixed (signed data, min/max SDK, signatures,
/// public key); v2 signers are not (signed data, signatures, public key sit
/// directly under the signer count). Either way the signed data opens with
/// digest records over the APK contents, followed by the certificate list
/// whose first entry is the signer's certificate.
Uint8List _firstSignerCert(
  Uint8List scheme, {
  required bool lengthPrefixedSigner,
}) {
  final reader = _Reader(scheme, 0);
  if (reader.u32() < 1) {
    stderr.writeln('FAIL: signing block holds no signers');
    exit(1);
  }
  final signer = lengthPrefixedSigner ? _Reader(reader.block(), 0) : reader;
  final signedData = _Reader(signer.block(), 0);
  _skipBlock(signedData); // Digest records, skipped by length.
  final certs = _Reader(signedData.block(), 0);
  return certs.block(); // First certificate, DER.
}

Uint8List _signerCertOf(String apkPath) {
  final bytes = File(apkPath).readAsBytesSync();
  final view = ByteData.sublistView(bytes);
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (view.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) {
    stderr.writeln('FAIL: $apkPath has no End of Central Directory');
    exit(1);
  }
  final centralOffset = view.getUint32(eocd + 16, Endian.little);
  const magic = 'APK Sig Block 42';
  var blockEnd = -1;
  for (var i = centralOffset - 16; i >= 0; i--) {
    var match = true;
    for (var j = 0; j < magic.length; j++) {
      if (bytes[i + j] != magic.codeUnitAt(j)) {
        match = false;
        break;
      }
    }
    if (match) {
      blockEnd = i;
      break;
    }
  }
  if (blockEnd < 0) {
    stderr.writeln('FAIL: $apkPath has no APK Signing Block');
    exit(1);
  }
  final reader = _Reader(bytes, blockEnd - 8);
  final size = reader.u64();
  // The trailing size covers the pairs, itself and the magic, so the pairs
  // start 16 bytes (magic) past blockStart + 8 (leading size).
  reader.pos = blockEnd - size + 16;
  String? scheme;
  Uint8List? cert;
  while (reader.pos < blockEnd - 8) {
    final pairSize = reader.u64();
    final id = reader.u32();
    final value = reader.bytes(pairSize - 4);
    if (id == _v3Id) {
      scheme = 'v3';
      cert = _firstSignerCert(value, lengthPrefixedSigner: true);
    } else if (id == _v2Id && cert == null) {
      scheme = 'v2';
      cert = _firstSignerCert(value, lengthPrefixedSigner: false);
    }
  }
  if (cert == null) {
    stderr.writeln('FAIL: $apkPath Signing Block has no v2/v3 scheme');
    exit(1);
  }
  print('OK: $apkPath signed under scheme $scheme');
  return cert;
}

int _rotr(int value, int bits) =>
    ((value >> bits) | (value << (32 - bits))) & 0xffffffff;

String _sha256Hex(Uint8List data) {
  const k = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  final padded = [...data, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  final bitLength = data.length * 8;
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLength >> (i * 8)) & 0xff);
  }

  for (var offset = 0; offset < padded.length; offset += 64) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      w[i] =
          (padded[offset + i * 4] << 24) |
          (padded[offset + i * 4 + 1] << 16) |
          (padded[offset + i * 4 + 2] << 8) |
          padded[offset + i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var (a, b, c, d, e, f, g, h) = (h0, h1, h2, h3, h4, h5, h6, h7);
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (h + s1 + ch + k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
    h5 = (h5 + f) & 0xffffffff;
    h6 = (h6 + g) & 0xffffffff;
    h7 = (h7 + h) & 0xffffffff;
  }

  final out = ByteData(32);
  final words = [h0, h1, h2, h3, h4, h5, h6, h7];
  for (var i = 0; i < words.length; i++) {
    out.setUint32(i * 4, words[i]);
  }
  return out.buffer
      .asUint8List()
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final base = '$testSrcDir/$testWorkspace';

  final releaseApk = '$base/hello_world_android_release_signed.apk';
  final debugApk = '$base/hello_world_android.apk';
  for (final apk in [releaseApk, debugApk]) {
    if (!File(apk).existsSync()) {
      stderr.writeln('APK not found at $apk');
      exit(1);
    }
  }

  final releaseFingerprint = _sha256Hex(_signerCertOf(releaseApk));
  final debugFingerprint = _sha256Hex(_signerCertOf(debugApk));
  print('release signer SHA-256: $releaseFingerprint');
  print('debug signer SHA-256:   $debugFingerprint');

  var failed = false;
  void check(String description, bool condition, String detail) {
    if (condition) {
      print('OK: $description');
    } else {
      stderr.writeln('FAIL: $description — $detail');
      failed = true;
    }
  }

  check(
    'release signer is the fixture certificate',
    releaseFingerprint == _releaseFingerprint,
    'got $releaseFingerprint, want $_releaseFingerprint',
  );
  check(
    'release signer is not the debug keystore',
    releaseFingerprint != debugFingerprint,
    'both APKs share signer $releaseFingerprint',
  );

  if (failed) exit(1);
  print('PASS');
}
