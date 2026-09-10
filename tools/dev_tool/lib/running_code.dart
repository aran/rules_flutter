/// What the app's Dart code is, once a command is over.
///
/// Its own library because the question is asked at both ends of the pipeline
/// and the answers must be the same word: `VmServiceClient` knows which phase
/// of an apply failed, and `CommandReport` knows what to tell a client. A
/// second enum, or a sentence composed by hand at either end, is how the two
/// would come to disagree.
library;

/// What the app's Dart code is, now the command is over.
///
/// The question a failed reload cannot answer in prose without guessing, and
/// the one its reader most needs: is the app still running what it was?
///
/// Deliberately not derived from success: a failure can leave the app running
/// the new code (`AppliedThenThrew`), and a success can leave it running the
/// old one (an empty delta).
enum RunningCode {
  /// The app is running the same program it was: whatever this command sent,
  /// if anything, the loaded code is what it already had.
  ///
  /// Three shapes reach it. Nothing was ever sent — a refusal, a pre-compile
  /// rebuild that broke, a compile that produced no delta. A delivery was
  /// demonstrably refused before it took effect (`ApplyFailed`). Or a delivery
  /// completed and carried nothing new: an empty delta, where every file the
  /// compiler was asked for was byte-identical to what the app already had.
  ///
  /// That last one reaches an app, and a **restart** with an empty delta reaches
  /// it hard — `runInView` re-runs `main()`, so the state is wiped and the
  /// screen can change while the code does not. It is still this value, because
  /// the question is what code is loaded and nothing else. This does not mean
  /// "nothing happened", and no consumer may read it that way: the sentence it
  /// gates is about the program, not about what is on screen.
  unchanged,

  /// The VM took the code. It may be unhappy about it — see `AppliedThenThrew`
  /// — but it is running it.
  updated,

  /// Nobody said, and nothing here may guess. A device that never answered
  /// within the apply's budget is the member this exists for: the RPC it
  /// stopped waiting on may have landed, and the connection was dropped before
  /// anything could ask.
  ///
  /// A refusal is not one of these: `VmServiceClient` never raises one after an
  /// app has taken what was sent.
  unknown,
}
