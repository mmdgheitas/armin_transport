// The API client over real sockets: a local HTTP server stands in for the backend.
// These tests cover what a scripted transport cannot show: the bytes on the wire.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:armin_transport/core/api/api_client.dart';
import 'package:armin_transport/core/api/api_error.dart';
import 'package:armin_transport/core/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// One part of a multipart body.
class Part {
  Part(this.headers, this.content);

  final String headers;
  final List<int> content;
}

int _indexOf(List<int> haystack, List<int> needle, int start) {
  for (var index = start; index <= haystack.length - needle.length; index += 1) {
    var found = true;
    for (var offset = 0; offset < needle.length; offset += 1) {
      if (haystack[index + offset] != needle[offset]) {
        found = false;
        break;
      }
    }
    if (found) return index;
  }
  return -1;
}

/// Splits a multipart body on its boundary, byte by byte (file content is not text).
List<Part> parseMultipart(List<int> body, String boundary) {
  final delimiter = ascii.encode('--$boundary');
  final blankLine = ascii.encode('\r\n\r\n');
  final parts = <Part>[];
  var position = _indexOf(body, delimiter, 0);
  while (position >= 0) {
    final start = position + delimiter.length;
    if (body[start] == 0x2d && body[start + 1] == 0x2d) break; // the closing "--"
    final next = _indexOf(body, delimiter, start);
    if (next < 0) break;
    final headerEnd = _indexOf(body, blankLine, start);
    final headers = utf8.decode(body.sublist(start + 2, headerEnd));
    final content = body.sublist(headerEnd + 4, next - 2); // without the line break before the delimiter
    parts.add(Part(headers, content));
    position = next;
  }
  return parts;
}

void main() {
  late HttpServer server;
  late String baseUrl;
  late Future<void> Function(HttpRequest request, Uint8List body) respond;
  final received = <({String method, String path, Map<String, String> headers, Uint8List body})>[];

  setUp(() async {
    received.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}/api/v1';
    server.listen((request) async {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in request) {
        builder.add(chunk);
      }
      final body = builder.takeBytes();
      final headers = <String, String>{};
      request.headers.forEach((name, values) => headers[name] = values.join(', '));
      received.add((method: request.method, path: request.uri.toString(), headers: headers, body: body));
      await respond(request, body);
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  void sendJson(HttpRequest request, int status, Object? body) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType('application', 'json', charset: 'utf-8')
      ..add(utf8.encode(jsonEncode(body)));
  }

  ({ApiClient api, List<ApiError?> ended, AuthSession? Function() session}) client({bool signedIn = true}) {
    AuthSession? session = signedIn ? AuthSession.fromAuthResponse(authPayload(), DateTime.now()) : null;
    final ended = <ApiError?>[];
    final dio = ApiClient.createDio();
    addTearDown(dio.close);
    final api = ApiClient(
      baseUrl: baseUrl,
      dio: dio,
      readSession: () => session,
      writeSession: (next) => session = next,
      endSession: (reason) {
        session = null;
        ended.add(reason);
      },
    );
    return (api: api, ended: ended, session: () => session);
  }

  test('exchanges JSON in UTF-8 with the bearer token', () async {
    respond = (request, body) async {
      sendJson(request, 201, {
        'success': true,
        'message': 'محموله ثبت شد.',
        'data': {'id': 's1', 'echo': jsonDecode(utf8.decode(body))},
        'errors': null,
      });
    };
    final result = await client().api.request(
      'POST',
      '/shipments',
      json: {'description': 'دو پالت یخچال ۲۴ فوت'},
      query: {'q': 'یخچال', 'page': 2},
    );
    expect(result.message, 'محموله ثبت شد.');
    expect(result.json['echo'], {'description': 'دو پالت یخچال ۲۴ فوت'});

    final request = received.single;
    expect(request.method, 'POST');
    expect(Uri.parse(request.path).path, '/api/v1/shipments');
    expect(Uri.parse(request.path).queryParameters, {'q': 'یخچال', 'page': '2'});
    expect(request.headers['authorization'], 'Bearer access-1');
    expect(request.headers['content-type'], startsWith('application/json'));
    expect(request.headers['accept'], 'application/json');
    expect(request.headers['content-length'], '${request.body.length}');
  });

  test('uploads files as a multipart form the server can take apart', () async {
    late String contentType;
    respond = (request, body) async {
      contentType = request.headers.value('content-type') ?? '';
      sendJson(request, 201, {'success': true, 'message': 'بارگذاری شد.', 'data': <Object>[], 'errors': null});
    };
    final binary = Uint8List.fromList([for (var index = 0; index < 3000; index += 1) index % 256]);
    final sent = <int>[];
    final result = await client().api.upload(
      '/shipments/s1/documents',
      files: [
        UploadPart(filename: 'بارنامه ۱.pdf', bytes: utf8.encode('%PDF-1.7\r\n--not-a-boundary\r\n')),
        UploadPart(filename: 'scan.png', bytes: binary),
      ],
      fields: {'customer_visible': 'true'},
      onProgress: (count, total) => sent.add(count),
    );
    expect(result.message, 'بارگذاری شد.');

    final request = received.single;
    expect(request.method, 'POST');
    expect(contentType, startsWith('multipart/form-data; boundary='));
    expect(request.headers['content-length'], '${request.body.length}');
    final parts = parseMultipart(request.body, contentType.split('boundary=').last);
    expect(parts, hasLength(3));

    expect(parts[0].headers.toLowerCase(), contains('content-disposition: form-data; name="customer_visible"'));
    expect(utf8.decode(parts[0].content), 'true');

    expect(parts[1].headers, contains('name="files"; filename="بارنامه ۱.pdf"'));
    expect(parts[1].headers.toLowerCase(), contains('content-type: application/octet-stream'));
    expect(utf8.decode(parts[1].content), '%PDF-1.7\r\n--not-a-boundary\r\n');

    expect(parts[2].headers, contains('name="files"; filename="scan.png"'));
    expect(parts[2].content, binary);
    expect(sent.last, request.body.length);
  });

  test('downloads binary content with a Persian file name', () async {
    final content = Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x00, 0xff, 0xfe, 0x0d, 0x0a]);
    respond = (request, body) async {
      request.response
        ..statusCode = 200
        ..headers.set('Content-Type', 'application/pdf')
        ..headers.set(
          'Content-Disposition',
          "attachment; filename=\"download.pdf\"; filename*=UTF-8''%D8%A8%D8%A7%D8%B1%D9%86%D8%A7%D9%85%D9%87.pdf",
        )
        ..add(content);
    };
    final file = await client().api.download('/documents/d1/download');
    expect(file.bytes, content);
    expect(file.filename, 'بارنامه.pdf');
    expect(file.contentType, 'application/pdf');
  });

  test('does not follow a redirect, so the token never reaches another address', () async {
    respond = (request, body) async {
      if (request.uri.path.endsWith('/elsewhere')) {
        sendJson(request, 200, {'success': true, 'message': '', 'data': null, 'errors': null});
      } else {
        request.response
          ..statusCode = 302
          ..headers.set('Location', 'http://127.0.0.1:${server.port}/api/v1/elsewhere');
      }
    };
    final harness = client();
    try {
      await harness.api.get('/shipments');
      fail('The redirect must be reported.');
    } on ApiError catch (error) {
      expect(error.code, 'redirected');
      expect(error.status, 302);
      expect(error.details['location'], endsWith('/api/v1/elsewhere'));
    }
    expect(received, hasLength(1));
    expect(harness.session(), isNotNull);
  });

  test('renews the tokens over the wire and repeats the request', () async {
    respond = (request, body) async {
      if (request.uri.path.endsWith('/auth/refresh')) {
        expect(jsonDecode(utf8.decode(body)), {'refresh_token': 'refresh-token-1-padding-padding'});
        sendJson(request, 200, {'success': true, 'message': '', 'data': authPayload('2'), 'errors': null});
      } else if (request.headers.value('authorization') == 'Bearer access-2') {
        sendJson(request, 200, {'success': true, 'message': 'ok', 'data': {'fine': true}, 'errors': null});
      } else {
        sendJson(request, 401, {
          'success': false,
          'message': 'توکن منقضی شده است.',
          'data': null,
          'errors': {'code': 'token_expired', 'request_id': 'r1'},
        });
      }
    };
    final harness = client();
    final result = await harness.api.get('/dashboard/summary');
    expect(result.json, {'fine': true});
    expect([for (final request in received) Uri.parse(request.path).path], [
      '/api/v1/dashboard/summary',
      '/api/v1/auth/refresh',
      '/api/v1/dashboard/summary',
    ]);
    expect(received[1].headers.containsKey('authorization'), isFalse);
    expect(harness.session()!.accessToken, 'access-2');
    expect(harness.ended, isEmpty);
  });

  test('reports an unreachable server as a network error and keeps the session', () async {
    final harness = client();
    await server.close(force: true);
    try {
      await harness.api.get('/shipments');
      fail('A closed port must not answer.');
    } on ApiError catch (error) {
      expect(error.isNetworkError, isTrue);
      expect(error.status, 0);
      expect(error.message, contains('ارتباط با سرور'));
    }
    expect(harness.session(), isNotNull);
    expect(harness.ended, isEmpty);
  });
}
