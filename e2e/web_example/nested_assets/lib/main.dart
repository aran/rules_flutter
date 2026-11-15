import 'package:material_ui/material_ui.dart';
import 'package:nested_assets/widgets/banner.dart';
import 'package:ui_kit/ui_kit.dart';

/// An app below the workspace root, showing three assets re-read on every
/// build: its own, one of a library of its own package, and the one in the
/// library it depends on.
///
/// `asset_reload_e2e_test` edits each file on disk and asserts the label
/// changes after a hot reload. Neither asset's key says where its file is in
/// the workspace (`assets/message.txt` is `nested_assets/assets/message.txt`,
/// `packages/ui_kit/assets/greeting.txt` is
/// `nested_assets/ui_kit/assets/greeting.txt`), which is what the reload has
/// to work out.
void main() {
  runApp(const NestedAssetsApp());
}

/// Root widget of the nested app.
class NestedAssetsApp extends StatelessWidget {
  /// Creates the nested app.
  const NestedAssetsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AssetLabel(
                assetKey: 'assets/message.txt',
                labelKey: ValueKey('e2e_app_asset_label'),
              ),
              _AssetLabel(
                assetKey: bannerKey,
                labelKey: ValueKey('e2e_own_lib_asset_label'),
              ),
              _AssetLabel(
                assetKey: greetingKey,
                labelKey: ValueKey('e2e_lib_asset_label'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssetLabel extends StatelessWidget {
  const _AssetLabel({required this.assetKey, required this.labelKey});

  final String assetKey;
  final Key labelKey;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: DefaultAssetBundle.of(context).loadString(assetKey),
      builder: (context, snapshot) =>
          Text(snapshot.data?.trim() ?? '', key: labelKey),
    );
  }
}
