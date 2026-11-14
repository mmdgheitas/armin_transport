/// HTTP client for the Armin Transport API.
///
/// - Understands the response envelope `{ success, message, data, errors }`.
/// - Attaches the access token and renews it transparently. Refresh tokens rotate and
///   reuse revokes the whole session, so only one renewal runs at any time.
/// - Reports every failure as an [ApiError] with a Persian, user-presentable message.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show TlsException;
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_error.dart';
import 'models.dart';

/// Renew the access token this long before it expires, so requests are not sent with a dying token.
const Duration expirySkew = Duration(seconds: 20);

/// The `data` and `message` of a successful response.
class ApiResult {
  const ApiResult(this.data, this.message);

  final Object? data;
  final String message;

  Json get json => asJson(data);
}

class DownloadedFile {
  const DownloadedFile({required this.bytes, required this.filename, required this.contentType});

  final Uint8List bytes;
  final String filename;
  final String contentType;
}

/// One file of a multipart upload.
class UploadPart {
  const UploadPart({required this.filename, required this.bytes});

  final String filename;
  final List<int> bytes;
}

final DioMediaType _binary = DioMediaType('application', 'octet-stream');

final RegExp _extendedFilename = RegExp(r"filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)");
final RegExp _quotedFilename = RegExp(r'filename\s*=\s*"((?:[^"\\]|\\.)*)"');
final RegExp _plainFilename = RegExp(r'filename\s*=\s*([^;]+)');

/// Extracts the file name from a Content-Disposition header (RFC 6266 / RFC 5987).
String filenameFromContentDisposition(String? header, {String fallback = 'download'}) {
  if (header == null || header.isEmpty) return fallback;
  final extended = _extendedFilename.firstMatch(header);
  if (extended != null) {
    try {
      final decoded = Uri.decodeComponent(extended.group(1)!.trim());
      if (decoded.isNotEmpty) return decoded;
    } on ArgumentError {
      // A broken escape sequence: fall through to the plain parameter.
    } on FormatException {
      // Bytes that are not UTF-8: fall through to the plain parameter.
    }
  }
  final quoted = _quotedFilename.firstMatch(header);
  if (quoted != null) {
    final name = quoted.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (match) => match.group(1)!);
    return name.isEmpty ? fallback : name;
  }
  final plain = _plainFilename.firstMatch(header);
  final name = plain?.group(1)?.trim() ?? '';
  return name.isEmpty ? fallback : name;
}

class ApiClient {
  /// [readSession], [writeSession] and [endSession] connect the client to wherever the app keeps its session;
  /// [endSession] is called with `null` after a logout and with the reason when the server ends the session.
  ApiClient({
    required String baseUrl,
    required this._dio,
    required this._readSession,
    required this._writeSession,
    required this._endSession,
    this._now = DateTime.now,
  }) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  /// A [Dio] with the timeouts this client expects. Statuses are handled here, so none of them throws.
  static Dio createDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
      responseType: ResponseType.bytes,
      followRedirects: false,
      validateStatus: (_) => true,
    ),
  );

  final String baseUrl;
  final Dio _dio;
  final AuthSession? Function() _readSession;
  final void Function(AuthSession session) _writeSession;
  final void Function(ApiError? reason) _endSession;
  final DateTime Function() _now;

  Future<String>? _refreshInFlight;

  // -------------------------------------------------------------------------------------------- transport

  Future<Response<List<int>>> _send(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? json,
    List<UploadPart>? files,
    Map<String, String>? fields,
    String? token,
    ProgressCallback? onSendProgress,
  }) async {
    final headers = <String, dynamic>{'Accept': 'application/json'};
    if (token != null) headers['Authorization'] = 'Bearer $token';

    Object? body;
    String? contentType;
    if (json != null) {
      body = jsonEncode(json);
      contentType = Headers.jsonContentType;
    } else if (files != null) {
      // Built anew for every attempt: a form that has been sent cannot be sent again.
      final form = FormData();
      (fields ?? const <String, String>{}).forEach((name, value) => form.fields.add(MapEntry(name, value)));
      for (final file in files) {
        // The type is left generic on purpose: the server decides it from the extension and the content.
        form.files.add(
          MapEntry('files', MultipartFile.fromBytes(file.bytes, filename: file.filename, contentType: _binary)),
        );
      }
      body = form;
    }

    final cleanQuery = <String, dynamic>{};
    (query ?? const <String, Object?>{}).forEach((name, value) {
      if (value != null && value != '') cleanQuery[name] = value.toString();
    });

    try {
      return await _dio.request<List<int>>(
        '$baseUrl$path',
        data: body,
        queryParameters: cleanQuery.isEmpty ? null : cleanQuery,
        onSendProgress: onSendProgress,
        options: Options(
          method: method,
          headers: headers,
          contentType: contentType,
          responseType: ResponseType.bytes,
          // A redirect is reported instead of followed, so that tokens never travel to another address.
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (error) {
      throw _transportError(error);
    }
  }

  static ApiError _transportError(DioException error) {
    // Kept for diagnosis only; it is never shown to the user.
    final details = <String, dynamic>{'cause': '${error.type.name}: ${error.error ?? error.message ?? ''}'};
    if (error.type == DioExceptionType.badCertificate || error.error is TlsException) {
      return ApiError(
        code: 'network_error',
        message: 'گواهی امنیتی سرور تأیید نشد. نشانی سرور و تاریخ و ساعت دستگاه را بررسی کنید.',
        details: details,
      );
    }
    return ApiError(code: 'network_error', message: networkErrorMessage, details: details);
  }

  static bool _isOk(Response<List<int>> response) {
    final status = response.statusCode ?? 0;
    return status >= 200 && status < 300;
  }

  /// The response envelope, or `null` when the body is not one.
  static Json? _readEnvelope(Response<List<int>> response) {
    final contentType = response.headers.value(Headers.contentTypeHeader) ?? '';
    final bytes = response.data;
    if (!contentType.contains('json') || bytes == null) return null;
    try {
      final body = jsonDecode(utf8.decode(bytes));
      return body is Map && body['success'] is bool ? asJson(body) : null;
    } on FormatException {
      return null;
    }
  }

  static ApiError _toApiError(Response<List<int>> response) {
    final status = response.statusCode ?? 0;
    final envelope = _readEnvelope(response);
    if (envelope != null && envelope['success'] == false) {
      final errors = asJson(envelope['errors']);
      final message = envelope['message'];
      final code = errors['code'];
      return ApiError(
        status: status,
        code: code is String ? code : 'unknown_error',
        message: message is String && message.isNotEmpty ? message : unexpectedResponseMessage,
        details: errors,
      );
    }
    if (status >= 300 && status < 400) {
      return ApiError(
        status: status,
        code: 'redirected',
        message: 'سرور درخواست را به نشانی دیگری ارجاع داد. نشانی سرور را بررسی کنید.',
        details: <String, dynamic>{'location': response.headers.value('location') ?? ''},
      );
    }
    return ApiError(status: status, code: 'unexpected_response');
  }

  // -------------------------------------------------------------------------------------------- session

  /// Renews the tokens once, no matter how many requests ask at the same time. Completes with the new access token.
  Future<String> _refreshAccessToken() {
    final running = _refreshInFlight;
    if (running != null) return running;
    final started = _renew().whenComplete(() => _refreshInFlight = null);
    _refreshInFlight = started;
    return started;
  }

  Future<String> _renew() async {
    final current = _readSession();
    if (current == null) throw ApiError(status: 401, code: 'authentication_required', message: sessionEndedMessage);
    final response = await _send(
      'POST',
      '/auth/refresh',
      json: <String, dynamic>{'refresh_token': current.refreshToken},
    );
    if (!_isOk(response)) throw _toApiError(response);
    final renewed = AuthSession.fromAuthResponse(_readEnvelope(response)?['data'], _now());
    if (renewed == null) throw ApiError(status: response.statusCode ?? 0, code: 'unexpected_response');
    _writeSession(renewed);
    return renewed.accessToken;
  }

  void _end(ApiError reason) => _endSession(reason);

  Future<String> _renewOrEndSession() async {
    try {
      return await _refreshAccessToken();
    } on ApiError catch (error) {
      // Only a definite rejection ends the session; network failures and rate limits are transient.
      if (error.status == 401 || error.status == 403 || error.status == 422) {
        final ended = ApiError(status: 401, code: error.code, message: sessionEndedMessage, details: error.details);
        _end(ended);
        throw ended;
      }
      rethrow;
    }
  }

  Future<String> _accessToken() async {
    final current = _readSession();
    if (current == null) {
      final error = ApiError(status: 401, code: 'authentication_required', message: sessionEndedMessage);
      _end(error);
      throw error;
    }
    if (current.accessExpiresAt.difference(_now()) <= expirySkew) return _renewOrEndSession();
    return current.accessToken;
  }

  /// Sends a request with authentication and one transparent retry after a token renewal.
  Future<Response<List<int>>> _exchange(
    String method,
    String path, {
    required bool auth,
    Map<String, Object?>? query,
    Object? json,
    List<UploadPart>? files,
    Map<String, String>? fields,
    ProgressCallback? onSendProgress,
  }) async {
    Future<Response<List<int>>> attempt(String? token) => _send(
      method,
      path,
      query: query,
      json: json,
      files: files,
      fields: fields,
      token: token,
      onSendProgress: onSendProgress,
    );

    if (!auth) return attempt(null);
    final token = await _accessToken();
    var response = await attempt(token);
    if (response.statusCode != 401) return response;

    var error = _toApiError(response);
    if (error.code == 'token_expired') {
      response = await attempt(_newerToken(token) ?? await _renewOrEndSession());
      if (response.statusCode != 401) return response;
      error = _toApiError(response);
    }
    _end(error);
    throw error;
  }

  /// The access token another request obtained while the one using [rejected] was under way, if any.
  /// Using it avoids a second renewal for a token that has just been renewed.
  String? _newerToken(String rejected) {
    if (_refreshInFlight != null) return null; // the caller joins the renewal that is under way
    final current = _readSession();
    if (current == null || current.accessToken == rejected) return null;
    return current.accessExpiresAt.difference(_now()) > expirySkew ? current.accessToken : null;
  }

  // -------------------------------------------------------------------------------------------- requests

  /// Performs a JSON request and completes with the `data` and `message` of the envelope.
  Future<ApiResult> request(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? json,
    bool auth = true,
  }) async {
    final response = await _exchange(method, path, auth: auth, query: query, json: json);
    return _result(response);
  }

  ApiResult _result(Response<List<int>> response) {
    if (!_isOk(response)) throw _toApiError(response);
    final envelope = _readEnvelope(response);
    if (envelope == null || envelope['success'] != true) {
      throw ApiError(status: response.statusCode ?? 0, code: 'unexpected_response');
    }
    final message = envelope['message'];
    return ApiResult(envelope['data'], message is String ? message : '');
  }

  Future<ApiResult> get(String path, {Map<String, Object?>? query, bool auth = true}) =>
      request('GET', path, query: query, auth: auth);

  Future<ApiResult> post(String path, {Object? json, bool auth = true}) =>
      request('POST', path, json: json, auth: auth);

  Future<ApiResult> put(String path, {Object? json}) => request('PUT', path, json: json);

  Future<ApiResult> patch(String path, {Object? json}) => request('PATCH', path, json: json);

  Future<ApiResult> delete(String path) => request('DELETE', path);

  /// Sends files as `multipart/form-data` (the parts are named `files`, as the API expects).
  Future<ApiResult> upload(
    String path, {
    required List<UploadPart> files,
    Map<String, String> fields = const <String, String>{},
    void Function(int sent, int total)? onProgress,
  }) async {
    final response = await _exchange(
      'POST',
      path,
      auth: true,
      files: files,
      fields: fields,
      onSendProgress: onProgress,
    );
    return _result(response);
  }

  /// Downloads a file completely into memory.
  Future<DownloadedFile> download(String path, {bool auth = true}) async {
    final response = await _exchange('GET', path, auth: auth);
    if (!_isOk(response)) throw _toApiError(response);
    return DownloadedFile(
      bytes: Uint8List.fromList(response.data ?? const <int>[]),
      filename: filenameFromContentDisposition(response.headers.value('content-disposition')),
      contentType: response.headers.value(Headers.contentTypeHeader) ?? 'application/octet-stream',
    );
  }

  // -------------------------------------------------------------------------------------------- authentication

  Future<ApiResult> login(String username, String password) async {
    final result = await post(
      '/auth/login',
      auth: false,
      json: <String, dynamic>{'username': username, 'password': password},
    );
    final session = AuthSession.fromAuthResponse(result.data, _now());
    if (session == null) throw ApiError(code: 'unexpected_response');
    _writeSession(session);
    return result;
  }

  /// Revokes the session on the server (best effort) and always forgets it on this device.
  Future<void> logout() async {
    if (_readSession() == null) return;
    try {
      await post('/auth/logout');
    } on ApiError {
      // Without a connection the session cannot be revoked; it expires on the server on its own.
    } finally {
      _endSession(null);
    }
  }

  Future<ApiResult> changePassword(String currentPassword, String newPassword) async {
    final result = await post(
      '/auth/change-password',
      json: <String, dynamic>{'current_password': currentPassword, 'new_password': newPassword},
    );
    // Every other session of the user was revoked; this one continues with new tokens.
    final session = AuthSession.fromAuthResponse(result.data, _now());
    if (session != null) _writeSession(session);
    return result;
  }

  /// Reads the profile again, so that changed permissions and settings take effect.
  Future<void> refreshProfile() async {
    final result = await get('/auth/me');
    final current = _readSession();
    if (current != null) _writeSession(current.withProfile(result.data));
  }
}
