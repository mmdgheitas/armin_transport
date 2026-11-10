import 'dart:convert';

import 'package:armin_transport/core/api/api_error.dart';
import 'package:armin_transport/core/api/models.dart';
import 'package:armin_transport/core/session.dart';
import 'package:armin_transport/core/storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

const String server = 'https://armin.test/api/v1';

/// A storage whose every operation fails, like a broken key store.
class BrokenStorage implements AppStorage {
  int attempts = 0;

  @override
  Future<String?> read(String key) async {
    attempts += 1;
    throw const FormatException('unreadable');
  }

  @override
  Future<void> write(String key, String value) async {
    attempts += 1;
    throw const FormatException('read-only');
  }

  @override
  Future<void> delete(String key) async {
    attempts += 1;
    throw const FormatException('read-only');
  }
}

void main() {
  late FakeClock clock;
  late MemoryAppStorage storage;

  setUp(() {
    clock = FakeClock();
    storage = MemoryAppStorage();
  });

  AuthSession newSession([String suffix = '1']) => AuthSession.fromAuthResponse(authPayload(suffix), clock.now)!;

  Future<AppSession> load({String compiledUrl = ''}) => AppSession.load(storage, compiledUrl: compiledUrl, now: clock.call);

  test('starts empty on a new device', () async {
    final app = await load();
    expect(app.serverUrl, isNull);
    expect(app.auth, isNull);
    expect(app.isSignedIn, isFalse);
    expect(app.serverIsFixed, isFalse);
    expect(app.endReason, isNull);
  });

  test('remembers the server and the session between runs', () async {
    final first = await load();
    first.setServer(server);
    first.write(newSession());
    expect(first.isSignedIn, isTrue);
    await first.settled;
    expect(storage.values.keys.toSet(), {serverStorageKey, sessionStorageKey});

    clock.advance(const Duration(days: 3));
    final second = await load();
    expect(second.serverUrl, server);
    expect(second.isSignedIn, isTrue);
    final restored = second.auth!;
    expect(restored.accessToken, 'access-1');
    expect(restored.refreshToken, 'refresh-token-1-padding-padding');
    expect(restored.accessExpiresAt, first.auth!.accessExpiresAt);
    expect(restored.refreshExpiresAt, first.auth!.refreshExpiresAt);
    expect(restored.user.fullName, 'سارا محمدی');
    expect(restored.user.company!.name, 'حمل‌ونقل آرمین');
    expect(restored.permissions, first.auth!.permissions);
    expect(restored.settings.upload.allowedExtensions, contains('pdf'));
    expect(restored.settings.maxPageSize, 100);
  });

  test('forgets a session whose refresh token has expired', () async {
    final first = await load();
    first.setServer(server);
    first.write(newSession());
    await first.settled;

    clock.advance(const Duration(seconds: 1209600));
    final second = await load();
    expect(second.serverUrl, server);
    expect(second.auth, isNull);
    expect(second.isSignedIn, isFalse);
  });

  test('a session stops counting as signed in when its refresh token expires while the app is open', () async {
    final app = await load();
    app.setServer(server);
    app.write(newSession());
    clock.advance(const Duration(seconds: 1209599));
    expect(app.isSignedIn, isTrue);
    clock.advance(const Duration(seconds: 1));
    expect(app.isSignedIn, isFalse);
  });

  test('never offers the tokens of one server to another', () async {
    final first = await load();
    first.setServer(server);
    first.write(newSession());
    await first.settled;

    // The stored address changes behind the back of the app.
    storage.values[serverStorageKey] = 'https://other.test/api/v1';
    final second = await load();
    expect(second.serverUrl, 'https://other.test/api/v1');
    expect(second.auth, isNull);
  });

  test('switching to another server ends the session', () async {
    final app = await load();
    app.setServer(server);
    app.write(newSession());
    var notifications = 0;
    app.addListener(() => notifications += 1);

    app.setServer('https://other.test/api/v1');
    expect(app.serverUrl, 'https://other.test/api/v1');
    expect(app.auth, isNull);
    expect(app.endReason, isNull);
    expect(notifications, 1);
    await app.settled;
    expect(storage.values, {serverStorageKey: 'https://other.test/api/v1'});

    app.setServer('https://other.test/api/v1'); // the same address again changes nothing
    expect(notifications, 1);
  });

  test('an address built into the app cannot be replaced', () async {
    storage.values[serverStorageKey] = 'https://stored.test/api/v1';
    final app = await load(compiledUrl: 'https://fixed.test');
    expect(app.serverUrl, 'https://fixed.test/api/v1');
    expect(app.serverIsFixed, isTrue);
    app.setServer('https://other.test/api/v1');
    expect(app.serverUrl, 'https://fixed.test/api/v1');
    await app.settled;
    expect(storage.values[serverStorageKey], 'https://stored.test/api/v1');
  });

  test('an unusable built-in address falls back to the stored one', () async {
    storage.values[serverStorageKey] = 'https://stored.test/api/v1';
    final app = await load(compiledUrl: 'http://public.example.com');
    expect(app.serverUrl, 'https://stored.test/api/v1');
    expect(app.serverIsFixed, isFalse);
  });

  test('ignores stored values it cannot use', () async {
    storage.values[serverStorageKey] = 'http://public.example.com/api/v1'; // plain HTTP outside a local network
    storage.values[sessionStorageKey] = '{broken';
    final app = await load();
    expect(app.serverUrl, isNull);
    expect(app.auth, isNull);

    storage.values[serverStorageKey] = server;
    for (final unusable in [
      '{broken',
      'null',
      '[]',
      '{"server":"$server"}',
      jsonEncode({...newSession().toStorageJson(), 'server': server, 'version': 2}),
      jsonEncode({...newSession().toStorageJson(), 'server': server, 'refresh_token': ''}),
      jsonEncode({...newSession().toStorageJson(), 'server': server, 'user': <String, dynamic>{}}),
      jsonEncode({...newSession().toStorageJson(), 'server': server, 'access_expires_at': 'soon'}),
    ]) {
      storage.values[sessionStorageKey] = unusable;
      expect((await load()).auth, isNull, reason: unusable);
    }
    storage.values[sessionStorageKey] = jsonEncode({...newSession().toStorageJson(), 'server': server});
    expect((await load()).auth, isNotNull);
  });

  test('tells why the server ended a session exactly once', () async {
    final app = await load();
    app.setServer(server);
    app.write(newSession());
    await app.settled;
    var notifications = 0;
    app.addListener(() => notifications += 1);

    final reason = ApiError(status: 401, code: 'token_revoked', message: sessionEndedMessage);
    app.end(reason);
    app.end(reason); // every request that was under way reports the same end
    expect(notifications, 1);
    expect(app.auth, isNull);
    expect(app.endReason, same(reason));
    expect(app.takeEndReason(), same(reason));
    expect(app.takeEndReason(), isNull);
    await app.settled;
    expect(storage.values.containsKey(sessionStorageKey), isFalse);
    expect(storage.values[serverStorageKey], server);
  });

  test('a logout leaves nothing to tell', () async {
    final app = await load();
    app.setServer(server);
    app.write(newSession());
    app.end();
    expect(app.auth, isNull);
    expect(app.endReason, isNull);

    // A logout that the server answered with a rejection: the rejection is not reported either.
    app.write(newSession('2'));
    app.end(ApiError(status: 401, code: 'token_revoked'));
    app.end();
    expect(app.endReason, isNull);

    // A new login clears an old reason.
    app.write(newSession('3'));
    app.end(ApiError(status: 401, code: 'token_revoked'));
    app.write(newSession('4'));
    expect(app.endReason, isNull);
  });

  test('stores the newest tokens when they change quickly', () async {
    final app = await load();
    app.setServer(server);
    for (var generation = 1; generation <= 5; generation += 1) {
      app.write(newSession('$generation'));
    }
    await app.settled;
    final stored = jsonDecode(storage.values[sessionStorageKey]!) as Map<String, dynamic>;
    expect(stored['access_token'], 'access-5');
    expect(stored['server'], server);
    expect(stored['version'], 1);
  });

  test('keeps working in memory when the storage of the device fails', () async {
    final broken = BrokenStorage();
    final app = await AppSession.load(broken, compiledUrl: '', now: clock.call);
    expect(app.serverUrl, isNull);
    app.setServer(server);
    app.write(newSession());
    app.end();
    app.write(newSession('2'));
    await app.settled;
    expect(app.serverUrl, server);
    expect(app.auth!.accessToken, 'access-2');
    expect(broken.attempts, greaterThan(4));
  });
}
