import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the fonts of the app before the screen tests run, so that texts take the room they take on a device.
/// Without this every glyph is a square as wide as the font size, and layouts overflow that fit in reality.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final entry in manifest) {
    final font = entry as Map<String, dynamic>;
    final loader = FontLoader(font['family'] as String);
    for (final file in font['fonts'] as List<dynamic>) {
      loader.addFont(rootBundle.load((file as Map<String, dynamic>)['asset'] as String));
    }
    await loader.load();
  }
  await testMain();
}
