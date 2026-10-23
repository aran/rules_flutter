import 'package:flutter/src/widgets/icon_data.dart';

export 'package:flutter/foundation.dart';
export 'package:flutter/src/widgets/icon_data.dart'
    show IconData, staticIconProvider;

class TextStyle {
  const TextStyle({this.fontFamily, this.package});

  final String? fontFamily;
  final String? package;
}

@staticIconProvider
abstract final class Icons {
  static const IconData a = IconData(0xe047, fontFamily: 'MaterialIcons');
  static const IconData b = IconData(0xe567, fontFamily: 'MaterialIcons');
  static const IconData c = IconData(0xe145, fontFamily: 'MaterialIcons');
  static const IconData d = IconData(0xe88a, fontFamily: 'MaterialIcons');
  static const IconData e = IconData(0xe5cd, fontFamily: 'MaterialIcons');
}
