// A test that fails on purpose: the `flutter_prebuilt_test` twin of this
// suite (`:prebuilt_failing_test` in BUILD.bazel) runs this kernel, so its
// red run proves the prebuilt path executes the kernel rather than passing
// vacuously. Both targets are `manual`: neither runs under `bazel test
// //...`. Run them explicitly to see the failure:
//   bazel test //:prebuilt_failing_test
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deliberately fails', () {
    expect(1, 2, reason: 'this suite exists to fail');
  });
}
