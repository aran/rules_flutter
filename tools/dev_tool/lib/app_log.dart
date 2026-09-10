/// Console output from a running Flutter app.
///
/// A launched app produces console output for its whole lifetime, and the dev
/// tool has several consumers for it that come and go at different times: the
/// terminal, the `app.log` machine-protocol event, and the HTTP control
/// channel's `/logs` endpoint. [AppLogStream] is the single place that output
/// lands, so every consumer sees the same lines.
///
/// Two properties matter and neither is free:
///
///  * **Nothing is lost before someone listens.** Output starts flowing the
///    moment the app is spawned, but the session that forwards it isn't wired
///    up until `launch()` has returned. A plain broadcast controller discards
///    events emitted while unlistened, which would silently swallow everything
///    printed during startup and VM-service discovery. So the stream is backed
///    by a ring buffer that is replayed to each new listener.
///  * **The producer never blocks.** Whatever feeds the stream (an OS pipe, a
///    logcat process, a VM-service event stream) must keep being drained
///    regardless of whether anyone is listening, or the app itself can stall on
///    a full pipe. Adding to the buffer is unconditional and never awaits a
///    consumer.
///
/// The buffer is bounded. When it overflows, the eviction is *reported*
/// ([dropped], and [LogPage.missed] for a specific reader) rather than papered
/// over, so a consumer can tell "there was nothing more" apart from "I fell
/// behind".
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// A single line of console output from a running app.
class AppLogLine {
  /// The line, without its trailing newline.
  final String text;

  /// Whether the line came from an error channel (the process's stderr, a
  /// VM-service `Stderr` event, a `console.error` call).
  final bool isError;

  /// Monotonically increasing position in the app's output. Stable across
  /// eviction: index `n` always refers to the same line, whether or not it is
  /// still buffered.
  final int index;

  const AppLogLine({
    required this.text,
    required this.isError,
    required this.index,
  });

  @override
  String toString() => '${isError ? 'stderr' : 'stdout'}[$index]: $text';
}

/// A page of lines from [AppLogStream.read], plus what the reader needs to
/// keep polling without gaps or overlap.
class LogPage {
  final List<AppLogLine> lines;

  /// Pass this back as the next `cursor` to continue where this page ended.
  final int nextCursor;

  /// How many lines fell between the requested cursor and the first line
  /// returned — i.e. lines that were evicted before this reader asked for
  /// them. Zero means the page is contiguous with the previous one.
  ///
  /// Always zero for a tail read: a caller asking for "the last N lines" did
  /// not ask for anything earlier, so nothing was missed.
  final int missed;

  const LogPage({
    required this.lines,
    required this.nextCursor,
    required this.missed,
  });
}

/// Default number of lines retained. Roughly a screen's worth of scrollback
/// several times over; enough that a consumer polling every few seconds never
/// falls behind, small enough to be irrelevant to memory.
const _defaultCapacity = 2000;

/// The largest page [AppLogStream.read] will return regardless of the
/// requested limit, so a naive `cursor: 0` on a long-running app can't produce
/// an unbounded response.
const _maxPageSize = 1000;

/// Fans a running app's console output out to zero or more listeners.
///
/// See the library docs for why this exists rather than a bare
/// `StreamController.broadcast()`.
class AppLogStream {
  final int capacity;
  final ListQueue<AppLogLine> _buffer = ListQueue<AppLogLine>();
  final StreamController<AppLogLine> _controller =
      StreamController<AppLogLine>.broadcast();

  int _nextCursor = 0;
  int _dropped = 0;
  bool _closed = false;

  AppLogStream({this.capacity = _defaultCapacity})
    : assert(capacity > 0, 'capacity must be positive');

  /// Close this stream once every future in [sources] has completed.
  ///
  /// A reader waiting on the stream — VM-service discovery, a `/logs` poller —
  /// then learns immediately that no more output is coming, rather than
  /// sitting out a timeout.
  ///
  /// The whole set is named in one call, by the one object that knows how many
  /// sources it started, because a stream fed by several sources cannot close
  /// on the first of them to finish: a physical iOS device is fed by both
  /// `devicectl --console` and lldb, either of which can end first, and
  /// closing on the first would mute the other for the rest of the run.
  /// Registering sources one at a time instead would mean the count can pass
  /// through zero before the last source has even been started.
  void closeWhen(Iterable<Future<void>> sources) =>
      unawaited(Future.wait(sources).then((_) => close()));

  /// Append a line. Never blocks, and is a no-op once [close] has been called.
  void add(String text, {bool isError = false}) {
    if (_closed) return;
    final line = AppLogLine(
      text: text,
      isError: isError,
      index: _nextCursor++,
    );
    _buffer.addLast(line);
    while (_buffer.length > capacity) {
      _buffer.removeFirst();
      _dropped++;
    }
    _controller.add(line);
  }

  /// Every line, buffered ones first and then live ones as they arrive.
  ///
  /// Each listener gets its own replay of whatever is currently buffered, so a
  /// consumer that attaches late still sees the app's startup output.
  Stream<AppLogLine> get lines {
    late StreamController<AppLogLine> out;
    StreamSubscription<AppLogLine>? live;

    out = StreamController<AppLogLine>(
      onListen: () {
        // Snapshot before subscribing: any line added between the snapshot and
        // the subscription would otherwise be delivered twice.
        final replay = List<AppLogLine>.of(_buffer);
        final replayedThrough = _nextCursor;
        for (final line in replay) {
          out.add(line);
        }
        if (_closed) {
          out.close();
          return;
        }
        live = _controller.stream.listen(
          (line) {
            if (line.index >= replayedThrough) out.add(line);
          },
          onDone: out.close,
          onError: out.addError,
        );
      },
      onCancel: () async {
        await live?.cancel();
        live = null;
      },
    );

    return out.stream;
  }

  /// Read a page of lines.
  ///
  /// [cursor] selects the starting point:
  ///
  ///  * `0` — from the oldest line still buffered.
  ///  * `n > 0` — resume at index `n` (pass back a previous
  ///    [LogPage.nextCursor]).
  ///  * `n < 0` — *tail*: the last `-n` lines. `read(-100)` means "the most
  ///    recent 100 lines", which is what a consumer with no prior cursor
  ///    almost always wants.
  ///
  /// A cursor older than the retained window clamps to the oldest retained
  /// line and reports the gap in [LogPage.missed]; it is never silently
  /// treated as if it had been contiguous.
  LogPage read(int cursor, {int limit = _maxPageSize}) {
    final effectiveLimit = limit <= 0
        ? 0
        : (limit > _maxPageSize ? _maxPageSize : limit);
    if (_buffer.isEmpty || effectiveLimit == 0) {
      return LogPage(lines: const [], nextCursor: _nextCursor, missed: 0);
    }

    final oldest = _buffer.first.index;

    if (cursor < 0) {
      // Tail: take from the end, so a limit smaller than the requested window
      // keeps the *newest* lines rather than the oldest of that window.
      final want = -cursor;
      final take = want < effectiveLimit ? want : effectiveLimit;
      final all = _buffer.toList(growable: false);
      final from = all.length > take ? all.length - take : 0;
      return LogPage(
        lines: all.sublist(from),
        nextCursor: _nextCursor,
        missed: 0,
      );
    }

    final missed = cursor < oldest ? oldest - cursor : 0;
    final start = cursor < oldest ? oldest : cursor;
    final selected = <AppLogLine>[];
    for (final line in _buffer) {
      if (line.index < start) continue;
      if (selected.length >= effectiveLimit) break;
      selected.add(line);
    }

    return LogPage(
      lines: selected,
      nextCursor: selected.isEmpty ? _nextCursor : selected.last.index + 1,
      missed: missed,
    );
  }

  /// The index the next added line will get — i.e. one past the newest line.
  int get nextCursor => _nextCursor;

  /// The lowest index still retained, or [nextCursor] when nothing is
  /// buffered.
  int get oldestCursor => _buffer.isEmpty ? _nextCursor : _buffer.first.index;

  /// Total lines evicted since the stream was created.
  int get dropped => _dropped;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Stop accepting lines and complete every listener. Idempotent.
  ///
  /// The buffer is retained so a consumer can still [read] an exited app's
  /// final output — a crash's last lines are the ones that matter most.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}

/// A running forwarder from some source into an [AppLogStream].
class AppLogPump {
  final List<StreamSubscription<String>> _subscriptions;
  final Completer<void> _done;

  AppLogPump._(this._subscriptions, this._done);

  /// Completes when this pump will forward nothing further — its source has
  /// ended, or [dispose] was called. Hand it to [AppLogStream.closeWhen] to
  /// make the stream's lifetime follow its sources'.
  Future<void> get done => _done.future;

  /// Stop forwarding. The [AppLogStream] itself is unaffected.
  Future<void> dispose() async {
    await Future.wait(_subscriptions.map((s) => s.cancel()));
    _subscriptions.clear();
    if (!_done.isCompleted) _done.complete();
  }
}

/// Wire a process's stdout and stderr into [out] for the process's lifetime.
///
/// Forwarding never stops on a content match. Discovery of things like the
/// VM-service URI is a *reader* of [AppLogStream], never an owner of these
/// subscriptions: cancelling them on a match would both cut off the rest of
/// the app's output and leave the OS pipes unread, which stalls the writer.
///
/// [transform] filters and rewrites lines: return null to drop a line (used by
/// sources like `adb logcat` that carry unrelated system logging).
///
/// Pumping does not close [out] — [AppLogPump.done] reports when this source
/// has ended, and the caller that started every source decides what that means
/// for the stream (see [AppLogStream.closeWhen]).
AppLogPump pumpProcessLines(
  Process process,
  AppLogStream out, {
  bool stderrIsError = true,
  String? Function(String line)? transform,
}) {
  void handle(String line, {required bool isError}) {
    final mapped = transform == null ? line : transform(line);
    if (mapped == null) return;
    out.add(mapped, isError: isError);
  }

  Stream<String> linesOf(Stream<List<int>> raw) => raw
      // Device logs occasionally carry invalid UTF-8; a decoding error must
      // not tear down forwarding for the rest of the run.
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  // Both channels have to end, not just one: stderr may still carry the reason
  // the app is failing after stdout has gone quiet.
  final done = Completer<void>();
  var remaining = 2;
  void onStreamDone() {
    if (--remaining == 0 && !done.isCompleted) done.complete();
  }

  return AppLogPump._([
    linesOf(
      process.stdout,
    ).listen((l) => handle(l, isError: false), onDone: onStreamDone),
    linesOf(
      process.stderr,
    ).listen((l) => handle(l, isError: stderrIsError), onDone: onStreamDone),
  ], done);
}
