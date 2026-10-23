import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../xtool_pack.dart';
import '../macho_edit.dart' as macho;

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
        InfoPlistRequest(
          plistXmls: [baseXml],
          platform: 'ios',
          appName: 'Runner',
          bundleId: 'com.example.runner',
          minimumOsVersion: '14.0',
        ),
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
        InfoPlistRequest(
          plistXmls: [macXml],
          platform: 'macos',
          appName: 'MyMacApp',
          bundleId: 'com.example.macapp',
          minimumOsVersion: '11.0',
        ),
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

    test(
      'macOS bundle always contains Contents/Resources with and without resources',
      () {
        final execFile = File('${tempDir.path}/ResRunner_bin')
          ..writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE, 10, 20]);

        // Resourceless bundle: Contents/Resources/ must exist both in the
        // app dir and as an explicit zip entry.
        const emptyApp = 'EmptyResRunner';
        final emptyAppDir = '${tempDir.path}/out/$emptyApp.app';
        final emptyZip = '$emptyAppDir.zip';
        assembleBundle(
          BundleConfig(
            platform: 'macos',
            appName: emptyApp,
            bundleId: 'com.example.emptyres',
            executablePath: execFile.path,
            minimumOsVersion: '10.15',
            outputArchivePath: emptyZip,
            outputAppDirPath: emptyAppDir,
          ),
        );
        expect(
          Directory('$emptyAppDir/Contents/Resources').existsSync(),
          isTrue,
        );
        final emptyEntries = {
          for (final e in readZipEntries(File(emptyZip).readAsBytesSync()))
            e.path: e,
        };
        expect(
          emptyEntries.keys,
          contains('$emptyApp.app/Contents/Resources/'),
        );

        // Bundle with one resource: the same directory plus the copied file.
        final greeting = File('${tempDir.path}/greeting.txt')
          ..writeAsStringSync('hello');
        const resApp = 'ResRunner';
        final resAppDir = '${tempDir.path}/out/$resApp.app';
        final resZip = '$resAppDir.zip';
        assembleBundle(
          BundleConfig(
            platform: 'macos',
            appName: resApp,
            bundleId: 'com.example.withres',
            executablePath: execFile.path,
            minimumOsVersion: '10.15',
            resourceSpecs: [greeting.path],
            outputArchivePath: resZip,
            outputAppDirPath: resAppDir,
          ),
        );
        expect(
          Directory('$resAppDir/Contents/Resources').existsSync(),
          isTrue,
        );
        expect(
          File('$resAppDir/Contents/Resources/greeting.txt').existsSync(),
          isTrue,
        );
        final resEntries = {
          for (final e in readZipEntries(File(resZip).readAsBytesSync()))
            e.path: e,
        };
        expect(resEntries.keys, contains('$resApp.app/Contents/Resources/'));
        expect(
          resEntries.keys,
          contains('$resApp.app/Contents/Resources/greeting.txt'),
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
      expect(macExecText, contains('@executable_path/Frameworks'));
      expect(macExecText, contains('@executable_path/../Frameworks'));
      expect(
        macExecText,
        contains('source=macos_native_plugin_registrant.swift'),
      );
      expect(macExecText, contains('modulemap=sample_macos_plugin.modulemap'));
    });

    test(
      'embeds macOS App.framework from its .framework.zip archive with real symlinks',
      () {
        // The producer (flutter_macos_framework) archives the versioned
        // layout with its own tool; build the fixture the same way so the
        // archive container matches production byte for byte in structure.
        final prodFw = Directory('${tempDir.path}/prod/App.framework')
          ..createSync(recursive: true);
        Directory('${prodFw.path}/Versions/A/Resources/flutter_assets')
            .createSync(recursive: true);
        File('${prodFw.path}/Versions/A/App')
            .writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE, 9]);
        File('${prodFw.path}/Versions/A/Resources/Info.plist')
            .writeAsStringSync('<plist version="1.0"><dict/></plist>');
        Link('${prodFw.path}/Versions/Current').createSync('A');
        Link('${prodFw.path}/App').createSync('Versions/Current/App');
        Link('${prodFw.path}/Resources')
            .createSync('Versions/Current/Resources');
        final zipBytes = macho.createFrameworkZipBytes(
          prodFw,
          archiveRootName: 'App.framework',
          executableRelPaths: {'App.framework/Versions/A/App'},
        );
        final zipPath = '${tempDir.path}/App.framework.zip';
        File(zipPath).writeAsBytesSync(zipBytes);

        final runnerBin = '${tempDir.path}/out/ZipMacRunner';
        compileRunner(
          RunnerCompileConfig(
            platform: 'macos',
            arch: 'arm64',
            appName: 'ZipMacRunner',
            minimumOsVersion: '11.0',
            sdkAvailable: false,
            frameworkPaths: [zipPath],
            outputPath: runnerBin,
          ),
        );

        final appDirPath = '${tempDir.path}/out/ZipMacRunner.app';
        final appZipPath = '$appDirPath.zip';
        assembleBundle(
          BundleConfig(
            platform: 'macos',
            appName: 'ZipMacRunner',
            bundleId: 'com.example.zip.macos',
            executablePath: runnerBin,
            minimumOsVersion: '11.0',
            frameworkPaths: [zipPath],
            outputArchivePath: appZipPath,
            outputAppDirPath: appDirPath,
          ),
        );

        // The assembled bundle on disk carries real symlinks (what codesign
        // and the layout tests inspect), not materialized directories.
        final fwDir = '$appDirPath/Contents/Frameworks/App.framework';
        expect(
          FileSystemEntity.typeSync(
            '$fwDir/Versions/Current',
            followLinks: false,
          ),
          FileSystemEntityType.link,
        );
        expect(Link('$fwDir/Versions/Current').targetSync(), 'A');
        expect(Link('$fwDir/App').targetSync(), 'Versions/Current/App');
        expect(
          Link('$fwDir/Resources').targetSync(),
          'Versions/Current/Resources',
        );
        expect(
          File('$fwDir/Versions/A/App').readAsBytesSync(),
          [0xCF, 0xFA, 0xED, 0xFE, 9],
        );

        // The outer archive preserves the links as S_IFLNK entries.
        final zipEntries = {
          for (final e in readZipEntries(File(appZipPath).readAsBytesSync()))
            e.path: e,
        };
        const prefix = 'ZipMacRunner.app/Contents/Frameworks/App.framework';
        expect(zipEntries['$prefix/Versions/Current']!.isSymlink, isTrue);
        expect(zipEntries['$prefix/App']!.isSymlink, isTrue);
        expect(zipEntries['$prefix/Resources']!.isSymlink, isTrue);
        expect(
          zipEntries['$prefix/Versions/A/App']!.isExecutable,
          isTrue,
        );
      },
    );

    test(
      'sets archive entry file modes explicitly from role and produces byte-identical output across runs',
      () {
        final run1Dir = Directory('${tempDir.path}/run1')
          ..createSync(recursive: true);
        final run2Dir = Directory('${tempDir.path}/run2')
          ..createSync(recursive: true);

        for (final dir in [run1Dir, run2Dir]) {
          final execFile =
              File(
                '${dir.path}/Runner',
              )..writeAsBytesSync(
                generateStubExecutableMachO(
                  StubRunnerSpec(
                    platform: 'ios',
                    arch: 'arm64',
                    minimumOsVersion: '14.0',
                  ),
                ),
              );
          final plistFile = File('${dir.path}/Info.plist')
            ..writeAsStringSync(
              '<plist version="1.0"><dict><key>CFBundleName</key><string>Runner</string></dict></plist>',
            );
          final resFile = File('${dir.path}/config.json')
            ..writeAsStringSync('{"hello":"world"}');
          final fwDir = Directory('${dir.path}/Plugin.framework')
            ..createSync(recursive: true);
          final fwBin = File('${fwDir.path}/Plugin')
            ..writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE]);
          final fwPlist = File('${fwDir.path}/Info.plist')
            ..writeAsStringSync('<plist version="1.0"><dict/></plist>');

          // Perturb host filesystem permissions in opposite directions between run1 and run2
          // to prove archive modes come from role rather than host stat.mode.
          if (!Platform.isWindows) {
            if (dir == run1Dir) {
              Process.runSync('chmod', ['0644', execFile.path, fwBin.path]);
              Process.runSync('chmod', [
                '0755',
                plistFile.path,
                resFile.path,
                fwPlist.path,
              ]);
            } else {
              Process.runSync('chmod', ['0755', execFile.path, fwBin.path]);
              Process.runSync('chmod', [
                '0600',
                plistFile.path,
                resFile.path,
                fwPlist.path,
              ]);
            }
          }

          assembleBundle(
            BundleConfig(
              platform: 'ios',
              appName: 'Runner',
              bundleId: 'com.example.deterministic',
              executablePath: execFile.path,
              minimumOsVersion: '14.0',
              infoPlistPaths: [plistFile.path],
              frameworkPaths: [fwDir.path],
              resourceSpecs: [resFile.path],
              outputArchivePath: '${dir.path}/Runner.ipa',
              tempDirPath: '${dir.path}/tmp',
            ),
          );
        }

        final ipa1 = File('${run1Dir.path}/Runner.ipa').readAsBytesSync();
        final ipa2 = File('${run2Dir.path}/Runner.ipa').readAsBytesSync();
        expect(ipa1, equals(ipa2));

        final entries = {for (final e in readZipEntries(ipa1)) e.path: e};
        expect(entries['Payload/Runner.app/Runner']!.isExecutable, isTrue);
        expect(
          entries['Payload/Runner.app/Frameworks/Plugin.framework/Plugin']!
              .isExecutable,
          isTrue,
        );
        expect(entries['Payload/Runner.app/Info.plist']!.isExecutable, isFalse);
        expect(entries['Payload/Runner.app/PkgInfo']!.isExecutable, isFalse);
        expect(
          entries['Payload/Runner.app/config.json']!.isExecutable,
          isFalse,
        );
        expect(
          entries['Payload/Runner.app/Frameworks/Plugin.framework/Info.plist']!
              .isExecutable,
          isFalse,
        );
      },
    );

    test(
      'honours families, versionFilePath, nativeLibPaths, and additionalContentSpecs',
      () {
        final execFile = File('${tempDir.path}/MacApp_bin')
          ..writeAsBytesSync(
            generateStubExecutableMachO(
              StubRunnerSpec(
                platform: 'macos',
                arch: 'arm64',
                minimumOsVersion: '11.0',
              ),
            ),
          );
        final versionJson = File('${tempDir.path}/version.json')
          ..writeAsStringSync(
            jsonEncode({
              'build_version': '42',
              'short_version_string': '2.3.4',
            }),
          );
        final nativeDylib = File('${tempDir.path}/libnative_asset.dylib')
          ..writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3, 4]);
        final extraHelper = File('${tempDir.path}/helper.txt')
          ..writeAsStringSync('extra-content');
        final zipOut = '${tempDir.path}/out/MacApp.app.zip';

        assembleBundle(
          BundleConfig(
            platform: 'macos',
            appName: 'MacApp',
            bundleId: 'com.example.macapp',
            executablePath: execFile.path,
            minimumOsVersion: '11.0',
            versionFilePath: versionJson.path,
            nativeLibPaths: [nativeDylib.path],
            additionalContentSpecs: ['Helpers=${extraHelper.path}'],
            outputArchivePath: zipOut,
            tempDirPath: '${tempDir.path}/tmp_mac',
          ),
        );

        final macEntries = {
          for (final e in readZipEntries(File(zipOut).readAsBytesSync()))
            e.path: e,
        };
        expect(
          macEntries.keys,
          contains('MacApp.app/Contents/Frameworks/libnative_asset.dylib'),
        );
        expect(
          macEntries['MacApp.app/Contents/Frameworks/libnative_asset.dylib']!
              .isExecutable,
          isTrue,
        );
        expect(
          macEntries.keys,
          isNot(
            contains('MacApp.app/Contents/Resources/libnative_asset.dylib'),
          ),
        );
        expect(
          macEntries.keys,
          contains('MacApp.app/Contents/Helpers/helper.txt'),
        );
        final macPlist = utf8.decode(
          macEntries['MacApp.app/Contents/Info.plist']!.data,
        );
        expect(
          macPlist,
          contains('<key>CFBundleVersion</key>\n\t<string>42</string>'),
        );
        expect(
          macPlist,
          contains(
            '<key>CFBundleShortVersionString</key>\n\t<string>2.3.4</string>',
          ),
        );

        // Verify iOS families (ipad only -> UIDeviceFamily = [2])
        final iosPlist = buildInfoPlist(
          InfoPlistRequest(
            plistXmls: const [],
            platform: 'ios',
            appName: 'PadApp',
            bundleId: 'com.example.padapp',
            minimumOsVersion: '14.0',
            families: const ['ipad'],
          ),
        );
        expect(
          iosPlist,
          contains(
            '<key>UIDeviceFamily</key>\n\t<array>\n\t\t<integer>2</integer>\n\t</array>',
          ),
        );
        expect(
          () => buildInfoPlist(
            InfoPlistRequest(
              plistXmls: const [],
              platform: 'ios',
              appName: 'BadApp',
              bundleId: 'com.example.badapp',
              minimumOsVersion: '14.0',
              families: const ['tv'],
            ),
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test(
      'reads signing password from file or env and rejects plain-text --certificate-password or uncompiled .storyboard/.xib/.xcassets resources',
      () {
        final execFile = File('${tempDir.path}/Runner_sec')
          ..writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3, 4]);
        final pwFile = File('${tempDir.path}/cert_pw.txt')
          ..writeAsStringSync('file-secret-pw\n');
        final certFile = File('${tempDir.path}/cert.p12')
          ..writeAsStringSync('mock-p12');
        final argsLog = File('${tempDir.path}/zsign_args.txt');
        final envLog = File('${tempDir.path}/zsign_env.txt');
        final fakeZsign = File('${tempDir.path}/fake_zsign.sh')
          ..writeAsStringSync(
            '#!/bin/sh\n'
            'printf "%s\\n" "\$@" > "${argsLog.path}"\n'
            'env > "${envLog.path}"\n',
          );
        if (!Platform.isWindows) {
          Process.runSync('chmod', ['0755', fakeZsign.path]);
          assembleBundle(
            BundleConfig(
              platform: 'ios',
              appName: 'Runner',
              bundleId: 'com.example.sec',
              executablePath: execFile.path,
              minimumOsVersion: '14.0',
              zsignPath: fakeZsign.path,
              certificatePath: certFile.path,
              certificatePasswordFilePath: pwFile.path,
              outputArchivePath: '${tempDir.path}/out/Sec.ipa',
              tempDirPath: '${tempDir.path}/tmp_sec',
            ),
          );
          final logged = argsLog.readAsLinesSync();
          expect(logged, contains('-p'));
          expect(logged, contains('file-secret-pw'));
          expect(
            logged.last,
            equals('${tempDir.path}/tmp_sec/stage/Payload/Runner.app'),
          );

          // Verify certificatePasswordEnv reads from declared environment and
          // does not leak parent environment variables (like TMPDIR or TEST_TMPDIR)
          // into the zsign subprocess.
          assembleBundle(
            BundleConfig(
              platform: 'macos',
              appName: 'Runner',
              bundleId: 'com.example.sec.env',
              executablePath: execFile.path,
              minimumOsVersion: '11.0',
              zsignPath: fakeZsign.path,
              certificatePath: certFile.path,
              certificatePasswordEnv: 'DECLARED_CERT_PW',
              environment: const {'DECLARED_CERT_PW': 'env-secret-pw'},
              outputArchivePath: '${tempDir.path}/out/SecEnv.app.zip',
            ),
          );
          final envLoggedArgs = argsLog.readAsLinesSync();
          expect(envLoggedArgs, contains('-p'));
          expect(envLoggedArgs, contains('env-secret-pw'));
          expect(
            envLoggedArgs.last,
            equals('${tempDir.path}/out/.xtool_pack_stage/Runner.app'),
          );
          final zsignEnvLines = envLog.readAsLinesSync();
          expect(
            zsignEnvLines.any((l) => l.startsWith('DECLARED_CERT_PW=')),
            isFalse,
          );
          expect(zsignEnvLines.any((l) => l.startsWith('TMPDIR=')), isFalse);
          expect(
            zsignEnvLines.any((l) => l.startsWith('TEST_TMPDIR=')),
            isFalse,
          );

          // Undeclared env var in BundleConfig.environment must fail even if
          // present in the host process environment.
          expect(
            () => assembleBundle(
              BundleConfig(
                platform: 'macos',
                appName: 'Runner',
                bundleId: 'com.example.sec.missing',
                executablePath: execFile.path,
                minimumOsVersion: '11.0',
                zsignPath: fakeZsign.path,
                certificatePath: certFile.path,
                certificatePasswordEnv: 'PATH',
                environment: const {},
                outputArchivePath: '${tempDir.path}/out/SecMissing.app.zip',
              ),
            ),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                contains('is not set'),
              ),
            ),
          );

          // Building the same macOS bundle from the same inputs under two
          // different temp roots (and with --isolated-env +
          // --certificate-password-env TMPDIR) must produce byte-for-byte
          // identical .app.zip archives with no temp root or TMPDIR bytes.
          final sigZsign = File('${tempDir.path}/sig_zsign.sh')
            ..writeAsStringSync('''#!/bin/sh
pw=""
prev=""
last=""
for arg in "\$@"; do
  if [ "\$prev" = "-p" ]; then
    pw="\$arg"
  fi
  prev="\$arg"
  last="\$arg"
done
mkdir -p "\$last/Contents/_CodeSignature"
printf 'pw=%s\\ntmpdir=%s\\ntest_tmpdir=%s\\n' "\$pw" "\${TMPDIR:-}" "\${TEST_TMPDIR:-}" > "\$last/Contents/_CodeSignature/CodeResources"
''');
          Process.runSync('chmod', ['+x', sigZsign.path]);

          List<int> buildUnderTempRoot(String rootName) {
            final rootDir = Directory('${tempDir.path}/$rootName')
              ..createSync(recursive: true);
            final rootExec = File('${rootDir.path}/RunnerBin')
              ..writeAsBytesSync(execFile.readAsBytesSync());
            final rootCert = File('${rootDir.path}/cert.p12')
              ..writeAsBytesSync(certFile.readAsBytesSync());
            final rootRes = File('${rootDir.path}/greeting.txt')
              ..writeAsStringSync('hello world');
            final outZip = '${rootDir.path}/out/macos_bundle.app.zip';
            final outAppDir = '${rootDir.path}/out/Runner.app';
            final cfg = parseBundleCliArgs([
              '--platform',
              'macos',
              '--app-name',
              'Runner',
              '--bundle-id',
              'com.example.repro',
              '--executable',
              rootExec.path,
              '--minimum-os-version',
              '12.0',
              '--resource',
              rootRes.path,
              '--zsign',
              sigZsign.path,
              '--certificate',
              rootCert.path,
              '--certificate-password-env',
              'TMPDIR',
              '--isolated-env',
              '--output-archive',
              outZip,
              '--output-app-dir',
              outAppDir,
            ]);
            assembleBundle(cfg);
            return File(outZip).readAsBytesSync();
          }

          final bytesRootA = buildUnderTempRoot('tmp_root_alpha_111');
          final bytesRootB = buildUnderTempRoot('tmp_root_bravo_999999');
          expect(bytesRootA, equals(bytesRootB));

          final entriesA = {
            for (final e in readZipEntries(Uint8List.fromList(bytesRootA)))
              e.path: e,
          };
          final codeResEntry =
              entriesA['Runner.app/Contents/_CodeSignature/CodeResources'];
          expect(codeResEntry, isNotNull);
          final codeResText = utf8.decode(codeResEntry!.data);
          expect(codeResText, equals('pw=\ntmpdir=\ntest_tmpdir=\n'));
          for (final entry in entriesA.values) {
            expect(entry.path, isNot(contains('tmp_root_')));
          }
        }

        // Plain-text --certificate-password on CLI must be rejected.
        expect(
          () => parseBundleCliArgs([
            '--platform',
            'ios',
            '--app-name',
            'Runner',
            '--bundle-id',
            'com.example.sec',
            '--executable',
            execFile.path,
            '--minimum-os-version',
            '14.0',
            '--certificate-password',
            'leaked',
            '--output-archive',
            '${tempDir.path}/out/Fail.ipa',
          ]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('--certificate-password is not permitted'),
            ),
          ),
        );

        // Uncompiled .storyboard / .xib / .xcassets resources must be rejected.
        for (final ext in [
          'Main.storyboard',
          'MainMenu.xib',
          'Assets.xcassets',
        ]) {
          final badRes = File('${tempDir.path}/$ext')
            ..writeAsStringSync('uncompiled');
          expect(
            () => assembleBundle(
              BundleConfig(
                platform: 'ios',
                appName: 'Runner',
                bundleId: 'com.example.badres',
                executablePath: execFile.path,
                minimumOsVersion: '14.0',
                resourceSpecs: [badRes.path],
                outputArchivePath: '${tempDir.path}/out/Bad.ipa',
                tempDirPath: '${tempDir.path}/tmp_bad',
              ),
            ),
            throwsA(isA<ArgumentError>()),
          );
        }
      },
    );

    test(
      'resolves apple_bundle_version placeholders and embeds sdkFrameworks/sdkDylibs in stub executable',
      () {
        final buildInfo = File('${tempDir.path}/volatile-status.txt')
          ..writeAsStringSync(
            'BUILD_EMBED_LABEL release_2.5.1_b99\nSTABLE_OTHER foo\n',
          );
        final outVer1 = '${tempDir.path}/out/ver1.json';
        resolveBundleVersion(
          BundleVersionRequest(
            buildVersion: '1.0.{build_number}',
            shortVersionString: '{major}.{minor}',
            buildLabelPattern:
                'release_{major}.{minor}.{patch}_b{build_number}',
            captureGroups: {
              'major': r'\d+',
              'minor': r'\d+',
              'patch': r'\d+',
              'build_number': r'\d+',
            },
            stableStatusPath: buildInfo.path,
            outputPath: outVer1,
          ),
        );
        final resolved = jsonDecode(
          File(outVer1).readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(resolved['build_version'], equals('1.0.99'));
        expect(resolved['short_version_string'], equals('2.5'));

        final outVer2 = '${tempDir.path}/out/ver2.json';
        resolveBundleVersion(
          BundleVersionRequest(
            buildVersion: '1.0.{build_number}',
            shortVersionString: '1.0',
            buildLabelPattern: 'release_{build_number}',
            captureGroups: {'build_number': r'\d+'},
            fallbackBuildLabel: 'release_77',
            outputPath: outVer2,
          ),
        );
        final fallbackResolved = jsonDecode(
          File(outVer2).readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(fallbackResolved['build_version'], equals('1.0.77'));
        expect(fallbackResolved['short_version_string'], equals('1.0'));

        final runnerOut = '${tempDir.path}/out/SdkFwRunner';
        compileRunner(
          RunnerCompileConfig(
            platform: 'ios',
            arch: 'arm64',
            appName: 'SdkFwRunner',
            minimumOsVersion: '14.0',
            sdkAvailable: false,
            sourcePaths: const [],
            modulemapPaths: const [],
            frameworkPaths: const [],
            sdkFrameworks: const ['AVFoundation', 'CoreBluetooth'],
            sdkDylibs: const ['sqlite3', 'libz'],
            outputPath: runnerOut,
          ),
        );
        final runnerText = utf8.decode(
          File(runnerOut).readAsBytesSync(),
          allowMalformed: true,
        );
        expect(runnerText, contains('sdk_framework=AVFoundation'));
        expect(runnerText, contains('sdk_framework=CoreBluetooth'));
        expect(runnerText, contains('sdk_dylib=sqlite3'));
        expect(runnerText, contains('sdk_dylib=libz'));
        expect(runnerText, contains('/usr/lib/libsqlite3.dylib'));
        expect(runnerText, contains('/usr/lib/libz.dylib'));
      },
    );
  });

  group('ZIP64 support', () {
    test('writes and reads ZIP64 archive when entry count exceeds 65,535', () {
      const entryCount = 65537;
      final entries = List<ZipEntry>.generate(
        entryCount,
        (i) => ZipEntry(
          path: 'Payload/Runner.app/f_${i.toString().padLeft(5, '0')}.txt',
          data: Uint8List(0),
        ),
      );

      final zipBytes = encodeDeterministicZip(entries);
      final bd = ByteData.sublistView(zipBytes);

      // Verify standard EOCD has 0xFFFF total entries sentinel, preceded by
      // ZIP64 EOCD locator (0x07064b50) and ZIP64 EOCD record (0x06064b50).
      final eocdOffset = zipBytes.length - 22;
      expect(bd.getUint32(eocdOffset, Endian.little), equals(0x06054b50));
      expect(bd.getUint16(eocdOffset + 10, Endian.little), equals(0xFFFF));

      final locatorOffset = eocdOffset - 20;
      expect(
        bd.getUint32(locatorOffset, Endian.little),
        equals(0x07064b50),
      );
      final zip64EocdOffset = bd.getUint64(locatorOffset + 8, Endian.little);
      expect(
        bd.getUint32(zip64EocdOffset, Endian.little),
        equals(0x06064b50),
      );
      expect(
        bd.getUint64(zip64EocdOffset + 24, Endian.little),
        equals(entryCount),
      );
      expect(
        bd.getUint64(zip64EocdOffset + 32, Endian.little),
        equals(entryCount),
      );

      final parsed = readZipEntries(zipBytes);
      expect(parsed.length, equals(entryCount));
      expect(parsed.first.path, equals('Payload/Runner.app/f_00000.txt'));
      expect(
        parsed.last.path,
        equals(
          'Payload/Runner.app/f_${(entryCount - 1).toString().padLeft(5, '0')}.txt',
        ),
      );
    });

    test(
      'writes and reads ZIP64 extended information (0x0001) when entry size exceeds 4 GiB',
      () {
        const over4GiB = 0x100000005; // 4 GiB + 5 bytes
        final entry = ZipEntry(
          path: 'Payload/Runner.app/huge.bin',
          data: Uint8List.fromList([1, 2, 3, 4, 5]),
          uncompressedSizeOverride: over4GiB,
        );

        final zipBytes = encodeDeterministicZip([entry]);
        final bd = ByteData.sublistView(zipBytes);

        // Local file header must have 0xFFFFFFFF size sentinels and 0x0001 extra field.
        expect(bd.getUint32(0, Endian.little), equals(0x04034b50));
        expect(bd.getUint16(4, Endian.little), equals(45)); // version 4.5
        expect(bd.getUint32(18, Endian.little), equals(0xFFFFFFFF));
        expect(bd.getUint32(22, Endian.little), equals(0xFFFFFFFF));
        final nameLen = bd.getUint16(26, Endian.little);
        final extraLen = bd.getUint16(28, Endian.little);
        expect(extraLen, equals(20)); // header(4) + usize(8) + csize(8)
        expect(
          bd.getUint16(30 + nameLen, Endian.little),
          equals(0x0001),
        );
        expect(
          bd.getUint64(30 + nameLen + 4, Endian.little),
          equals(over4GiB),
        );

        // Verify ZIP64 EOCD locator and record are emitted.
        final eocdOffset = zipBytes.length - 22;
        final locatorOffset = eocdOffset - 20;
        expect(
          bd.getUint32(locatorOffset, Endian.little),
          equals(0x07064b50),
        );
        final zip64EocdOffset = bd.getUint64(locatorOffset + 8, Endian.little);
        expect(
          bd.getUint32(zip64EocdOffset, Endian.little),
          equals(0x06064b50),
        );

        final parsed = readZipEntries(zipBytes);
        expect(parsed.length, equals(1));
        expect(parsed.single.path, equals('Payload/Runner.app/huge.bin'));
        expect(parsed.single.uncompressedSize, equals(over4GiB));
      },
    );
  });
}
