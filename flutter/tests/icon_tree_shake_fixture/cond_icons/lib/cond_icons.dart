// The standard Dart platform split: the web program gets icon_web.dart, the
// native program gets icon_vm.dart. The icon tree-shake kernel must compile
// against the web platform so const_finder sees the web branch's icon.
export 'src/icon_vm.dart' if (dart.library.js_interop) 'src/icon_web.dart';
