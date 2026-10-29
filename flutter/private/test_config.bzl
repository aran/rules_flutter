"""Finds a test's `flutter_test_config.dart` the way `flutter test` does."""

TEST_CONFIG_FILENAME = "flutter_test_config.dart"

def find_test_config(main, exists):
    """The nearest `flutter_test_config.dart` above `main`, or None.

    `flutter test` walks up from the test file's directory and takes the first
    config it finds, checking each directory before deciding whether it is the
    project root: the walk ends after the directory holding `pubspec.yaml`.
    The same walk here, over package-relative paths, ends at the BUILD file's
    package as well, since nothing above it can be seen from there.

    Args:
      main: The test's main, as a path relative to the BUILD file's package.
      exists: Whether a package-relative path names a source file.

    Returns:
      The config's package-relative path, or None.
    """
    directory = main.rpartition("/")[0]

    # A path cannot climb more directories than it has.
    for _ in range(main.count("/") + 1):
        prefix = directory + "/" if directory else ""
        if exists(prefix + TEST_CONFIG_FILENAME):
            return prefix + TEST_CONFIG_FILENAME
        if exists(prefix + "pubspec.yaml") or not directory:
            return None
        directory = directory.rpartition("/")[0]
    return None
