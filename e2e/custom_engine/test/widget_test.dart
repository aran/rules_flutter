import 'package:custom_engine/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the app draws its screen', (tester) async {
    await tester.pumpWidget(const CustomEngineApp());
    expect(find.text('Custom engine'), findsOneWidget);
  });

  test('the program is told what the selected SDK is', () {
    // The stand-in checkout's revision is the first ten characters of its
    // commit, as the release SDK's is of the release's.
    expect(FlutterVersion.version, '3.50.0');
    expect(FlutterVersion.frameworkRevision, matches(RegExp(r'^[0-9a-f]{10}$')));
    expect(FlutterVersion.engineRevision, '371f77202a');
    expect(FlutterVersion.dartVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
  });
}
