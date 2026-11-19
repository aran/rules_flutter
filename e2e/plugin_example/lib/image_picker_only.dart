import 'package:flutter/widgets.dart';
import 'package:image_picker_android/image_picker_android.dart';

/// An app whose only Android plugin is image_picker_android, whose Java
/// compiles against flutter_plugin_android_lifecycle's classes. It names the
/// plugin's API so that it is linked; it picks no image.
void main() {
  runApp(Text('${ImagePickerAndroid()}', textDirection: TextDirection.ltr));
}
