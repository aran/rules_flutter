/// Model consumed by the Flutter app (lib/main.dart) whose `toJson()` lives in
/// a generated `part` (lib/user.g.dart, produced by tools/json_generator.dart).
///
/// Compiling the app must resolve this `part` directive — which only works if
/// the kernel compile co-locates the generated file with this source sibling.
part 'user.g.dart';

class User {
  final String name;
  final int age;

  const User(this.name, this.age);
}
