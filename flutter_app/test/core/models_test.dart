import 'package:armin_transport/core/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

const Json shipmentJson = {
  'id': 's1',
  'tracking_code': 'ARMN-7K2P-9QXD-4M8T',
  'tracking_code_type': 'AUTO',
  'status': 'ACTIVE',
  'description': 'دو پالت لوازم خانگی',
  'company_id': 'c1',
  'company': {
    'id': 'c1',
    'name': 'حمل‌ونقل ',
    'company_code': 'ARMIN',
    'is_active': true,
  },
  'created_by': {'id': 'u1', 'full_name': 'سارا محمدی'},
  'document_count': 3,
  'created_at': '2026-11-10T08:30:00Z',
  'updated_at': '2026-11-10T09:00:00Z',
};

void main() {
  test('reads a session from a login response', () {
    final now = DateTime.utc(2026, 11, 10, 8, 30);
    final session = AuthSession.fromAuthResponse(authPayload(), now)!;
    expect(session.accessToken, 'access-1');
    expect(session.accessExpiresAt, DateTime.utc(2026, 11, 10, 8, 45));
    expect(session.refreshExpiresAt, DateTime.utc(2026, 11, 24, 8, 30));
    expect(session.user.id, 'u1');
    expect(session.user.isAdmin, isFalse);
    expect(session.user.roleLabel, 'کارمند');
    expect(session.user.company!.companyCode, 'ARMIN');
    expect(session.can('shipment:create'), isTrue);
    expect(session.can('user:view'), isFalse);
    expect(session.isGlobal, isFalse);
    expect(session.settings.upload.maxFileSizeBytes, 10485760);
    expect(session.settings.upload.maxFilesPerUpload, 10);
    expect(session.settings.upload.customerVisibleDefault, isTrue);
    expect(session.settings.trackingCode.minLength, 6);
    expect(session.settings.passwordMinLength, 10);
    expect(session.settings.defaultPageSize, 20);

    final admin = AuthSession.fromAuthResponse(adminAuthPayload(), now)!;
    expect(admin.user.isAdmin, isTrue);
    expect(admin.user.roleLabel, 'مدیر مرکزی');
    expect(admin.user.company, isNull);
    expect(admin.isGlobal, isTrue);

    for (final incomplete in [
      null,
      'text',
      <String, dynamic>{},
      {...authPayload(), 'access_token': null},
      {...authPayload(), 'refresh_token': ''},
    ]) {
      expect(AuthSession.fromAuthResponse(incomplete, now), isNull);
    }
  });

  test('falls back to safe defaults when the server leaves settings out', () {
    final session = AuthSession.fromAuthResponse({
      'access_token': 'a',
      'refresh_token': 'r',
      'user': {
        'id': 'u9',
        'username': 'x',
        'full_name': 'ی',
        'role': 'EMPLOYEE',
      },
    }, DateTime.utc(2026))!;
    expect(
      session.accessExpiresAt,
      DateTime.utc(2026).add(const Duration(seconds: 900)),
    );
    expect(session.permissions, isEmpty);
    expect(session.settings.upload.allowedExtensions, isEmpty);
    expect(session.settings.trackingCode.maxLength, 64);
    expect(session.settings.maxPageSize, 100);
    expect(session.user.isActive, isTrue);
  });

  test('keeps a session through storage', () {
    final session = AuthSession.fromAuthResponse(
      adminAuthPayload('7'),
      DateTime.utc(2026, 11, 10, 8, 30),
    )!;
    final restored = AuthSession.fromStorageJson(session.toStorageJson())!;
    expect(restored.accessToken, 'access-7');
    expect(restored.refreshToken, session.refreshToken);
    expect(restored.accessExpiresAt, session.accessExpiresAt);
    expect(restored.refreshExpiresAt, session.refreshExpiresAt);
    expect(restored.user.username, 'admin');
    expect(restored.permissions, session.permissions);
    expect(
      restored.settings.upload.allowedExtensions,
      session.settings.upload.allowedExtensions,
    );
    expect(AuthSession.fromStorageJson(null), isNull);
    expect(
      AuthSession.fromStorageJson(<String, dynamic>{'version': 1}),
      isNull,
    );
  });

  test('applies a fresh profile without touching the tokens', () {
    final session = AuthSession.fromAuthResponse(
      authPayload(),
      DateTime.utc(2026, 11, 10),
    )!;
    final updated = session.withProfile({
      'user': {...employeeUser, 'full_name': 'نام تازه'},
      'permissions': ['shipment:view'],
      'app_settings': {
        ...appSettings,
        'password': {'min_length': 12},
      },
    });
    expect(updated.accessToken, session.accessToken);
    expect(updated.refreshToken, session.refreshToken);
    expect(updated.accessExpiresAt, session.accessExpiresAt);
    expect(updated.user.fullName, 'نام تازه');
    expect(updated.permissions, {'shipment:view'});
    expect(updated.settings.passwordMinLength, 12);

    final unchanged = session.withProfile('garbage');
    expect(unchanged.user.fullName, session.user.fullName);
    expect(unchanged.permissions, session.permissions);
    // The stored form of the updated session carries the new profile.
    expect(
      AuthSession.fromStorageJson(updated.toStorageJson())!.user.fullName,
      'نام تازه',
    );
  });

  test('reads a page of a list', () {
    final page = PageOf<Shipment>.fromJson(
      pageOf([shipmentJson, 'not an object', null], total: 45),
      Shipment.fromJson,
    );
    expect(page.items, hasLength(1));
    expect(page.pagination.page, 1);
    expect(page.pagination.perPage, 20);
    expect(page.pagination.total, 45);
    expect(page.pagination.totalPages, 3);
    expect(page.pagination.hasNext, isTrue);

    final empty = PageOf<Shipment>.fromJson(null, Shipment.fromJson);
    expect(empty.items, isEmpty);
    expect(empty.pagination.total, 0);
    expect(empty.pagination.hasNext, isFalse);
  });

  test('reads a shipment', () {
    final shipment = Shipment.fromJson(shipmentJson);
    expect(shipment.id, 's1');
    expect(shipment.trackingCode, 'ARMN-7K2P-9QXD-4M8T');
    expect(shipment.isArchived, isFalse);
    expect(shipment.hasManualCode, isFalse);
    expect(shipment.statusLabel, 'فعال');
    expect(shipment.codeTypeLabel, 'خودکار');
    expect(shipment.description, 'دو پالت لوازم خانگی');
    expect(shipment.company!.name, 'حمل‌ونقل ');
    expect(shipment.createdBy!.fullName, 'سارا محمدی');
    expect(shipment.createdBy!.username, isNull);
    expect(shipment.documentCount, 3);
    expect(shipment.createdAt, DateTime.utc(2026, 11, 10, 8, 30));

    final archived = Shipment.fromJson({
      ...shipmentJson,
      'status': 'ARCHIVED',
      'tracking_code_type': 'MANUAL',
    });
    expect(archived.isArchived, isTrue);
    expect(archived.statusLabel, 'بایگانی‌شده');
    expect(archived.codeTypeLabel, 'دستی');
  });

  test('survives members that are missing or of the wrong type', () {
    final shipment = Shipment.fromJson({
      'id': 12,
      'tracking_code': null,
      'description': '',
      'company': 'ARMIN',
      'created_by': [],
      'document_count': '3',
      'created_at': 'yesterday',
    });
    expect(shipment.id, '');
    expect(shipment.trackingCode, '');
    expect(shipment.description, isNull);
    expect(shipment.company, isNull);
    expect(shipment.createdBy, isNull);
    expect(shipment.documentCount, 0);
    expect(shipment.createdAt, isNull);
    expect(shipment.status, 'ACTIVE');

    expect(asJson('text'), isEmpty);
    expect(asJson({1: 'a'}), {'1': 'a'});
    expect(asJsonList('text'), isEmpty);
    expect(
      asJsonList([
        1,
        <String, dynamic>{'a': 1},
        null,
      ]),
      [
        {'a': 1},
      ],
    );
    expect(Company.fromJson(const {}).name, '');
    expect(UserAccount.fromJson(const {}).role, 'EMPLOYEE');
    expect(ProductField.fromJson(const {}).dataType, 'TEXT');
    expect(AuditLogEntry.fromJson(const {}).action, '');
    expect(DashboardSummary.fromJson(const {}).recentShipments, isEmpty);
    expect(CustomerShipment.fromJson(const {}).productDetails, isEmpty);
    expect(CustomerGrant.fromJson(const {}), isNull);
  });

  test('reads documents, history and audit entries', () {
    final document = ShipmentDocument.fromJson({
      'id': 'd1',
      'shipment_id': 's1',
      'original_name': 'بارنامه.pdf',
      'mime_type': 'application/pdf',
      'extension': 'pdf',
      'file_size': 204800,
      'is_customer_visible': true,
      'uploaded_by': {'id': 'u1', 'full_name': 'سارا محمدی'},
      'created_at': '2026-11-10T08:31:00Z',
    });
    expect(document.originalName, 'بارنامه.pdf');
    expect(document.fileSize, 204800);
    expect(document.isCustomerVisible, isTrue);
    expect(document.uploadedBy!.fullName, 'سارا محمدی');

    final history = TrackingHistoryEntry.fromJson({
      'id': 'h1',
      'old_code': null,
      'new_code': 'ARMN-7K2P-9QXD-4M8T',
      'changed_by': {'id': 'u1', 'full_name': 'سارا محمدی'},
      'changed_at': '2026-11-10T08:30:00Z',
    });
    expect(history.oldCode, isNull);
    expect(history.newCode, 'ARMN-7K2P-9QXD-4M8T');
    expect(history.changedAt, DateTime.utc(2026, 11, 10, 8, 30));

    final entry = AuditLogEntry.fromJson({
      'id': 'a1',
      'action': 'shipment.created',
      'entity_type': 'shipment',
      'entity_id': 's1',
      'metadata': {'tracking_code': 'ARMN-7K2P-9QXD-4M8T'},
      'ip_address': '192.0.2.7',
      'request_id': 'req-1',
      'user': {
        'id': 'u1',
        'username': 'armin.operator',
        'full_name': 'سارا محمدی',
      },
      'created_at': '2026-11-10T08:30:00Z',
    });
    expect(entry.action, 'shipment.created');
    expect(entry.user!.username, 'armin.operator');
    expect(entry.metadata, {'tracking_code': 'ARMN-7K2P-9QXD-4M8T'});
    expect(
      AuditLogEntry.fromJson({
        'id': 'a2',
        'action': 'auth.login_failed',
        'user': null,
      }).user,
      isNull,
    );
  });

  test('reads goods fields and their values', () {
    final item = ProductValueItem.fromJson({
      'field': {
        'id': 'f1',
        'field_key': 'packaging',
        'label': 'نوع بسته‌بندی',
        'data_type': 'SELECT',
        'is_required': true,
        'is_active': true,
        'is_customer_visible': true,
        'display_order': 30,
        'validation_rules': null,
        'options': [
          {'value': 'pallet', 'label': 'پالت'},
          {'value': 'box', 'label': 'کارتن'},
        ],
        'version': 2,
      },
      'value': 'pallet',
      'display_value': 'پالت',
      'field_version': 1,
      'is_outdated': true,
    });
    expect(item.field.fieldKey, 'packaging');
    expect(item.field.hasOptions, isTrue);
    expect(item.field.isRequired, isTrue);
    expect(item.field.validationRules, isEmpty);
    expect(item.field.options.map((option) => option.label), ['پالت', 'کارتن']);
    expect(item.field.version, 2);
    expect(item.value, 'pallet');
    expect(item.displayValue, 'پالت');
    expect(item.isOutdated, isTrue);
    expect(
      ProductField.fromJson({
        'data_type': 'NUMBER',
        'validation_rules': {'min': 0},
      }).validationRules,
      {'min': 0},
    );
    expect(ProductField.fromJson({'data_type': 'NUMBER'}).hasOptions, isFalse);
  });

  test('reads the dashboard of an administrator and of an employee', () {
    final global = DashboardSummary.fromJson({
      'scope': 'GLOBAL',
      'company': null,
      'companies': {'total': 3, 'active': 2},
      'employees': {'total': 9, 'active': 8},
      'shipments': {'total': 120, 'active': 100, 'archived': 20},
      'documents': 340,
      'recent_shipments': [shipmentJson],
    });
    expect(global.isGlobal, isTrue);
    expect(global.companies!.total, 3);
    expect(global.employees!.active, 8);
    expect(
      (global.shipmentsTotal, global.shipmentsActive, global.shipmentsArchived),
      (120, 100, 20),
    );
    expect(global.documents, 340);
    expect(global.recentShipments.single.id, 's1');

    final own = DashboardSummary.fromJson({
      'scope': 'COMPANY',
      'company': {
        'id': 'c1',
        'name': 'حمل‌ونقل ',
        'company_code': 'ARMIN',
        'is_active': true,
      },
      'companies': null,
      'employees': null,
      'shipments': {'total': 5, 'active': 4, 'archived': 1},
      'documents': 7,
      'recent_shipments': <Object>[],
    });
    expect(own.isGlobal, isFalse);
    expect(own.company!.name, 'حمل‌ونقل ');
    expect(own.companies, isNull);
    expect(own.employees, isNull);
  });

  test('reads what a customer may see', () {
    final grant = CustomerGrant.fromJson({
      'access_token': 'tok',
      'expires_at': '2026-11-10T09:00:00Z',
      'expires_in': 1800,
    })!;
    expect(grant.accessToken, 'tok');
    expect(grant.expiresAt, DateTime.utc(2026, 11, 10, 9));

    final shipment = CustomerShipment.fromJson({
      'tracking_code': 'ARMN-7K2P-9QXD-4M8T',
      'status': 'ACTIVE',
      'company_name': 'حمل‌ونقل ',
      'description': null,
      'registered_at': '2026-11-10T08:30:00Z',
      'document_count': 2,
      'product_details': [
        {'label': 'وزن', 'data_type': 'DECIMAL', 'value': '1250.5'},
        {'label': 'شکستنی', 'data_type': 'BOOLEAN', 'value': false},
      ],
      'session_expires_at': '2026-11-10T09:00:00Z',
    });
    expect(shipment.companyName, 'حمل‌ونقل ');
    expect(shipment.description, isNull);
    expect(shipment.documentCount, 2);
    expect(shipment.productDetails.map((detail) => detail.label), [
      'وزن',
      'شکستنی',
    ]);
    expect(shipment.productDetails.last.value, isFalse);
    expect(shipment.sessionExpiresAt, DateTime.utc(2026, 11, 10, 9));

    final document = CustomerDocument.fromJson({
      'id': 'd1',
      'name': 'بارنامه.pdf',
      'mime_type': 'application/pdf',
      'extension': 'pdf',
      'file_size': 1024,
      'uploaded_at': '2026-11-10T08:31:00Z',
    });
    expect(document.name, 'بارنامه.pdf');
    expect(document.fileSize, 1024);
  });

  test('reads companies and users', () {
    final company = Company.fromJson({
      'id': 'c1',
      'name': 'حمل‌ونقل ',
      'company_code': 'ARMIN',
      'phone': '02112345678',
      'address': null,
      'is_active': false,
      'created_at': '2026-01-01T00:00:00Z',
      'employee_count': 4,
      'shipment_count': 12,
    });
    expect(company.isActive, isFalse);
    expect(company.phone, '02112345678');
    expect(company.address, isNull);
    expect((company.employeeCount, company.shipmentCount), (4, 12));
    expect(
      Company.fromJson({'id': 'c2', 'name': 'پارس', 'company_code': 'PARS'})
          .employeeCount,
      isNull,
    );

    final user = UserAccount.fromJson({
      ...employeeUser,
      'last_login_at': '2026-11-09T07:00:00Z',
      'is_active': false,
    });
    expect(user.isActive, isFalse);
    expect(user.companyId, 'c1');
    expect(user.lastLoginAt, DateTime.utc(2026, 11, 9, 7));
  });
}
