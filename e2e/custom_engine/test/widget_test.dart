import 'package:custom_engine/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the app draws its screen', (tester) async {
    await tester.pumpWidget(const CustomEngineApp());
    expect(find.text('Custom engine'), findsOneWidget);
  });

  test('the program is told what the selected SDK is', () {
    // The stand-in checkout is not a git repository, so it has no framework
    // revision to report; the release SDK reports its own ten characters.
    expect(FlutterVersion.version, '3.50.0');
    expect(FlutterVersion.frameworkRevision, isEmpty);
    expect(FlutterVersion.engineRevision, '371f77202a');
    expect(FlutterVersion.dartVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
  });
}
