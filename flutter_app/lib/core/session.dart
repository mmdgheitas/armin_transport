/// What the app remembers: the address of the server and the signed-in session.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api/api_error.dart';
import 'api/models.dart';
import 'config.dart';
import 'storage.dart';

/// The state shared by the whole app. Screens listen to it; the router re-evaluates its redirects when it changes.
///
/// Changes take effect in memory at once and are written to [AppStorage] in the background, one after the other.
/// When the storage of the device fails, the app keeps working and only forgets its state when it is closed.
class AppSession extends ChangeNotifier {
  AppSession({
    required AppStorage storage,
    String? serverUrl,
    AuthSession? auth,
    this.serverIsFixed = false,
    DateTime Function() now = DateTime.now,
  }) : _storage = storage,
       _serverUrl = serverUrl,
       _auth = auth,
       _now = now;

  /// Restores the state of the previous run.
  ///
  /// [compiledUrl] is the address built into the app; when it is valid the user cannot choose another one.
  static Future<AppSession> load(
    AppStorage storage, {
    String compiledUrl = compiledApiBaseUrl,
    DateTime Function() now = DateTime.now,
  }) async {
    final compiled = compiledUrl.trim().isEmpty ? null : ServerAddress.parse(compiledUrl).baseUrl;
    var serverUrl = compiled;
    if (serverUrl == null) {
      final stored = await _read(storage, serverStorageKey);
      // Checked again, because the rules may be stricter than when the address was stored.
      if (stored != null) serverUrl = ServerAddress.parse(stored).baseUrl;
    }

    AuthSession? auth;
    final storedSession = await _read(storage, sessionStorageKey);
    if (storedSession != null && serverUrl != null) {
      try {
        final json = asJson(jsonDecode(storedSession));
        // Tokens are only ever sent to the server that issued them.
        if (json['server'] == serverUrl) auth = AuthSession.fromStorageJson(json);
      } on FormatException {
        auth = null;
      }
      if (auth != null && !auth.refreshExpiresAt.isAfter(now())) auth = null;
    }
    return AppSession(storage: storage, serverUrl: serverUrl, auth: auth, serverIsFixed: compiled != null, now: now);
  }

  static Future<String?> _read(AppStorage storage, String key) async {
    try {
      return await storage.read(key);
    } on Object catch (error) {
      // A key store that cannot be read (for example after a restored backup) must not keep the app from starting.
      debugPrint('Armin Transport: could not read the stored state ($error).');
      return null;
    }
  }

  final AppStorage _storage;
  final DateTime Function() _now;
  String? _serverUrl;
  AuthSession? _auth;
  ApiError? _endReason;
  Future<void> _writes = Future<void>.value();

  /// True when the address of the server is built into the app and cannot be changed by the user.
  final bool serverIsFixed;

  /// The API base URL, e.g. `https://example.com/api/v1`; `null` until the user has entered an address.
  String? get serverUrl => _serverUrl;

  /// The session of the signed-in employee, or `null`.
  AuthSession? get auth => _auth;

  bool get isSignedIn {
    final auth = _auth;
    return auth != null && auth.refreshExpiresAt.isAfter(_now());
  }

  /// Why the server ended the last session. The login screen shows it once, see [takeEndReason].
  ApiError? get endReason => _endReason;

  ApiError? takeEndReason() {
    final reason = _endReason;
    _endReason = null;
    return reason;
  }

  /// Stores the result of a login or a token renewal.
  void write(AuthSession session) {
    _auth = session;
    _endReason = null;
    notifyListeners();
    final serverUrl = _serverUrl;
    final text = jsonEncode(<String, dynamic>{...session.toStorageJson(), 'server': serverUrl});
    _enqueue(() => _storage.write(sessionStorageKey, text));
  }

  /// Forgets the session: after a logout ([reason] is `null`) or because the server no longer accepts it.
  void end([ApiError? reason]) {
    if (_auth == null) {
      // A logout right after a rejection: there is nothing left to tell the user.
      if (reason == null) _endReason = null;
      return;
    }
    _auth = null;
    _endReason = reason;
    notifyListeners();
    _enqueue(() => _storage.delete(sessionStorageKey));
  }

  /// Switches to another server. A session of the previous server ends, because its tokens mean nothing elsewhere.
  void setServer(String baseUrl) {
    if (serverIsFixed || baseUrl == _serverUrl) return;
    _serverUrl = baseUrl;
    _auth = null;
    _endReason = null;
    notifyListeners();
    _enqueue(() async {
      await _storage.delete(sessionStorageKey);
      await _storage.write(serverStorageKey, baseUrl);
    });
  }

  /// Completes when everything changed so far has reached the storage.
  Future<void> get settled => _writes;

  void _enqueue(Future<void> Function() action) {
    _writes = _writes.then((_) async {
      try {
        await action();
      } on Object catch (error) {
        // Nothing may break this chain: the writes that follow still have to happen.
        debugPrint('Armin Transport: could not update the stored state ($error).');
      }
    });
  }
}
