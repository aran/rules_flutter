/// Tying a spawned process to the lifetime of the test that started it.
///
/// ## What `package:test` does when a test times out
///
///   * The body is **abandoned, not cancelled**. `Invoker.heartbeat`'s timer
///     completes the outstanding-callback barrier, so the runner stops *waiting
///     on* the body — but nothing stops the body *executing*, and Dart cannot
///     cancel an async frame. The frame stays parked on whatever future it was
///     awaiting, so a `try { … } finally { dispose(); }` around a spawned
///     process never disposes anything, and the process outlives the suite.
///   * Callbacks registered with `addTearDown` **do** run, and are awaited
///     **without a bound**. So teardown is not the thing at risk of being cut
///     short; the hazard runs the other way, and a teardown that can hang hangs
///     the whole suite. `DevToolProcess.dispose` bounding its own waits is what
///     makes it safe to register here.
///   * The abandoned frame **keeps going**. When the timeout lands while a
///     spawn is still in flight, the frame runs on and starts the process
///     *after* the teardowns have already finished.
///   * `addTearDown` called after teardowns have run is **silently dropped**:
///     it appends to `Invoker._tearDowns`, a list the `while` loop in
///     `runTearDowns` has already drained and will not look at again. No throw,
///     no warning, and the callback never runs.
///
/// The last two are why [spawnBoundToTest] registers cleanup *before* it
/// spawns, and why the registered callback leaves word behind for a spawn that
/// finishes after it.
library;

import 'dart:async';

import 'package:test/test.dart';

/// Spawns a resource with its cleanup already registered, so no test can end —
/// however it ends — leaving the resource running.
///
/// [spawn] starts it and [dispose] releases it; the result is whatever [spawn]
/// returned. [dispose] is registered on the running test before [spawn] is
/// called, which is the only ordering that survives a timeout: registering
/// afterwards loses the race described above, silently, because a late
/// `addTearDown` is accepted and then never run.
///
/// When the test ends while [spawn] is still in flight, the resource is
/// disposed as soon as it exists and the call throws [StateError] rather than
/// handing a live process back to a test that has already finished. Throwing is
/// what stops the abandoned frame from carrying on against it.
///
/// The alternative — having the teardown *await* an in-flight spawn — would
/// order the dispose before the next test starts, since teardowns get unbounded
/// time. It is rejected: a spawn that wedges would then hang the entire suite,
/// which is the failure mode all the bounding work exists to prevent. The cost
/// of the flag instead is that a late dispose may overlap the next test's
/// startup, and that overlap is bounded by [dispose]'s own limits.
///
/// [register] is a seam for testing this function itself; it defaults to
/// `package:test`'s [addTearDown] and production callers leave it alone.
Future<T> spawnBoundToTest<T extends Object>({
  required Future<T> Function() spawn,
  required Future<void> Function(T resource) dispose,
  void Function(FutureOr<dynamic> Function() callback) register = addTearDown,
}) async {
  var testEnded = false;
  T? spawned;

  register(() async {
    testEnded = true;
    // Read once: the spawn cannot complete between here and the await, and
    // when it completes later the guard below disposes it instead.
    final resource = spawned;
    if (resource != null) await dispose(resource);
  });

  final resource = await spawn();
  spawned = resource;

  if (testEnded) {
    await dispose(resource);
    throw StateError(
      'the test ended while this was still starting up, so it was disposed '
      'as soon as it existed. Nothing is left running, but nothing can be '
      'done with it either.',
    );
  }
  return resource;
}
