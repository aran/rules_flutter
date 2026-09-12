/// What the native-library check decided about a command, before anyone puts it
/// into words.
///
/// Four states, because there are four genuinely different things to say about a
/// rebuilt native library, and a reload that collapsed them would either refuse
/// an edit it could have delivered or deliver one it could not. The question is
/// never "did the library change" on its own — a library the running process has
/// `dlopen`ed can never be replaced, so that much is always true once a rebuild
/// has moved it. The question is whether the *bindings* about to be injected are
/// ones that library can still serve.
///
/// A build answers that by declaring a binding contract — see
/// `flutter_native_library` — whose bytes the dev tool compares and never parses.
library;

sealed class NativeLibsVerdict {
  const NativeLibsVerdict();
}

/// The running process has the libraries on disk. The ordinary path, and the one
/// every app with no native libraries at all takes.
final class NativeLibsCurrent extends NativeLibsVerdict {
  const NativeLibsCurrent();
}

/// The libraries' code moved and their declared contracts did not, so the
/// bindings are unchanged and the old images can still serve them.
///
/// The increment is delivered. What the app cannot have is the new *machine
/// code*, which is reported rather than left to be discovered: an edit to a
/// function's body is live in every sense except the one that matters, and a
/// reply that said only "successful" would be how someone spends an afternoon on
/// it.
final class NativeCodeStale extends NativeLibsVerdict {
  /// The libraries whose bytes moved, so the reply can name them.
  final List<String> libs;

  const NativeCodeStale(this.libs);
}

/// A declared contract moved: the bindings are not ones the running process's
/// libraries can serve.
///
/// Nothing may be compiled or sent. This is the shape that corrupts — new
/// bindings over an old library decode a request that was never encoded for it,
/// and the failure surfaces as a malformed-message error from inside the bridge
/// or a call landing on the wrong function, with nothing left pointing at the
/// library.
final class NativeBindingsMoved extends NativeLibsVerdict {
  final List<String> libs;

  /// The contract files whose bytes moved — the evidence, and what a reader
  /// diffs to see what about their interface changed.
  final List<String> contracts;

  const NativeBindingsMoved({required this.libs, required this.contracts});
}

/// A library's code moved and no contract is declared for it, so nothing says
/// whether its bindings changed.
///
/// Withheld, for the same reason as [NativeBindingsMoved] and with a different
/// thing to say: the answer is unknown rather than no, and the way to make it
/// knowable is to declare what the bindings are built against. Every app that
/// bundles a native library starts here, which is why this is the state that
/// carries the advice.
final class NativeLibsUnverifiable extends NativeLibsVerdict {
  final List<String> libs;

  const NativeLibsUnverifiable(this.libs);
}
