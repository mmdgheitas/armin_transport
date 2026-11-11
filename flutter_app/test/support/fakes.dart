/// Test doubles shared by the tests: a scripted HTTP transport, canned API responses and a clock.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:armin_transport/core/api/api_client.dart';
import 'package:armin_transport/core/api/api_error.dart';
import 'package:armin_transport/core/api/models.dart';
import 'package:dio/dio.dart';

/// One request as the transport received it.
class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.bodyBytes,
  });

  final String method;
  final Uri uri;

  /// Header names in lower case.
  final Map<String, String> headers;
  final Uint8List bodyBytes;

  String get path => uri.path;
  Map<String, String> get query => uri.queryParameters;
  String get bodyText => utf8.decode(bodyBytes);
  dynamic get json => jsonDecode(bodyText);
  String? get authorization => headers['authorization'];

  @override
  String toString() => '$method $uri';
}

typedef FakeHandler = FutureOr<ResponseBody> Function(RecordedRequest request);

/// A transport for [Dio] that answers from [handler] and records every request in [calls].
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  FakeHandler handler;
  final List<RecordedRequest> calls = <RecordedRequest>[];

  List<String> get paths => [for (final call in calls) call.path];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = BytesBuilder(copy: false);
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        body.add(chunk);
      }
    }
    final request = RecordedRequest(
      method: options.method,
      uri: options.uri,
      headers: {
        for (final entry in options.headers.entries)
          entry.key.toLowerCase(): '${entry.value}',
      },
      bodyBytes: body.takeBytes(),
    );
    calls.add(request);
    return handler(request);
  }

  @override
  void close({bool force = false}) {}
}

/// A [Dio] configured like the one of the app, answering from [adapter].
Dio fakeDio(FakeAdapter adapter) =>
    ApiClient.createDio()..httpClientAdapter = adapter;

const Map<String, List<String>> _jsonHeaders = {
  'content-type': ['application/json; charset=utf-8'],
};

ResponseBody jsonResponse(
  int status,
  Object? body, {
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {..._jsonHeaders, ...headers},
);

ResponseBody textResponse(
  int status,
  String body, {
  String contentType = 'text/html',
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    'content-type': [contentType],
  },
);

/// A successful response envelope.
ResponseBody ok(
  Object? data, {
  String message = 'انجام شد.',
  int status = 200,
}) => jsonResponse(status, {
  'success': true,
  'message': message,
  'data': data,
  'errors': null,
});

/// An error response envelope.
ResponseBody errorResponse(
  int status,
  String code, {
  String message = 'خطا',
  Map<String, dynamic> extra = const {},
}) => jsonResponse(status, {
  'success': false,
  'message': message,
  'data': null,
  'errors': {'code': code, 'request_id': 'req-test-0001', ...extra},
});

/// One page of a list, as the API sends it.
Json pageOf(List<Object?> items, {int page = 1, int perPage = 20, int? total}) {
  final count = total ?? items.length;
  final pages = count == 0 ? 0 : ((count - 1) ~/ perPage) + 1;
  return {
    'items': items,
    'pagination': {
      'page': page,
      'per_page': perPage,
      'total': count,
      'total_pages': pages,
      'has_next': page < pages,
      'has_prev': page > 1,
    },
  };
}

const List<String> employeePermissions = [
  'dashboard:view',
  'shipment:view',
  'shipment:create',
  'shipment:update',
  'shipment:archive',
  'tracking_code:generate',
  'tracking_code:change',
  'tracking_code:history',
  'document:view',
  'document:upload',
  'document:download',
  'document:set_visibility',
  'product_field:view',
  'product_value:view',
  'product_value:edit',
  'customer_session:revoke',
];

const List<String> adminPermissions = [
  ...employeePermissions,
  'scope:global',
  'company:view',
  'company:create',
  'company:update',
  'company:set_active',
  'user:view',
  'user:create',
  'user:update',
  'user:set_active',
  'user:reset_password',
  'shipment:unarchive',
  'tracking_code:manual',
  'document:delete',
  'product_field:manage',
  'audit_log:view',
];

const Json employeeUser = {
  'id': 'u1',
  'username': 'armin.operator',
  'full_name': 'سارا محمدی',
  'role': 'EMPLOYEE',
  'is_active': true,
  'company_id': 'c1',
  'company': {
    'id': 'c1',
    'name': 'حمل‌ونقل ',
    'company_code': 'ARMIN',
    'is_active': true,
  },
};

const Json adminUser = {
  'id': 'u0',
  'username': 'admin',
  'full_name': 'مدیر سامانه',
  'role': 'SUPER_ADMIN',
  'is_active': true,
  'company_id': null,
  'company': null,
};

const Json appSettings = {
  'upload': {
    'max_file_size_bytes': 10485760,
    'max_files_per_upload': 10,
    'allowed_extensions': ['pdf', 'jpg', 'jpeg', 'png', 'docx', 'xlsx'],
    'customer_visible_default': true,
  },
  'tracking_code': {
    'min_length': 6,
    'max_length': 64,
    'pattern': r'^[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?$',
  },
  'password': {'min_length': 10},
  'pagination': {'default_page_size': 20, 'max_page_size': 100},
};

/// The `data` of a login or refresh response. [suffix] makes the tokens of each generation distinct.
Json authPayload([String suffix = '1', Json overrides = const {}]) => {
  'access_token': 'access-$suffix',
  'refresh_token': 'refresh-token-$suffix-padding-padding',
  'token_type': 'Bearer',
  'expires_in': 900,
  'refresh_expires_in': 1209600,
  'user': employeeUser,
  'permissions': employeePermissions,
  'app_settings': appSettings,
  ...overrides,
};

Json adminAuthPayload([String suffix = '1']) => authPayload(suffix, const {
  'user': adminUser,
  'permissions': adminPermissions,
});

/// A clock that only moves when a test says so.
class FakeClock {
  FakeClock([DateTime? start])
    : now = start ?? DateTime.utc(2026, 11, 10, 8, 30);

  DateTime now;

  DateTime call() => now;

  void advance(Duration duration) => now = now.add(duration);
}

/// An [ApiClient] on a fake transport, with the session kept in a variable as the app would keep it.
class ClientHarness {
  ClientHarness(
    FakeHandler handler, {
    bool signedIn = true,
    FakeClock? clock,
    String baseUrl = 'https://armin.test/api/v1/',
  }) : adapter = FakeAdapter(handler),
       clock = clock ?? FakeClock() {
    if (signedIn)
      session = AuthSession.fromAuthResponse(authPayload(), this.clock.now);
    api = ApiClient(
      baseUrl: baseUrl,
      dio: fakeDio(adapter),
      readSession: () => session,
      writeSession: (next) => session = next,
      endSession: (reason) {
        session = null;
        ended.add(reason);
      },
      now: this.clock.call,
    );
  }

  final FakeAdapter adapter;
  final FakeClock clock;
  late final ApiClient api;
  AuthSession? session;

  /// The reasons the client gave for ending the session, in order (`null` for a logout).
  final List<ApiError?> ended = <ApiError?>[];

  List<RecordedRequest> get calls => adapter.calls;
}
