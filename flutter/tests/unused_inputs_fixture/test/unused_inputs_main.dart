// Entrypoint fixture for the `unused_inputs` analysis tests.
//
// Framework-free: the tests read declared actions, never build the fixture.
// Imports every shape the unused-inputs list must keep: the adopted part's
// value, the re-exported library, and the folded constant.
import 'package:unused_a/adopt.dart';

void main() {
  adoptValue();
  cValue();
  foldedAgain;
}
