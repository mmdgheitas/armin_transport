import 'dart:convert';

import 'package:armin_transport/core/api/api_client.dart';
import 'package:armin_transport/core/api/api_error.dart';
import 'package:armin_transport/core/api/armin_api.dart';
import 'package:armin_transport/core/api/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

const Json shipment = {
  'id': 's1',
  'tracking_code': 'ARMN-7K2P-9QXD-4M8T',
  'tracking_code_type': 'AUTO',
  'status': 'ACTIVE',
  'company_id': 'c1',
  'document_count': 0,
};

const Json field = {
  'id': 'f1',
  'field_key': 'weight',
  'label': 'وزن',
  'data_type': 'DECIMAL',
  'version': 1,
};

/// An [ArminApi] whose every request is answered with [data].
(ArminApi, ClientHarness) apiAnswering(
  Object? data, {
  String message = 'انجام شد.',
  int status = 200,
  bool signedIn = true,
}) {
  final harness = ClientHarness(
    (request) => ok(data, message: message, status: status),
    signedIn: signedIn,
  );
  return (ArminApi(harness.api), harness);
}

void main() {
  test('asks the server for its version without a token', () async {
    final (api, harness) = apiAnswering({
      'status': 'ok',
      'version': '1.0.0',
      'time': '2026-11-10T08:30:00Z',
    }, signedIn: false);
    expect(await api.serverVersion(), '1.0.0');
    final call = harness.calls.single;
    expect((call.method, call.path), ('GET', '/api/v1/health'));
    expect(call.authorization, isNull);

    // Something that answers JSON but is not this API is not accepted as a server.
    final other = ClientHarness(
      (request) => jsonResponse(200, {'hello': 'world'}),
      signedIn: false,
    );
    await expectLater(
      ArminApi(other.api).serverVersion(),
      throwsA(isA<ApiError>()),
    );
  });

  test('lists shipments with the filters that are set', () async {
    final (api, harness) = apiAnswering(
      pageOf([shipment], total: 41, perPage: 20),
    );
    final page = await api.shipments(
      page: 2,
      perPage: 20,
      search: 'یخچال',
      status: 'ARCHIVED',
      codeType: 'MANUAL',
      companyId: 'c1',
      createdFrom: '2026-03-21',
      createdTo: '2026-11-10',
      sort: '-created_at',
    );
    expect(page.items.single.trackingCode, 'ARMN-7K2P-9QXD-4M8T');
    expect(page.pagination.total, 41);
    final call = harness.calls.single;
    expect((call.method, call.path), ('GET', '/api/v1/shipments'));
    expect(call.query, {
      'page': '2',
      'per_page': '20',
      'q': 'یخچال',
      'status': 'ARCHIVED',
      'tracking_code_type': 'MANUAL',
      'company_id': 'c1',
      'created_from': '2026-03-21',
      'created_to': '2026-11-10',
      'sort': '-created_at',
    });

    await api.shipments(search: '');
    expect(harness.calls.last.query, {
      'page': '1',
    }); // filters that are not set are left out
  });

  test('creates a shipment with only the members that are given', () async {
    final (api, harness) = apiAnswering(
      shipment,
      message: 'محموله ثبت شد.',
      status: 201,
    );
    final created = await api.createShipment();
    expect(created.value.id, 's1');
    expect(created.message, 'محموله ثبت شد.');
    expect(
      (harness.calls.last.method, harness.calls.last.path),
      ('POST', '/api/v1/shipments'),
    );
    expect(harness.calls.last.json, <String, dynamic>{});

    await api.createShipment(
      companyId: 'c1',
      trackingCode: 'MANUAL-0001',
      description: 'بار شکستنی',
      productValues: {'weight': '12.5', 'fragile': true, 'note': null},
    );
    expect(harness.calls.last.json, {
      'company_id': 'c1',
      'tracking_code': 'MANUAL-0001',
      'description': 'بار شکستنی',
      'product_values': {'weight': '12.5', 'fragile': true, 'note': null},
    });
  });

  test('reads and changes one shipment', () async {
    final (api, harness) = apiAnswering(shipment, message: 'ذخیره شد.');
    (String, String) last() =>
        (harness.calls.last.method, harness.calls.last.path);

    expect((await api.shipment('s1')).id, 's1');
    expect(last(), ('GET', '/api/v1/shipments/s1'));

    expect(
      (await api.updateDescription('s1', 'توضیح تازه')).message,
      'ذخیره شد.',
    );
    expect(last(), ('PATCH', '/api/v1/shipments/s1'));
    expect(harness.calls.last.json, {'description': 'توضیح تازه'});
    await api.updateDescription('s1', null);
    expect(harness.calls.last.json, {
      'description': null,
    }); // null removes the description

    await api.archiveShipment('s1');
    expect(last(), ('POST', '/api/v1/shipments/s1/archive'));
    expect(harness.calls.last.bodyBytes, isEmpty);
    await api.unarchiveShipment('s1');
    expect(last(), ('POST', '/api/v1/shipments/s1/unarchive'));

    await api.changeTrackingCode('s1');
    expect(last(), ('POST', '/api/v1/shipments/s1/tracking-code'));
    expect(harness.calls.last.json, {'generate': true});
    await api.changeTrackingCode('s1', manualCode: 'MANUAL-0002');
    expect(harness.calls.last.json, {'tracking_code': 'MANUAL-0002'});

    // An identifier is always sent as one path segment.
    await api.shipment('a/b?c');
    expect(
      harness.calls.last.uri.toString(),
      'https://armin.test/api/v1/shipments/a%2Fb%3Fc',
    );
  });

  test('reads the history of codes and ends customer sessions', () async {
    final history = apiAnswering(
      pageOf([
        {
          'id': 'h1',
          'old_code': null,
          'new_code': 'ARMN-7K2P-9QXD-4M8T',
          'changed_at': '2026-11-10T08:30:00Z',
        },
      ]),
    );
    final page = await history.$1.trackingHistory('s1', page: 3, perPage: 10);
    expect(page.items.single.newCode, 'ARMN-7K2P-9QXD-4M8T');
    expect(
      history.$2.calls.single.path,
      '/api/v1/shipments/s1/tracking-history',
    );
    expect(history.$2.calls.single.query, {'page': '3', 'per_page': '10'});

    final revoke = apiAnswering({
      'revoked': 2,
    }, message: 'دسترسی مشتریان لغو شد.');
    final done = await revoke.$1.revokeCustomerSessions('s1');
    expect((done.value, done.message), (2, 'دسترسی مشتریان لغو شد.'));
    expect(
      (revoke.$2.calls.single.method, revoke.$2.calls.single.path),
      ('POST', '/api/v1/shipments/s1/customer-sessions/revoke'),
    );
  });

  test('reads and saves the goods of a shipment', () async {
    final (api, harness) = apiAnswering({
      'items': [
        {
          'field': field,
          'value': '12.5',
          'display_value': '12.5',
          'is_outdated': false,
        },
      ],
    }, message: 'مشخصات کالا ذخیره شد.');
    final values = await api.productValues('s1');
    expect(values.single.field.fieldKey, 'weight');
    expect(
      (harness.calls.last.method, harness.calls.last.path),
      ('GET', '/api/v1/shipments/s1/product-values'),
    );

    final saved = await api.saveProductValues('s1', {
      'weight': '13',
      'note': null,
    });
    expect(saved.value.single.value, '12.5');
    expect(saved.message, 'مشخصات کالا ذخیره شد.');
    expect(
      (harness.calls.last.method, harness.calls.last.path),
      ('PUT', '/api/v1/shipments/s1/product-values'),
    );
    expect(harness.calls.last.json, {
      'values': {'weight': '13', 'note': null},
    });
  });

  test('manages the definitions of goods fields', () async {
    final (api, harness) = apiAnswering(pageOf([field]));
    await api.productFields(
      page: 2,
      perPage: 50,
      search: 'وزن',
      includeInactive: true,
    );
    expect(harness.calls.last.path, '/api/v1/product-fields');
    expect(harness.calls.last.query, {
      'page': '2',
      'per_page': '50',
      'q': 'وزن',
      'include_inactive': 'true',
    });
    await api.productFields();
    expect(harness.calls.last.query, {'page': '1'});

    final single = apiAnswering(field, message: 'فیلد ذخیره شد.', status: 201);
    final created = await single.$1.createProductField({
      'field_key': 'weight',
      'label': 'وزن',
      'data_type': 'DECIMAL',
    });
    expect(created.value.fieldKey, 'weight');
    expect(
      (single.$2.calls.last.method, single.$2.calls.last.path),
      ('POST', '/api/v1/product-fields'),
    );
    expect(single.$2.calls.last.json, {
      'field_key': 'weight',
      'label': 'وزن',
      'data_type': 'DECIMAL',
    });
    await single.$1.updateProductField('f1', {'is_active': false});
    expect(
      (single.$2.calls.last.method, single.$2.calls.last.path),
      ('PATCH', '/api/v1/product-fields/f1'),
    );
    expect(single.$2.calls.last.json, {'is_active': false});
  });

  test('collects every page of the active goods fields', () async {
    Json fieldNumber(int number) => {
      ...field,
      'id': 'f$number',
      'field_key': 'field_$number',
    };
    final harness = ClientHarness((request) {
      final page = int.parse(request.query['page']!);
      final perPage = int.parse(request.query['per_page']!);
      final all = [
        for (var number = 1; number <= 5; number += 1) fieldNumber(number),
      ];
      final items = all.skip((page - 1) * perPage).take(perPage).toList();
      return ok(pageOf(items, page: page, perPage: perPage, total: all.length));
    });
    final fields = await ArminApi(harness.api).activeProductFields(pageSize: 2);
    expect(
      [for (final item in fields) item.fieldKey],
      ['field_1', 'field_2', 'field_3', 'field_4', 'field_5'],
    );
    expect(
      [for (final call in harness.calls) call.query['page']],
      ['1', '2', '3'],
    );
    expect(
      harness.calls.every(
        (call) => !call.query.containsKey('include_inactive'),
      ),
      isTrue,
    );
  });

  test('works with the documents of a shipment', () async {
    const document = {
      'id': 'd1',
      'original_name': 'بارنامه.pdf',
      'file_size': 10,
      'is_customer_visible': true,
    };
    final list = apiAnswering(pageOf([document]));
    final page = await list.$1.documents('s1', page: 2, perPage: 20);
    expect(page.items.single.originalName, 'بارنامه.pdf');
    expect(list.$2.calls.single.path, '/api/v1/shipments/s1/documents');
    expect(list.$2.calls.single.query, {'page': '2', 'per_page': '20'});

    final upload = apiAnswering(
      [document],
      message: 'بارگذاری شد.',
      status: 201,
    );
    final uploaded = await upload.$1.uploadDocuments(
      's1',
      files: [
        UploadPart(filename: 'بارنامه.pdf', bytes: utf8.encode('%PDF-1.7')),
      ],
      customerVisible: false,
    );
    expect(uploaded.value.single.id, 'd1');
    expect(uploaded.message, 'بارگذاری شد.');
    final sent = upload.$2.calls.single;
    expect(
      (sent.method, sent.path),
      ('POST', '/api/v1/shipments/s1/documents'),
    );
    final body = utf8.decode(sent.bodyBytes, allowMalformed: true);
    expect(body, contains('name="customer_visible"\r\n\r\nfalse\r\n'));
    expect(body, contains('name="files"; filename="بارنامه.pdf"'));

    final single = apiAnswering(document, message: 'ذخیره شد.');
    final changed = await single.$1.setDocumentVisibility(
      'd1',
      customerVisible: false,
    );
    expect(changed.value.id, 'd1');
    expect(
      (single.$2.calls.last.method, single.$2.calls.last.path),
      ('PATCH', '/api/v1/documents/d1'),
    );
    expect(single.$2.calls.last.json, {'is_customer_visible': false});

    final removed = apiAnswering(null, message: 'سند حذف شد.');
    expect(await removed.$1.deleteDocument('d1'), 'سند حذف شد.');
    expect(
      (removed.$2.calls.single.method, removed.$2.calls.single.path),
      ('DELETE', '/api/v1/documents/d1'),
    );

    final download = ClientHarness(
      (request) => ResponseBody.fromBytes(
        utf8.encode('%PDF-1.7'),
        200,
        headers: {
          'content-type': ['application/pdf'],
          'content-disposition': ['attachment; filename="a.pdf"'],
        },
      ),
    );
    final file = await ArminApi(download.api).downloadDocument('d1');
    expect(file.filename, 'a.pdf');
    expect(download.calls.single.path, '/api/v1/documents/d1/download');
  });

  test('manages companies', () async {
    const company = {
      'id': 'c1',
      'name': 'حمل‌ونقل ',
      'company_code': 'ARMIN',
      'employee_count': 4,
    };
    final list = apiAnswering(pageOf([company]));
    await list.$1.companies(page: 2, perPage: 100, search: '', isActive: true);
    expect(list.$2.calls.single.path, '/api/v1/companies');
    expect(list.$2.calls.single.query, {
      'page': '2',
      'per_page': '100',
      'q': '',
      'is_active': 'true',
    });
    await list.$1.companies(isActive: false);
    expect(list.$2.calls.last.query, {'page': '1', 'is_active': 'false'});

    final (api, harness) = apiAnswering(company, message: 'شرکت ذخیره شد.');
    expect((await api.company('c1')).employeeCount, 4);
    expect(
      (harness.calls.last.method, harness.calls.last.path),
      ('GET', '/api/v1/companies/c1'),
    );
    await api.createCompany({'name': 'پارس', 'company_code': 'PARS'});
    expect(
      (harness.calls.last.method, harness.calls.last.path),
      ('POST', '/api/v1/companies'),
    );
    expect(harness.calls.last.json, {'name': 'پارس', 'company_code': 'PARS'});
    final updated = await api.updateCompany('c1', {'is_active': false});
    expect(updated.message, 'شرکت ذخیره شد.');
    expect(
      (harness.calls.last.method, harness.calls.last.path),
      ('PATCH', '/api/v1/companies/c1'),
    );
  });

  test('manages users', () async {
    final list = apiAnswering(pageOf([employeeUser]));
    final page = await list.$1.users(
      page: 1,
      perPage: 20,
      search: 'سارا',
      companyId: 'c1',
      role: 'EMPLOYEE',
      isActive: true,
    );
    expect(page.items.single.username, 'armin.operator');
    expect(list.$2.calls.single.path, '/api/v1/users');
    expect(list.$2.calls.single.query, {
      'page': '1',
      'per_page': '20',
      'q': 'سارا',
      'company_id': 'c1',
      'role': 'EMPLOYEE',
      'is_active': 'true',
    });

    final (api, harness) = apiAnswering(
      employeeUser,
      message: 'کاربر ذخیره شد.',
    );
    await api.createUser({
      'username': 'new.user',
      'full_name': 'کاربر تازه',
      'password': 'Passw0rd-1234',
      'company_id': 'c1',
    });
    expect(
      (harness.calls.last.method, harness.calls.last.path),
      ('POST', '/api/v1/users'),
    );
    await api.updateUser('u1', {'is_active': false});
    expect(
      (harness.calls.last.method, harness.calls.last.path),
      ('PATCH', '/api/v1/users/u1'),
    );
    expect(await api.resetPassword('u1', 'N3w-Passw0rd!'), 'کاربر ذخیره شد.');
    expect(
      (harness.calls.last.method, harness.calls.last.path),
      ('POST', '/api/v1/users/u1/reset-password'),
    );
    expect(harness.calls.last.json, {'new_password': 'N3w-Passw0rd!'});
  });

  test('reads the dashboard and the audit log', () async {
    final dashboard = apiAnswering({
      'scope': 'COMPANY',
      'shipments': {'total': 5, 'active': 4, 'archived': 1},
      'documents': 7,
      'recent_shipments': [shipment],
    });
    final summary = await dashboard.$1.dashboard();
    expect(summary.shipmentsTotal, 5);
    expect(dashboard.$2.calls.single.path, '/api/v1/dashboard/summary');

    final log = apiAnswering(
      pageOf([
        {
          'id': 'a1',
          'action': 'shipment.created',
          'entity_type': 'shipment',
          'created_at': '2026-11-10T08:30:00Z',
        },
      ]),
    );
    final page = await log.$1.auditLogs(
      page: 4,
      perPage: 50,
      action: 'shipment.created',
      entityType: 'shipment',
      userId: 'u1',
      createdFrom: '2026-11-01',
      createdTo: '2026-11-10',
    );
    expect(page.items.single.action, 'shipment.created');
    expect(log.$2.calls.single.path, '/api/v1/audit-logs');
    expect(log.$2.calls.single.query, {
      'page': '4',
      'per_page': '50',
      'action': 'shipment.created',
      'entity_type': 'shipment',
      'user_id': 'u1',
      'created_from': '2026-11-01',
      'created_to': '2026-11-10',
    });
  });

  test('serves a customer without any staff session', () async {
    const grant = CustomerGrant(accessToken: 'tok/with+odd=chars');
    const prefix = '/api/v1/customer/access/tok%2Fwith%2Bodd%3Dchars';

    final lookup = apiAnswering({
      'access_token': 'tok',
      'expires_at': '2026-11-10T09:00:00Z',
      'expires_in': 1800,
    }, signedIn: false);
    expect(
      (await lookup.$1.customerLookup('ARMN-7K2P-9QXD-4M8T')).accessToken,
      'tok',
    );
    expect(
      (lookup.$2.calls.single.method, lookup.$2.calls.single.path),
      ('POST', '/api/v1/customer/lookup'),
    );
    expect(lookup.$2.calls.single.json, {
      'tracking_code': 'ARMN-7K2P-9QXD-4M8T',
    });
    expect(lookup.$2.calls.single.authorization, isNull);

    final nothing = apiAnswering({'unexpected': true}, signedIn: false);
    await expectLater(
      nothing.$1.customerLookup('ARMN-7K2P-9QXD-4M8T'),
      throwsA(isA<ApiError>()),
    );

    final view = apiAnswering({
      'tracking_code': 'ARMN-7K2P-9QXD-4M8T',
      'document_count': 1,
    }, signedIn: false);
    expect((await view.$1.customerShipment(grant)).documentCount, 1);
    expect(view.$2.calls.single.uri.path, '$prefix/shipment');
    expect(view.$2.calls.single.authorization, isNull);

    final documents = apiAnswering(
      pageOf([
        {'id': 'd1', 'name': 'بارنامه.pdf', 'file_size': 10},
      ]),
      signedIn: false,
    );
    expect(
      (await documents.$1.customerDocuments(
        grant,
        page: 2,
        perPage: 20,
      )).items.single.name,
      'بارنامه.pdf',
    );
    expect(documents.$2.calls.single.uri.path, '$prefix/documents');
    expect(documents.$2.calls.single.query, {'page': '2', 'per_page': '20'});

    final download = ClientHarness(
      (request) => ResponseBody.fromBytes(
        [1, 2, 3],
        200,
        headers: {
          'content-type': ['image/png'],
        },
      ),
      signedIn: false,
    );
    final file = await ArminApi(download.api)
        .downloadCustomerDocument(grant, 'd1');
    expect(file.bytes, [1, 2, 3]);
    expect(file.filename, 'download');
    expect(download.calls.single.uri.path, '$prefix/documents/d1/download');
    expect(download.calls.single.authorization, isNull);

    final end = apiAnswering(null, signedIn: false);
    await end.$1.endCustomerAccess(grant);
    expect(
      (end.$2.calls.single.method, end.$2.calls.single.uri.path),
      ('POST', '$prefix/revoke'),
    );

    // Ending the access is best effort: a failure is not reported.
    final failing = ClientHarness(
      (request) => errorResponse(404, 'access_not_found'),
      signedIn: false,
    );
    await ArminApi(failing.api).endCustomerAccess(grant);
    expect(failing.ended, isEmpty);
  });
}
