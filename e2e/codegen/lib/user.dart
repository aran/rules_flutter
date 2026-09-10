/// Model consumed by the Flutter app (lib/main.dart) whose `toJson()` lives in
/// a generated `part` (lib/user.g.dart, produced by tools/json_generator.dart).
///
/// Compiling the app must resolve this `part` directive — which only works if
/// the kernel compile co-locates the generated file with this source sibling.
library;

part 'user.g.dart';

/// The model whose `toJson()` the generated `part` supplies.
class User {
  /// Creates a user with the given [name] and [age].
  const User(this.name, this.age);

  /// The user's name.
  final String name;

  /// The user's age in years.
  final int age;
}
