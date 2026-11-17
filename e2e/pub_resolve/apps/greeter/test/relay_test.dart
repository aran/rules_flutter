import 'package:flutter_test/flutter_test.dart';
import 'package:greeting_relay/greeting_relay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("a package reached through one with nothing of Flutter's bundles "
      'its asset', () async {
    expect(await Greeting.text(), startsWith('Hello from greeting'));
  });
}
