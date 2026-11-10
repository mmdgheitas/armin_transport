/// Small key-value storage for what the app remembers between starts: the session and the server address.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class AppStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Encrypted storage of the platform. On Android the values are encrypted with a key of the Android Keystore;
/// on Windows each value is an AES-GCM encrypted file in the data folder of the app, and the key is kept in the
/// Credential Manager of the signed-in Windows user.
class SecureAppStorage implements AppStorage {
  const SecureAppStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Keeps everything in memory: for tests, and as the fallback when the platform storage fails.
class MemoryAppStorage implements AppStorage {
  MemoryAppStorage([Map<String, String>? initial]) : values = <String, String>{...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

// Plain ASCII names: on Windows every key becomes a file name.
const String sessionStorageKey = 'armin_transport_session_v1';
const String serverStorageKey = 'armin_transport_server_v1';
