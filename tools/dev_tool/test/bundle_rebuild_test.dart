/// One command, one build of the launch bundle.
import 'package:flutter_bazel_dev_tool/bundle_rebuild.dart';
import 'package:test/test.dart';

void main() {
  test('two callers inside one command get one build', () async {
    var builds = 0;
    var command = 1;
    final rebuild = BundleRebuild(() async {
      builds++;
      return true;
    }, () => command);

    // An `app.restart` whose asset sources moved: the asset refresh rebuilds the
    // bundle it is about to diff, and the native-libs check then needs the same
    // bundle current before it can compare it against the running process.
    expect(await rebuild.run(), isTrue);
    expect(await rebuild.run(), isTrue);
    expect(builds, 1);

    // The next command rebuilds: the tree has moved on, which is why there is a
    // next command.
    command = 2;
    expect(await rebuild.run(), isTrue);
    expect(builds, 2);
  });

  test('a failed build is the answer for the whole command', () async {
    var builds = 0;
    final rebuild = BundleRebuild(() async {
      builds++;
      return false;
    }, () => 7);

    expect(await rebuild.run(), isFalse);
    expect(await rebuild.run(), isFalse);
    expect(
      builds,
      1,
      reason:
          'a build that failed for this tree fails the same way twice, and the '
          'caller that asked first has already reported it',
    );
  });
}
