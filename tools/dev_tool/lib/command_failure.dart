/// Why a command did not do what it was asked, in one type.
///
/// A command surface has exactly one way to say no, and each transport renders
/// it in that transport's own vocabulary: the HTTP control channel as a status
/// plus `{"error": …}`, the stdin machine protocol as upstream's
/// `{"id": …, "error": "…"}`. A client checks one place, whichever way it is
/// driving the run.
///
/// What stays a *result* is an outcome with its own verdict field: a hot reload
/// answers `{"succeeded": false, "error": …}`, which is upstream's shape and is
/// a report about a thing that ran, not a refusal to run it. The line is
/// whether the command produced an answer of its own kind — text, a rectangle,
/// a reload verdict — or produced nothing.
library;

/// What kind of no this is. Transports map it to their own status vocabulary.
enum CommandFailureKind {
  /// The command, or the app it named, does not exist here.
  notFound,

  /// The request was malformed: a missing parameter, two selectors, a
  /// viewport that cannot be applied.
  badRequest,

  /// The command exists but cannot be served on this run — a capability the
  /// platform or the renderer does not have. Retrying will not help.
  unavailable,

  /// It was asked properly and could not be done: the app refused, or never
  /// answered.
  failed,
}

/// A command that could not be performed, and why.
class CommandFailure implements Exception {
  final String message;
  final CommandFailureKind kind;

  const CommandFailure(this.message, this.kind);

  const CommandFailure.notFound(this.message)
    : kind = CommandFailureKind.notFound;

  const CommandFailure.badRequest(this.message)
    : kind = CommandFailureKind.badRequest;

  const CommandFailure.unavailable(this.message)
    : kind = CommandFailureKind.unavailable;

  const CommandFailure.failed(this.message) : kind = CommandFailureKind.failed;

  @override
  String toString() => message;
}
