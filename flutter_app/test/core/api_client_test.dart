import 'dart:convert';
import 'dart:io';

import 'package:armin_transport/core/api/api_client.dart';
import 'package:armin_transport/core/api/api_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// Runs [action] and returns the [ApiError] it fails with.
Future<ApiError> errorOf(Future<Object?> Function() action) async {
  try {
    await action();
  } on ApiError catch (error) {
    return error;
  }
  fail('Expected an ApiError.');
}

const Duration tokenLifetime = Duration(seconds: 900);

void main() {
  test('sends JSON with the bearer token and unwraps the envelope', () async {
    final harness = ClientHarness((request) => ok({'id': 's1'}, message: 'محموله ثبت شد.', status: 201));
    final result = await harness.api.request(
      'POST',
      '/shipments',
      json: {'description': 'بار'},
      query: {'dry': '', 'page': 2, 'skip': null, 'active': true},
    );
    expect(result.data, {'id': 's1'});
    expect(result.json['id'], 's1');
    expect(result.message, 'محموله ثبت شد.');

    final call = harness.calls.single;
    expect(call.method, 'POST');
    expect(call.uri.toString(), 'https://armin.test/api/v1/shipments?page=2&active=true');
    expect(call.authorization, 'Bearer access-1');
    expect(call.headers['content-type'], startsWith('application/json'));
    expect(call.headers['accept'], 'application/json');
    expect(call.json, {'description': 'بار'});
    expect(harness.ended, isEmpty);
  });

  test('public requests carry no token and work without a session', () async {
    final harness = ClientHarness((request) => ok({'access_token': 'customer'}), signedIn: false);
    await harness.api.post('/customer/lookup', auth: false, json: {'tracking_code': 'ABCD-1234'});
    expect(harness.calls.single.authorization, isNull);
    expect(harness.ended, isEmpty);
  });

  test('a request without a body sends none', () async {
    final harness = ClientHarness((request) => ok(null));
    await harness.api.post('/shipments/s1/archive');
    expect(harness.calls.single.bodyBytes, isEmpty);
    await harness.api.delete('/documents/d1');
    expect(harness.calls.last.method, 'DELETE');
    await harness.api.put('/x', json: {'values': <String, dynamic>{}});
    expect(harness.calls.last.method, 'PUT');
    await harness.api.patch('/x', json: {'description': null});
    expect(harness.calls.last.method, 'PATCH');
    expect(harness.calls.last.json, {'description': null});
  });

  test('turns error envelopes into ApiError', () async {
    final harness = ClientHarness(
      (request) => errorResponse(
        422,
        'validation_error',
        message: 'اطلاعات واردشده معتبر نیست.',
        extra: {
          'fields': {
            'username': ['الزامی است.'],
            'password': ['کوتاه است.', 'باید رقم داشته باشد.'],
          },
        },
      ),
    );
    final error = await errorOf(() => harness.api.post('/users', json: <String, dynamic>{}));
    expect(error.status, 422);
    expect(error.code, 'validation_error');
    expect(error.message, 'اطلاعات واردشده معتبر نیست.');
    expect(error.fields, {'username': 'الزامی است.', 'password': 'کوتاه است. باید رقم داشته باشد.'});
    expect(error.requestId, 'req-test-0001');
    expect(error.isValidation, isTrue);
    expect(error.isNotFound, isFalse);
    expect(error.isNetworkError, isFalse);
    expect(error.toString(), contains('validation_error'));
  });

  test('exposes rate-limit details and keeps the session on 429 and 403', () async {
    final limited = ClientHarness(
      (request) => errorResponse(429, 'rate_limited', message: 'تعداد درخواست‌ها بیش از حد مجاز است.', extra: {'retry_after_seconds': 42}),
    );
    final tooMany = await errorOf(() => limited.api.get('/shipments'));
    expect(tooMany.retryAfterSeconds, 42);
    expect(tooMany.status, 429);
    expect(limited.session, isNotNull); // a rate limit never ends the session

    final denied = ClientHarness((request) => errorResponse(403, 'permission_denied', message: 'اجازهٔ این کار را ندارید.'));
    final forbidden = await errorOf(() => denied.api.get('/users'));
    expect(forbidden.isForbidden, isTrue);
    expect(denied.session, isNotNull);
    expect(denied.ended, isEmpty);
  });

  test('reports network failures and non-JSON responses with Persian messages', () async {
    final offline = ClientHarness((request) => throw const SocketException('Connection refused'));
    final unreachable = await errorOf(() => offline.api.get('/shipments'));
    expect(unreachable.code, 'network_error');
    expect(unreachable.isNetworkError, isTrue);
    expect(unreachable.status, 0);
    expect(unreachable.message, contains('ارتباط با سرور'));
    expect(unreachable.toString(), contains('Connection refused')); // the cause is kept for diagnosis
    expect(offline.session, isNotNull);

    final gateway = ClientHarness((request) => textResponse(502, '<html>502 Bad Gateway</html>'));
    final badGateway = await errorOf(() => gateway.api.get('/shipments'));
    expect((badGateway.code, badGateway.status), ('unexpected_response', 502));
    expect(badGateway.message, contains('پاسخ نامعتبر'));

    final liar = ClientHarness((request) => jsonResponse(200, {'unexpected': true}));
    expect((await errorOf(() => liar.api.get('/shipments'))).code, 'unexpected_response');

    final broken = ClientHarness((request) => textResponse(200, '{not json', contentType: 'application/json'));
    expect((await errorOf(() => broken.api.get('/shipments'))).code, 'unexpected_response');

    final page = ClientHarness((request) => textResponse(200, '<html>login</html>'));
    expect((await errorOf(() => page.api.get('/shipments'))).code, 'unexpected_response');
  });

  test('reports a certificate problem in its own words', () async {
    final harness = ClientHarness(
      (request) => throw DioException.badCertificate(requestOptions: RequestOptions(path: '/x')),
    );
    final error = await errorOf(() => harness.api.get('/shipments'));
    expect(error.code, 'network_error');
    expect(error.message, contains('گواهی'));
  });

  test('reports a redirect instead of following it', () async {
    final harness = ClientHarness(
      (request) => ResponseBody.fromString(
        '',
        308,
        headers: {
          'location': ['https://elsewhere.test/api/v1/shipments'],
        },
      ),
    );
    final error = await errorOf(() => harness.api.get('/shipments'));
    expect(error.code, 'redirected');
    expect(error.status, 308);
    expect(error.details['location'], 'https://elsewhere.test/api/v1/shipments');
    expect(harness.calls, hasLength(1));
    expect(harness.session, isNotNull);
  });

  test('renews an expired access token once and retries the request', () async {
    var refreshed = false;
    final harness = ClientHarness((request) {
      if (request.path == '/api/v1/auth/refresh') {
        refreshed = true;
        expect(request.json, {'refresh_token': 'refresh-token-1-padding-padding'});
        expect(request.authorization, isNull);
        return ok(authPayload('2'));
      }
      return refreshed && request.authorization == 'Bearer access-2'
          ? ok({'items': <Object>[]})
          : errorResponse(401, 'token_expired', message: 'توکن منقضی شده است.');
    });
    final result = await harness.api.get('/shipments');
    expect(result.data, {'items': <Object>[]});
    expect(harness.adapter.paths, ['/api/v1/shipments', '/api/v1/auth/refresh', '/api/v1/shipments']);
    expect(harness.session!.accessToken, 'access-2');
    expect(harness.session!.refreshToken, 'refresh-token-2-padding-padding');
    expect(harness.ended, isEmpty);
  });

  test('renews proactively when the token is about to expire', () async {
    final harness = ClientHarness(
      (request) => request.path.endsWith('/auth/refresh') ? ok(authPayload('2')) : ok({'fine': true}),
    );
    harness.clock.advance(tokenLifetime - const Duration(seconds: 10)); // ten seconds left
    await harness.api.get('/dashboard/summary');
    expect(harness.adapter.paths, ['/api/v1/auth/refresh', '/api/v1/dashboard/summary']);
    expect(harness.calls[1].authorization, 'Bearer access-2');
    // The lifetime of the new token is counted from the moment it arrived.
    expect(harness.session!.accessExpiresAt, harness.clock.now.add(tokenLifetime));
  });

  test('does not renew while the token is still good', () async {
    final harness = ClientHarness((request) => ok({'fine': true}));
    harness.clock.advance(tokenLifetime - const Duration(seconds: 21));
    await harness.api.get('/dashboard/summary');
    expect(harness.adapter.paths, ['/api/v1/dashboard/summary']);
  });

  test('concurrent requests share a single renewal (refresh tokens are single-use)', () async {
    var refreshCalls = 0;
    final harness = ClientHarness((request) async {
      if (request.path.endsWith('/auth/refresh')) {
        refreshCalls += 1;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return ok(authPayload('2'));
      }
      return request.authorization == 'Bearer access-2' ? ok({'path': request.path}) : errorResponse(401, 'token_expired');
    });
    harness.clock.advance(tokenLifetime); // expired locally: all five requests need a renewal first
    final results = await Future.wait([for (final path in ['/a', '/b', '/c', '/d', '/e']) harness.api.get(path)]);
    expect(refreshCalls, 1);
    expect([for (final result in results) result.json['path']], [
      '/api/v1/a',
      '/api/v1/b',
      '/api/v1/c',
      '/api/v1/d',
      '/api/v1/e',
    ]);
    final others = harness.calls.where((call) => !call.path.endsWith('/auth/refresh'));
    expect(others.every((call) => call.authorization == 'Bearer access-2'), isTrue);
  });

  test('requests rejected at the same moment share a single renewal as well', () async {
    var refreshCalls = 0;
    final harness = ClientHarness((request) async {
      if (request.path.endsWith('/auth/refresh')) {
        refreshCalls += 1;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return ok(authPayload('2'));
      }
      return request.authorization == 'Bearer access-2' ? ok({'path': request.path}) : errorResponse(401, 'token_expired');
    });
    // The device believes the token is good, the server does not (for example after a clock change).
    final results = await Future.wait([for (final path in ['/a', '/b', '/c']) harness.api.get(path)]);
    expect(refreshCalls, 1);
    expect(results, hasLength(3));
    expect(harness.ended, isEmpty);
  });

  test('a request rejected after another one renewed the tokens reuses the new token', () async {
    var refreshCalls = 0;
    final harness = ClientHarness((request) async {
      if (request.path.endsWith('/auth/refresh')) {
        refreshCalls += 1;
        return ok(authPayload('2'));
      }
      if (request.authorization == 'Bearer access-2') return ok({'path': request.path});
      // The slow request is answered only after the fast one has renewed the tokens.
      if (request.path.endsWith('/slow')) await Future<void>.delayed(const Duration(milliseconds: 30));
      return errorResponse(401, 'token_expired');
    });
    final results = await Future.wait([harness.api.get('/slow'), harness.api.get('/fast')]);
    expect(refreshCalls, 1);
    expect([for (final result in results) result.json['path']], ['/api/v1/slow', '/api/v1/fast']);
    expect(harness.session!.accessToken, 'access-2');
    expect(harness.ended, isEmpty);
  });

  test('a second renewal happens when the renewed token expires again later', () async {
    var generation = 1;
    final harness = ClientHarness((request) {
      if (request.path.endsWith('/auth/refresh')) {
        generation += 1;
        expect(request.json, {'refresh_token': 'refresh-token-${generation - 1}-padding-padding'});
        return ok(authPayload('$generation'));
      }
      return ok(<String, dynamic>{});
    });
    harness.clock.advance(tokenLifetime);
    await harness.api.get('/a');
    harness.clock.advance(tokenLifetime);
    await harness.api.get('/b');
    expect(harness.calls.where((call) => call.path.endsWith('/auth/refresh')), hasLength(2));
    expect(harness.calls.last.authorization, 'Bearer access-3');
  });

  test('ends the session when the refresh token is rejected', () async {
    final harness = ClientHarness(
      (request) => request.path.endsWith('/auth/refresh')
          ? errorResponse(401, 'refresh_token_invalid', message: 'نشست معتبر نیست.')
          : errorResponse(401, 'token_expired', message: 'توکن منقضی شده است.'),
    );
    final error = await errorOf(() => harness.api.get('/shipments'));
    expect(error.status, 401);
    expect(error.code, 'refresh_token_invalid');
    expect(error.message, contains('دوباره وارد شوید'));
    expect(harness.session, isNull);
    expect(harness.ended, hasLength(1));
    expect(harness.ended.single!.message, contains('دوباره وارد شوید'));
    expect(harness.calls, hasLength(2)); // the original request is not retried
  });

  test('keeps the session when the renewal fails for a transient reason', () async {
    final transients = <FakeHandler>[
      (request) => throw const SocketException('offline'),
      (request) => errorResponse(429, 'rate_limited', message: 'بعداً تلاش کنید.', extra: {'retry_after_seconds': 5}),
      (request) => errorResponse(503, 'service_unavailable', message: 'سرویس در دسترس نیست.'),
      (request) => textResponse(502, 'Bad Gateway'),
    ];
    for (final transient in transients) {
      final harness = ClientHarness(
        (request) => request.path.endsWith('/auth/refresh') ? transient(request) : errorResponse(401, 'token_expired'),
      );
      await errorOf(() => harness.api.get('/shipments'));
      expect(harness.session, isNotNull);
      expect(harness.ended, isEmpty);
    }
  });

  test('a renewal that answers without tokens does not end the session', () async {
    final harness = ClientHarness(
      (request) => request.path.endsWith('/auth/refresh') ? ok({'nothing': true}) : errorResponse(401, 'token_expired'),
    );
    final error = await errorOf(() => harness.api.get('/shipments'));
    expect(error.code, 'unexpected_response');
    expect(harness.session, isNotNull);
  });

  test('ends the session for revoked tokens and disabled accounts without trying to renew', () async {
    for (final code in ['token_revoked', 'token_invalid', 'account_disabled', 'company_inactive', 'authentication_required']) {
      final harness = ClientHarness((request) => errorResponse(401, code, message: 'دسترسی ندارید.'));
      final error = await errorOf(() => harness.api.get('/shipments'));
      expect(error.code, code);
      expect(harness.session, isNull, reason: code);
      expect(harness.ended, hasLength(1));
      expect(harness.calls, hasLength(1));
    }
  });

  test('ends the session when the renewed token is rejected as well', () async {
    final harness = ClientHarness(
      (request) => request.path.endsWith('/auth/refresh') ? ok(authPayload('2')) : errorResponse(401, 'token_expired'),
    );
    final error = await errorOf(() => harness.api.get('/shipments'));
    expect(error.code, 'token_expired');
    expect(harness.calls, hasLength(3)); // exactly one retry: no renewal loop
    expect(harness.session, isNull);
    expect(harness.ended, hasLength(1));
  });

  test('authenticated requests without a session fail fast', () async {
    final harness = ClientHarness((request) => ok(<String, dynamic>{}), signedIn: false);
    final error = await errorOf(() => harness.api.get('/shipments'));
    expect((error.status, error.code), (401, 'authentication_required'));
    expect(harness.calls, isEmpty);
    expect(harness.ended, hasLength(1));
  });

  test('login stores the session; a failed login does not', () async {
    final good = ClientHarness((request) {
      expect(request.json, {'username': 'admin', 'password': 'secret-password'});
      expect(request.authorization, isNull);
      return ok(authPayload('9'), message: 'خوش آمدید.');
    }, signedIn: false);
    final result = await good.api.login('admin', 'secret-password');
    expect(result.message, 'خوش آمدید.');
    expect(good.session!.accessToken, 'access-9');
    expect(good.session!.user.username, 'armin.operator');
    expect(good.session!.can('shipment:view'), isTrue);
    expect(good.session!.refreshExpiresAt, good.clock.now.add(const Duration(seconds: 1209600)));

    final bad = ClientHarness(
      (request) => errorResponse(401, 'invalid_credentials', message: 'نام کاربری یا رمز عبور نادرست است.'),
      signedIn: false,
    );
    final error = await errorOf(() => bad.api.login('admin', 'wrong'));
    expect(error.code, 'invalid_credentials');
    expect(bad.session, isNull);
    expect(bad.ended, isEmpty); // a wrong password is not an "ended session"

    final empty = ClientHarness((request) => ok({'user': employeeUser}), signedIn: false);
    expect((await errorOf(() => empty.api.login('admin', 'x'))).code, 'unexpected_response');
    expect(empty.session, isNull);
  });

  test('logout always forgets the session on the device', () async {
    final normal = ClientHarness((request) => ok(null, message: 'خارج شدید.'));
    await normal.api.logout();
    expect(normal.session, isNull);
    expect(normal.calls.single.path, '/api/v1/auth/logout');
    expect(normal.calls.single.authorization, 'Bearer access-1');
    expect(normal.ended, [null]); // ended on purpose: there is nothing to tell the user

    final offline = ClientHarness((request) => throw const SocketException('offline'));
    await offline.api.logout();
    expect(offline.session, isNull);

    final rejected = ClientHarness((request) => errorResponse(401, 'token_revoked'));
    await rejected.api.logout();
    expect(rejected.session, isNull);

    final anonymous = ClientHarness((request) => ok(null), signedIn: false);
    await anonymous.api.logout();
    expect(anonymous.calls, isEmpty);
    expect(anonymous.ended, isEmpty);
  });

  test('change-password replaces the tokens and refreshProfile updates the permissions', () async {
    final harness = ClientHarness((request) {
      if (request.path.endsWith('/auth/change-password')) {
        expect(request.json, {'current_password': 'old-password', 'new_password': 'new-password-1'});
        return ok(authPayload('5'), message: 'رمز عبور تغییر کرد.');
      }
      return ok({
        'user': {...employeeUser, 'full_name': 'نام جدید'},
        'permissions': ['shipment:view', 'document:delete'],
      });
    });
    final changed = await harness.api.changePassword('old-password', 'new-password-1');
    expect(changed.message, 'رمز عبور تغییر کرد.');
    expect(harness.session!.refreshToken, 'refresh-token-5-padding-padding');

    await harness.api.refreshProfile();
    expect(harness.calls.last.path, '/api/v1/auth/me');
    expect(harness.session!.user.fullName, 'نام جدید');
    expect(harness.session!.can('document:delete'), isTrue);
    expect(harness.session!.can('dashboard:view'), isFalse);
    expect(harness.session!.accessToken, 'access-5'); // the tokens are untouched
    expect(harness.session!.settings.passwordMinLength, 10); // settings missing from the answer are kept
  });

  test('downloads files with the names the server gives them', () async {
    final pdf = utf8.encode('%PDF-1.7 \u0000\u0001');
    final harness = ClientHarness(
      (request) => ResponseBody.fromBytes(
        pdf,
        200,
        headers: {
          'content-type': ['application/pdf'],
          'content-disposition': [
            "attachment; filename=barnameh.pdf; filename*=UTF-8''%D8%A8%D8%A7%D8%B1%D9%86%D8%A7%D9%85%D9%87.pdf",
          ],
        },
      ),
    );
    final file = await harness.api.download('/documents/d1/download');
    expect(file.filename, 'بارنامه.pdf');
    expect(file.contentType, 'application/pdf');
    expect(file.bytes, pdf);
    expect(harness.calls.single.authorization, 'Bearer access-1');

    final customer = ClientHarness(
      (request) => errorResponse(404, 'document_not_found', message: 'سند در دسترس نیست.'),
      signedIn: false,
    );
    final error = await errorOf(() => customer.api.download('/customer/access/token/documents/d1/download', auth: false));
    expect(error.isNotFound, isTrue);
    expect(error.message, 'سند در دسترس نیست.');
    expect(customer.calls.single.authorization, isNull);
  });

  test('uploads files as multipart form data and builds the form again for a retry', () async {
    var attempts = 0;
    final harness = ClientHarness((request) {
      if (request.path.endsWith('/auth/refresh')) return ok(authPayload('2'));
      attempts += 1;
      return attempts == 1 ? errorResponse(401, 'token_expired') : ok(<Object>[], message: 'بارگذاری شد.', status: 201);
    });
    final progress = <(int, int)>[];
    final result = await harness.api.upload(
      '/shipments/s1/documents',
      files: [
        UploadPart(filename: 'بارنامه ۱.pdf', bytes: utf8.encode('%PDF-first')),
        const UploadPart(filename: 'photo.jpg', bytes: [0xff, 0xd8, 0xff, 0xe0]),
      ],
      fields: {'customer_visible': 'false'},
      onProgress: (sent, total) => progress.add((sent, total)),
    );
    expect(result.message, 'بارگذاری شد.');
    expect(harness.adapter.paths, [
      '/api/v1/shipments/s1/documents',
      '/api/v1/auth/refresh',
      '/api/v1/shipments/s1/documents',
    ]);

    final first = harness.calls.first;
    final second = harness.calls.last;
    expect(second.authorization, 'Bearer access-2');
    for (final call in [first, second]) {
      expect(call.method, 'POST');
      final contentType = call.headers['content-type']!;
      expect(contentType, startsWith('multipart/form-data; boundary='));
      final boundary = contentType.split('boundary=').last;
      final body = utf8.decode(call.bodyBytes, allowMalformed: true);
      expect('--$boundary'.allMatches(body), hasLength(4)); // three parts and the closing line
      expect(body, contains('name="customer_visible"'));
      expect(body, contains('name="files"; filename="بارنامه ۱.pdf"'));
      expect(body, contains('name="files"; filename="photo.jpg"'));
      expect(body, contains('%PDF-first'));
      // The type is left to the server, which checks the extension and the content.
      expect('content-type: application/octet-stream'.allMatches(body), hasLength(2));
    }
    // The second attempt carries the complete body again.
    expect(second.bodyBytes.length, first.bodyBytes.length);
    expect(progress, isNotEmpty);
    expect(progress.last.$1, progress.last.$2);
  });

  test('trims the base address and keeps the path as given', () async {
    final harness = ClientHarness((request) => ok(null), baseUrl: 'http://192.168.1.10:5000/api/v1///');
    expect(harness.api.baseUrl, 'http://192.168.1.10:5000/api/v1');
    await harness.api.get('/shipments', query: {'q': 'یخچال ۲'});
    expect(harness.calls.single.uri.toString(), startsWith('http://192.168.1.10:5000/api/v1/shipments?q='));
    expect(harness.calls.single.query, {'q': 'یخچال ۲'});
  });

  test('parses Content-Disposition file names', () {
    expect(filenameFromContentDisposition('attachment; filename="report 1.pdf"'), 'report 1.pdf');
    expect(filenameFromContentDisposition('attachment; filename=plain.txt'), 'plain.txt');
    expect(filenameFromContentDisposition(r'attachment; filename="a \"quoted\" name.pdf"'), 'a "quoted" name.pdf');
    expect(filenameFromContentDisposition("attachment; filename*=UTF-8''%D8%B3%D9%86%D8%AF.pdf"), 'سند.pdf');
    expect(filenameFromContentDisposition("attachment; filename*=utf-8''a%20b.pdf"), 'a b.pdf');
    expect(
      filenameFromContentDisposition("attachment; filename=fallback.pdf; filename*=UTF-8''%E0%A4%A"),
      'fallback.pdf',
    );
    expect(filenameFromContentDisposition("attachment; filename=fallback.pdf; filename*=UTF-8''%FF%FE"), 'fallback.pdf');
    expect(filenameFromContentDisposition(null), 'download');
    expect(filenameFromContentDisposition('attachment'), 'download');
    expect(filenameFromContentDisposition('attachment; filename=""'), 'download');
    expect(filenameFromContentDisposition('', fallback: 'سند'), 'سند');
  });
}
