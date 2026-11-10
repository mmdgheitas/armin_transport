import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'core/providers.dart';
import 'core/session.dart';
import 'core/storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The address of the server and the session of the last run decide which screen comes first.
  final session = await AppSession.load(SecureAppStorage());
  runApp(ProviderScope(overrides: [appSessionProvider.overrideWithValue(session)], child: const ArminApp()));
}
