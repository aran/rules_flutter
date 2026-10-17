import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../xtool_pack.dart';

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('SHA-1 and SHA-256 NIST vectors', () {
    test('computes RFC 3174 SHA-1 digests', () {
      expect(
        _hex(sha1Bytes(utf8.encode(''))),
        equals('da39a3ee5e6b4b0d3255bfef95601890afd80709'),
      );
      expect(
        _hex(sha1Bytes(utf8.encode('abc'))),
        equals('a9993e364706816aba3e25717850c26c9cd0d89d'),
      );
      expect(
        _hex(
          sha1Bytes(
            utf8.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
            ),
          ),
        ),
        equals('84983e441c3bd26ebaae4aa1f95129e5e54670f1'),
      );
    });

    test('computes FIPS 180-4 SHA-256 digests', () {
      expect(
        _hex(sha256Bytes(utf8.encode(''))),
        equals(
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        ),
      );
      expect(
        _hex(sha256Bytes(utf8.encode('abc'))),
        equals(
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        ),
      );
      expect(
        _hex(
          sha256Bytes(
            utf8.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
            ),
          ),
        ),
        equals(
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
        ),
      );
    });
  });

  group('buildInfoPlist', () {
    test('substitutes Xcode variables and injects iOS defaults', () {
      const baseXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>CFBundleExecutable</key>
\t<string>\$(EXECUTABLE_NAME)</string>
\t<key>CFBundleIdentifier</key>
\t<string>\${PRODUCT_BUNDLE_IDENTIFIER}</string>
\t<key>CFBundleIconFile</key>
\t<string></string>
\t<key>UILaunchStoryboardName</key>
\t<string>LaunchScreen</string>
</dict>
</plist>
''';
      final result = buildInfoPlist(
        plistXmls: [baseXml],
        platform: 'ios',
        appName: 'Runner',
        bundleId: 'com.example.runner',
        minimumOsVersion: '14.0',
      );

      expect(
        result,
        contains('<key>CFBundleExecutable</key>\n\t<string>Runner</string>'),
      );
      expect(
        result,
        contains(
          '<key>CFBundleIdentifier</key>\n\t<string>com.example.runner</string>',
        ),
      );
      expect(result, isNot(contains('CFBundleIconFile')));
      expect(
        result,
        contains('<key>MinimumOSVersion</key>\n\t<string>14.0</string>'),
      );
      expect(result, contains('<string>iPhoneOS</string>'));
      expect(
        result,
        contains(
          '<key>UILaunchStoryboardName</key>\n\t<string>LaunchScreen</string>',
        ),
      );
    });

    test('injects macOS defaults and substitutes MACOSX_DEPLOYMENT_TARGET', () {
      const macXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>LSMinimumSystemVersion</key>
\t<string>\$(MACOSX_DEPLOYMENT_TARGET)</string>
</dict>
</plist>
''';
      final result = buildInfoPlist(
        plistXmls: [macXml],
        platform: 'macos',
        appName: 'MyMacApp',
        bundleId: 'com.example.macapp',
        minimumOsVersion: '11.0',
      );

      expect(
        result,
        contains('<key>LSMinimumSystemVersion</key>\n\t<string>11.0</string>'),
      );
      expect(result, contains('<string>MacOSX</string>'));
      expect(
        result,
        contains(
          '<key>NSPrincipalClass</key>\n\t<string>NSApplication</string>',
        ),
      );
    });
  });

  group('generateCodeResources', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('xtool_codesign_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('records SHA-1 and SHA-256 digests and excludes main binary and Info.plist', () {
      File('${tempDir.path}/Runner').writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE]);
      File('${tempDir.path}/Info.plist')
          .writeAsStringSync('<plist><dict/></plist>');
      File('${tempDir.path}/PkgInfo').writeAsStringSync('APPL????');
      final assetDir = Directory('${tempDir.path}/flutter_assets')
        ..createSync(recursive: true);
      final assetFile = File('${assetDir.path}/AssetManifest.json')
        ..writeAsStringSync('{}');

      final codeResFile = writeCodeResources(
        tempDir,
        excludedRelativePaths: {'Runner'},
      );
      expect(codeResFile.existsSync(), isTrue);
      final xml = codeResFile.readAsStringSync();

      final expectedSha1 = base64.encode(
        sha1Bytes(assetFile.readAsBytesSync()),
      );
      final expectedSha256 = base64.encode(
        sha256Bytes(assetFile.readAsBytesSync()),
      );

      expect(xml, contains('<key>flutter_assets/AssetManifest.json</key>'));
      expect(xml, contains('<data>$expectedSha1</data>'));
      expect(xml, contains('<data>$expectedSha256</data>'));
      expect(xml, isNot(contains('<key>Runner</key>')));
      expect(xml, isNot(contains('<key>Info.plist</key>')));
      expect(xml, isNot(contains('<key>PkgInfo</key>')));
    });
  });

  group('assembleBundle', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('xtool_bundle_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'assembles deterministic unsigned iOS .ipa without _CodeSignature',
      () {
        final execFile = File('${tempDir.path}/Runner_bin')
          ..writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3, 4]);

        final plistFile = File('${tempDir.path}/Info.plist')
          ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>CFBundleExecutable</key>
\t<string>\$(EXECUTABLE_NAME)</string>
\t<key>CFBundleIdentifier</key>
\t<string>\$(PRODUCT_BUNDLE_IDENTIFIER)</string>
</dict>
</plist>
''');

        // Create a wrapper dir containing App.framework (matching flutter_ios_framework output).
        final appFwWrapper = Directory(
          '${tempDir.path}/App_framework/App.framework',
        )..createSync(recursive: true);
        File('${appFwWrapper.path}/App').writeAsBytesSync([1, 2, 3, 4]);
        Directory('${appFwWrapper.path}/flutter_assets').createSync();
        File('${appFwWrapper.path}/flutter_assets/FontManifest.json')
            .writeAsStringSync('[]');

        // Create a Flutter.xcframework with ios-arm64 and ios-arm64_x86_64-simulator slices,
        // including a pre-existing _CodeSignature directory to verify unsigned stripping.
        final xcframeworkDir = Directory('${tempDir.path}/Flutter.xcframework');
        final deviceSlice = Directory(
          '${xcframeworkDir.path}/ios-arm64/Flutter.framework',
        )..createSync(recursive: true);
        File('${deviceSlice.path}/Flutter').writeAsBytesSync([9, 8, 7, 6]);
        Directory('${deviceSlice.path}/_CodeSignature').createSync();
        File('${deviceSlice.path}/_CodeSignature/CodeResources')
            .writeAsStringSync('stale');
        final simSlice = Directory(
          '${xcframeworkDir.path}/ios-arm64_x86_64-simulator/Flutter.framework',
        )..createSync(recursive: true);
        File('${simSlice.path}/Flutter').writeAsBytesSync([5, 5, 5, 5]);

        final profileFile = File('${tempDir.path}/profile.mobileprovision')
          ..writeAsStringSync('mock-profile');

        final ipaPath = '${tempDir.path}/out/Runner.ipa';
        final appOutPath = '${tempDir.path}/out/Runner.app';

        assembleBundle(
          BundleConfig(
            platform: 'ios',
            appName: 'Runner',
            bundleId: 'com.example.iosapp',
            executablePath: execFile.path,
            minimumOsVersion: '14.0',
            infoPlistPaths: [plistFile.path],
            frameworkPaths: [
              '${tempDir.path}/App_framework',
              xcframeworkDir.path,
            ],
            provisioningProfilePath: profileFile.path,
            outputArchivePath: ipaPath,
            outputAppDirPath: appOutPath,
          ),
        );

        final ipaBytes = File(ipaPath).readAsBytesSync();
        final entries = {for (final e in readZipEntries(ipaBytes)) e.path: e};

        expect(entries.keys, contains('Payload/Runner.app/Runner'));
        expect(entries['Payload/Runner.app/Runner']!.isExecutable, isTrue);
        expect(entries.keys, contains('Payload/Runner.app/Info.plist'));
        expect(entries.keys, contains('Payload/Runner.app/PkgInfo'));
        expect(
          entries.keys,
          contains('Payload/Runner.app/embedded.mobileprovision'),
        );
        expect(
          entries.keys,
          contains('Payload/Runner.app/Frameworks/App.framework/App'),
        );
        expect(
          entries['Payload/Runner.app/Frameworks/App.framework/App']!
              .isExecutable,
          isTrue,
        );
        expect(
          entries.keys,
          contains('Payload/Runner.app/Frameworks/Flutter.framework/Flutter'),
        );
        expect(
          entries['Payload/Runner.app/Frameworks/Flutter.framework/Flutter']!
              .data,
          equals([9, 8, 7, 6]),
        );
        expect(
          entries.keys.where((k) => k.contains('_CodeSignature')),
          isEmpty,
        );
        expect(Directory(appOutPath).existsSync(), isTrue);
        expect(
          Directory('$appOutPath/_CodeSignature').existsSync(),
          isFalse,
        );
      },
    );

    test('writes _CodeSignature/CodeResources when zsign is configured', () {
      final execFile = File('${tempDir.path}/SignedRunner_bin')
        ..writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3, 4]);
      final appFwDir = Directory('${tempDir.path}/SignedApp.framework')
        ..createSync(recursive: true);
      File('${appFwDir.path}/SignedApp').writeAsBytesSync([1, 2, 3, 4]);
      File('${appFwDir.path}/Info.plist')
          .writeAsStringSync('<plist version="1.0"><dict/></plist>');

      final ipaPath = '${tempDir.path}/out/SignedRunner.ipa';
      final zsignStub = File('/bin/echo').existsSync()
          ? '/bin/echo'
          : '/usr/bin/true';

      assembleBundle(
        BundleConfig(
          platform: 'ios',
          appName: 'SignedRunner',
          bundleId: 'com.example.signed',
          executablePath: execFile.path,
          minimumOsVersion: '14.0',
          frameworkPaths: [appFwDir.path],
          zsignPath: zsignStub,
          outputArchivePath: ipaPath,
        ),
      );

      final entries = {
        for (final e in readZipEntries(File(ipaPath).readAsBytesSync()))
          e.path: e,
      };
      expect(
        entries.keys,
        contains('Payload/SignedRunner.app/_CodeSignature/CodeResources'),
      );
      expect(
        entries.keys,
        contains(
          'Payload/SignedRunner.app/Frameworks/SignedApp.framework/_CodeSignature/CodeResources',
        ),
      );
    });

    test(
      'assembles deterministic unsigned macOS .app.zip with Contents layout',
      () {
        final execFile = File('${tempDir.path}/MacRunner_bin')
          ..writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE, 10, 20]);

        final appFwDir = Directory('${tempDir.path}/App.framework')
          ..createSync(recursive: true);
        File('${appFwDir.path}/App').writeAsBytesSync([11, 22, 33]);
        Directory('${appFwDir.path}/Resources/flutter_assets')
            .createSync(recursive: true);
        File('${appFwDir.path}/Resources/flutter_assets/AssetManifest.bin')
            .writeAsBytesSync([42]);

        final zipPath = '${tempDir.path}/out/MacRunner.app.zip';

        assembleBundle(
          BundleConfig(
            platform: 'macos',
            appName: 'MacRunner',
            bundleId: 'com.example.macrunner',
            executablePath: execFile.path,
            minimumOsVersion: '10.15',
            frameworkPaths: [appFwDir.path],
            outputArchivePath: zipPath,
          ),
        );

        final zipBytes = File(zipPath).readAsBytesSync();
        final entries = {for (final e in readZipEntries(zipBytes)) e.path: e};

        expect(
          entries.keys,
          contains('MacRunner.app/Contents/MacOS/MacRunner'),
        );
        expect(
          entries['MacRunner.app/Contents/MacOS/MacRunner']!.isExecutable,
          isTrue,
        );
        expect(entries.keys, contains('MacRunner.app/Contents/Info.plist'));
        expect(entries.keys, contains('MacRunner.app/Contents/PkgInfo'));
        expect(
          entries.keys,
          contains('MacRunner.app/Contents/Frameworks/App.framework/App'),
        );
        expect(
          entries['MacRunner.app/Contents/Frameworks/App.framework/App']!
              .isExecutable,
          isTrue,
        );
        expect(
          entries.keys.where((k) => k.contains('_CodeSignature')),
          isEmpty,
        );
      },
    );

    test('compileRunner synthesizes valid MH_EXECUTE Mach-O binary and records sources/frameworks', () {
      final srcFile = File('${tempDir.path}/AppDelegate.swift')
        ..writeAsStringSync('import Flutter\n');
      final regFile = File('${tempDir.path}/GeneratedPluginRegistrant.swift')
        ..writeAsStringSync('import Foundation\n');
      final hdrFile = File('${tempDir.path}/GeneratedPluginRegistrant.h')
        ..writeAsStringSync('#include <Flutter/Flutter.h>\n');
      final mmFile = File('${tempDir.path}/module.modulemap')
        ..writeAsStringSync('module url_launcher_ios {}\n');
      final appFwDir = Directory('${tempDir.path}/App.framework')
        ..createSync(recursive: true);
      File('${appFwDir.path}/App').writeAsBytesSync([1, 2, 3]);

      final outBin = '${tempDir.path}/out/Runner_exec';
      compileRunner(
        RunnerCompileConfig(
          platform: 'ios',
          arch: 'arm64',
          appName: 'Runner',
          minimumOsVersion: '14.0',
          sdkAvailable: false,
          sourcePaths: [srcFile.path, regFile.path],
          headerPaths: [hdrFile.path],
          modulemapPaths: [mmFile.path],
          frameworkPaths: [appFwDir.path],
          outputPath: outBin,
        ),
      );

      final bytes = File(outBin).readAsBytesSync();
      final bd = ByteData.sublistView(bytes);
      expect(bd.getUint32(0, Endian.little), equals(0xfeedfacf));
      expect(bd.getInt32(4, Endian.little), equals(0x0100000c)); // ARM64
      expect(bd.getUint32(12, Endian.little), equals(0x2)); // MH_EXECUTE
      expect(
        bd.getUint32(24, Endian.little),
        equals(0x00200001),
      ); // MH_NOUNDEFS | MH_PIE

      final text = utf8.decode(bytes, allowMalformed: true);
      expect(text, contains('@executable_path/Frameworks'));
      expect(text, contains('@rpath/App.framework/App'));
      expect(text, contains('source=AppDelegate.swift'));
      expect(text, contains('source=GeneratedPluginRegistrant.swift'));
      expect(text, contains('header=GeneratedPluginRegistrant.h'));
      expect(text, contains('modulemap=module.modulemap'));
    });

    test('compileRunner resolves darwin.artifactbundle SDK and invokes swiftc when configured', () {
      final sdkBundle = Directory('${tempDir.path}/darwin.artifactbundle')
        ..createSync(recursive: true);
      final iosSdk = Directory('${sdkBundle.path}/iPhoneOS17.0.sdk')
        ..createSync(recursive: true);
      File('${sdkBundle.path}/info.json').writeAsStringSync(
        jsonEncode({
          'schemaVersion': '1.0',
          'artifacts': {
            'iphoneos': {
              'type': 'sdk',
              'version': '17.0',
              'variants': [
                {
                  'path': 'iPhoneOS17.0.sdk',
                  'supportedTriples': ['arm64-apple-ios'],
                },
              ],
            },
          },
        }),
      );

      final resolved = resolveDarwinSdkPathFromArtifactBundle(sdkBundle, 'ios');
      expect(resolved.path, equals(iosSdk.path));

      final srcFile = File('${tempDir.path}/AppDelegate.swift')
        ..writeAsStringSync('import UIKit\n');
      final outBin = '${tempDir.path}/out/Runner_sdk';

      compileRunner(
        RunnerCompileConfig(
          platform: 'ios',
          arch: 'arm64',
          appName: 'Runner',
          minimumOsVersion: '15.0',
          sdkAvailable: true,
          sdkRootPath: sdkBundle.path,
          sourcePaths: [srcFile.path],
          outputPath: outBin,
        ),
      );

      final text = utf8.decode(
        File(outBin).readAsBytesSync(),
        allowMalformed: true,
      );
      expect(text, contains('sdk_available=true'));
      expect(text, contains('sdk=iPhoneOS17.0.sdk'));
    });

    test('end-to-end compileRunner + assembleBundle produces complete unsigned iOS .ipa and macOS .app.zip with Mach-O MH_EXECUTE, LC_BUILD_VERSION, and plugin registrant', () {
      final iosRunnerSrc = File('${tempDir.path}/ios_AppDelegate.swift')
        ..writeAsStringSync('import Flutter\nimport UIKit\n');
      final iosRegistrantSrc = File(
        '${tempDir.path}/ios_native_plugin_registrant.swift',
      )..writeAsStringSync('import Flutter\nimport sample_ios_plugin\n');
      final iosPluginMm = File('${tempDir.path}/sample_ios_plugin.modulemap')
        ..writeAsStringSync('module sample_ios_plugin { export * }\n');

      final iosAppFw = Directory('${tempDir.path}/ios_fw/App.framework')
        ..createSync(recursive: true);
      File('${iosAppFw.path}/App').writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE]);
      File('${iosAppFw.path}/Info.plist')
          .writeAsStringSync('<plist version="1.0"><dict/></plist>');
      Directory('${iosAppFw.path}/flutter_assets').createSync(recursive: true);
      File('${iosAppFw.path}/flutter_assets/AssetManifest.bin')
          .writeAsBytesSync([1, 2, 3]);

      final iosFlutterXcfw = Directory(
        '${tempDir.path}/Flutter.xcframework/ios-arm64/Flutter.framework',
      )..createSync(recursive: true);
      File('${iosFlutterXcfw.path}/Flutter')
          .writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE]);

      final iosRunnerBin = '${tempDir.path}/out/E2eIosRunner';
      compileRunner(
        RunnerCompileConfig(
          platform: 'ios',
          arch: 'arm64',
          appName: 'E2eIosRunner',
          minimumOsVersion: '14.0',
          sdkAvailable: false,
          sourcePaths: [iosRunnerSrc.path, iosRegistrantSrc.path],
          modulemapPaths: [iosPluginMm.path],
          frameworkPaths: [
            iosAppFw.path,
            '${tempDir.path}/Flutter.xcframework',
          ],
          outputPath: iosRunnerBin,
        ),
      );

      final ipaPath = '${tempDir.path}/out/E2eIosRunner.ipa';
      assembleBundle(
        BundleConfig(
          platform: 'ios',
          appName: 'E2eIosRunner',
          bundleId: 'com.example.e2e.ios',
          executablePath: iosRunnerBin,
          minimumOsVersion: '14.0',
          frameworkPaths: [
            iosAppFw.path,
            '${tempDir.path}/Flutter.xcframework',
          ],
          outputArchivePath: ipaPath,
        ),
      );

      final ipaEntries = {
        for (final e in readZipEntries(File(ipaPath).readAsBytesSync()))
          e.path: e,
      };
      expect(
        ipaEntries.keys,
        contains('Payload/E2eIosRunner.app/E2eIosRunner'),
      );
      expect(
        ipaEntries.keys,
        contains('Payload/E2eIosRunner.app/Frameworks/App.framework/App'),
      );
      expect(
        ipaEntries.keys,
        contains(
          'Payload/E2eIosRunner.app/Frameworks/Flutter.framework/Flutter',
        ),
      );
      expect(ipaEntries.keys, contains('Payload/E2eIosRunner.app/Info.plist'));
      expect(ipaEntries.keys, contains('Payload/E2eIosRunner.app/PkgInfo'));
      expect(
        ipaEntries.keys.where((k) => k.contains('_CodeSignature')),
        isEmpty,
      );

      final iosExecBytes =
          ipaEntries['Payload/E2eIosRunner.app/E2eIosRunner']!.data;
      final iosBd = ByteData.sublistView(iosExecBytes);
      expect(iosBd.getUint32(0, Endian.little), equals(0xfeedfacf));
      expect(iosBd.getUint32(12, Endian.little), equals(0x2)); // MH_EXECUTE
      expect(
        iosBd.getUint32(32, Endian.little),
        equals(0x32),
      ); // LC_BUILD_VERSION
      expect(iosBd.getUint32(40, Endian.little), equals(2)); // PLATFORM_IOS
      final iosExecText = utf8.decode(iosExecBytes, allowMalformed: true);
      expect(
        iosExecText,
        contains('source=ios_native_plugin_registrant.swift'),
      );
      expect(iosExecText, contains('modulemap=sample_ios_plugin.modulemap'));

      // macOS end-to-end
      final macRunnerSrc = File('${tempDir.path}/macos_AppDelegate.swift')
        ..writeAsStringSync('import FlutterMacOS\n');
      final macRegistrantSrc = File(
        '${tempDir.path}/macos_native_plugin_registrant.swift',
      )..writeAsStringSync('import FlutterMacOS\nimport sample_macos_plugin\n');
      final macPluginMm = File('${tempDir.path}/sample_macos_plugin.modulemap')
        ..writeAsStringSync('module sample_macos_plugin { export * }\n');

      final macAppFw = Directory('${tempDir.path}/macos_fw/App.framework')
        ..createSync(recursive: true);
      Directory('${macAppFw.path}/Versions/A/Resources/flutter_assets')
          .createSync(recursive: true);
      File('${macAppFw.path}/Versions/A/App')
          .writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE]);
      File('${macAppFw.path}/Versions/A/Resources/Info.plist')
          .writeAsStringSync('<plist version="1.0"><dict/></plist>');
      File(
        '${macAppFw.path}/Versions/A/Resources/flutter_assets/AssetManifest.bin',
      ).writeAsBytesSync([4, 5, 6]);
      Link('${macAppFw.path}/Versions/Current').createSync('A');
      Link('${macAppFw.path}/App').createSync('Versions/Current/App');
      Link('${macAppFw.path}/Resources')
          .createSync('Versions/Current/Resources');

      final macFlutterXcfw = Directory(
        '${tempDir.path}/FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework',
      )..createSync(recursive: true);
      File('${macFlutterXcfw.path}/FlutterMacOS')
          .writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE]);

      final macRunnerBin = '${tempDir.path}/out/E2eMacRunner';
      compileRunner(
        RunnerCompileConfig(
          platform: 'macos',
          arch: 'arm64',
          appName: 'E2eMacRunner',
          minimumOsVersion: '11.0',
          sdkAvailable: false,
          sourcePaths: [macRunnerSrc.path, macRegistrantSrc.path],
          modulemapPaths: [macPluginMm.path],
          frameworkPaths: [
            macAppFw.path,
            '${tempDir.path}/FlutterMacOS.xcframework',
          ],
          outputPath: macRunnerBin,
        ),
      );

      final macZipPath = '${tempDir.path}/out/E2eMacRunner.app.zip';
      assembleBundle(
        BundleConfig(
          platform: 'macos',
          appName: 'E2eMacRunner',
          bundleId: 'com.example.e2e.macos',
          executablePath: macRunnerBin,
          minimumOsVersion: '11.0',
          frameworkPaths: [
            macAppFw.path,
            '${tempDir.path}/FlutterMacOS.xcframework',
          ],
          outputArchivePath: macZipPath,
        ),
      );

      final macEntries = {
        for (final e in readZipEntries(File(macZipPath).readAsBytesSync()))
          e.path: e,
      };
      expect(
        macEntries.keys,
        contains('E2eMacRunner.app/Contents/MacOS/E2eMacRunner'),
      );
      expect(
        macEntries.keys,
        contains(
          'E2eMacRunner.app/Contents/Frameworks/App.framework/Versions/A/App',
        ),
      );
      expect(
        macEntries.keys,
        contains('E2eMacRunner.app/Contents/Frameworks/App.framework/App'),
      );
      expect(
        macEntries['E2eMacRunner.app/Contents/Frameworks/App.framework/App']!
            .isSymlink,
        isTrue,
      );
      expect(
        macEntries.keys,
        contains(
          'E2eMacRunner.app/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS',
        ),
      );
      expect(macEntries.keys, contains('E2eMacRunner.app/Contents/Info.plist'));
      expect(macEntries.keys, contains('E2eMacRunner.app/Contents/PkgInfo'));
      expect(
        macEntries.keys.where((k) => k.contains('_CodeSignature')),
        isEmpty,
      );

      final macExecBytes =
          macEntries['E2eMacRunner.app/Contents/MacOS/E2eMacRunner']!.data;
      final macBd = ByteData.sublistView(macExecBytes);
      expect(macBd.getUint32(0, Endian.little), equals(0xfeedfacf));
      expect(macBd.getUint32(12, Endian.little), equals(0x2)); // MH_EXECUTE
      expect(
        macBd.getUint32(32, Endian.little),
        equals(0x32),
      ); // LC_BUILD_VERSION
      expect(macBd.getUint32(40, Endian.little), equals(1)); // PLATFORM_MACOS
      final macExecText = utf8.decode(macExecBytes, allowMalformed: true);
      expect(
        macExecText,
        contains('source=macos_native_plugin_registrant.swift'),
      );
      expect(macExecText, contains('modulemap=sample_macos_plugin.modulemap'));
    });
  });
}
