/// Web build of this example has no native code; count in Dart instead.
library;

var _count = 0;

/// Bumps a Dart count twice, standing in for the native library on web.
int sharedCount() {
  _count++;
  return ++_count;
}
