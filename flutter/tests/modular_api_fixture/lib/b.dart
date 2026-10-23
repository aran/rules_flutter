// Suite fixture for the public modular kernel API tests: a `test_api`-only
// suite over the leaf module, imported by the test bootstrap as
// `package:modular_api_b/b.dart`.
import 'package:modular_api_a/a.dart';
import 'package:test_api/backend.dart';

void main() {
  test('greets through the dep module', () {
    assert(modularApiGreeting('fixture') == 'Hello, fixture!');
  });
}
