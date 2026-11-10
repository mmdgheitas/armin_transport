/// The objects the screens depend on, as Riverpod providers that tests can replace.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'api/armin_api.dart';
import 'api/models.dart';
import 'files.dart';
import 'session.dart';

/// The state restored before the first frame. `main()` provides the real object.
final appSessionProvider = Provider<AppSession>(
  (ref) => throw StateError('appSessionProvider has to be overridden with the loaded session.'),
);

class AuthNotifier extends Notifier<AuthSession?> {
  @override
  AuthSession? build() {
    final app = ref.watch(appSessionProvider);
    void sync() => state = app.auth;
    app.addListener(sync);
    ref.onDispose(() => app.removeListener(sync));
    return app.auth;
  }
}

/// The signed-in session, or `null`. Widgets that watch it rebuild when the user or the permissions change.
final authProvider = NotifierProvider<AuthNotifier, AuthSession?>(AuthNotifier.new);

class ServerUrlNotifier extends Notifier<String?> {
  @override
  String? build() {
    final app = ref.watch(appSessionProvider);
    void sync() => state = app.serverUrl;
    app.addListener(sync);
    ref.onDispose(() => app.removeListener(sync));
    return app.serverUrl;
  }
}

/// The API base URL, or `null` before the address of the server is known.
final serverUrlProvider = NotifierProvider<ServerUrlNotifier, String?>(ServerUrlNotifier.new);

/// The HTTP engine. Tests replace it with one that answers from memory.
final dioProvider = Provider<Dio>((ref) {
  final dio = ApiClient.createDio();
  ref.onDispose(dio.close);
  return dio;
});

/// A client for the server at [baseUrl] that reads and updates the session of the app.
ApiClient createApiClient({required String baseUrl, required Dio dio, required AppSession app}) =>
    ApiClient(baseUrl: baseUrl, dio: dio, readSession: () => app.auth, writeSession: app.write, endSession: app.end);

/// The client for the configured server. One instance per address, so that only one token renewal runs at a time.
final apiClientProvider = Provider<ApiClient>((ref) {
  final baseUrl = ref.watch(serverUrlProvider);
  if (baseUrl == null) throw StateError('The address of the server is not known yet.');
  return createApiClient(baseUrl: baseUrl, dio: ref.watch(dioProvider), app: ref.watch(appSessionProvider));
});

final apiProvider = Provider<ArminApi>((ref) => ArminApi(ref.watch(apiClientProvider)));

final fileGatewayProvider = Provider<FileGateway>((ref) => const PlatformFileGateway());

/// The current time. Tests replace it to get the same result every day.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
