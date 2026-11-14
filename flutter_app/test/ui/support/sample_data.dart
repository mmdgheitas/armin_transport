/// Canned API objects for the screen tests.
library;

import 'package:armin_transport/core/api/models.dart';

Json shipmentJson({
  String id = 's1',
  String code = 'ARMN-7K2M-9QXD-4T8B',
  String status = 'ACTIVE',
  String codeType = 'AUTO',
  String? description = 'دو پالت قطعات یدکی',
  int documents = 2,
}) => {
  'id': id,
  'tracking_code': code,
  'tracking_code_type': codeType,
  'status': status,
  'description': description,
  'company_id': 'c1',
  'company': {
    'id': 'c1',
    'name': 'حمل‌ونقل',
    'company_code': 'ARMIN',
    'is_active': true,
  },
  'created_by': {
    'id': 'u1',
    'full_name': 'سارا محمدی',
    'username': 'armin.operator',
  },
  'document_count': documents,
  'created_at': '2026-11-09T07:15:00Z',
  'updated_at': '2026-11-09T07:15:00Z',
};

Json dashboardJson({bool global = false, List<Json>? recent}) => {
  'scope': global ? 'GLOBAL' : 'COMPANY',
  'company': global
      ? null
      : {
          'id': 'c1',
          'name': 'حمل‌ونقل',
          'company_code': 'ARMIN',
          'is_active': true,
        },
  'shipments': {'total': 1284, 'active': 1200, 'archived': 84},
  'documents': 3120,
  if (global) 'companies': {'total': 7, 'active': 6},
  if (global) 'employees': {'total': 31, 'active': 28},
  'recent_shipments':
      recent ??
      [
        shipmentJson(),
        shipmentJson(id: 's2', code: 'ARMN-22AA-33BB-44CC', status: 'ARCHIVED'),
      ],
};

Json companyJson({
  String id = 'c1',
  String name = 'ترابر شرق',
  String code = 'SHARGH',
  bool active = true,
}) => {
  'id': id,
  'name': name,
  'company_code': code,
  'phone': '021-5550100',
  'address': 'تهران، خیابان آزادی',
  'is_active': active,
  'created_at': '2026-01-05T08:00:00Z',
};

/// The definition of a goods field.
Json fieldJson({
  String id = 'f1',
  String key = 'weight',
  String label = 'وزن (کیلوگرم)',
  String type = 'NUMBER',
  bool required = false,
  bool active = true,
  bool customerVisible = true,
  int order = 1,
  Json rules = const <String, dynamic>{},
  List<Json> options = const <Json>[],
}) => {
  'id': id,
  'field_key': key,
  'label': label,
  'data_type': type,
  'is_required': required,
  'is_active': active,
  'is_customer_visible': customerVisible,
  'display_order': order,
  'validation_rules': rules,
  'options': options,
  'version': 1,
};

/// The value a shipment holds for a goods field.
Json valueJson(
  Json field,
  Object? value, {
  Object? display,
  bool outdated = false,
}) => {
  'field': field,
  'value': value,
  'display_value': display ?? value,
  'is_outdated': outdated,
};

Json documentJson({
  String id = 'd1',
  String name = 'waybill.pdf',
  int size = 204800,
  bool visible = true,
}) => {
  'id': id,
  'original_name': name,
  'mime_type': 'application/pdf',
  'extension': 'pdf',
  'file_size': size,
  'is_customer_visible': visible,
  'uploaded_by': {
    'id': 'u1',
    'full_name': 'سارا محمدی',
    'username': 'armin.operator',
  },
  'created_at': '2026-11-09T09:30:00Z',
};

Json historyJson({
  String id = 'h1',
  String? oldCode,
  required String newCode,
}) => {
  'id': id,
  'old_code': oldCode,
  'new_code': newCode,
  'changed_by': {
    'id': 'u1',
    'full_name': 'سارا محمدی',
    'username': 'armin.operator',
  },
  'changed_at': '2026-11-09T07:15:00Z',
};

/// An account as the list of users shows it.
Json userJson({
  String id = 'u1',
  String username = 'armin.operator',
  String fullName = 'سارا محمدی',
  String role = 'EMPLOYEE',
  bool active = true,
  String? companyId = 'c1',
  String companyName = 'ترابر شرق',
  String? lastLogin = '2026-11-08T10:00:00Z',
}) => {
  'id': id,
  'username': username,
  'full_name': fullName,
  'role': role,
  'is_active': active,
  'company_id': companyId,
  'company': companyId == null
      ? null
      : {
          'id': companyId,
          'name': companyName,
          'company_code': 'SHARGH',
          'is_active': true,
        },
  'last_login_at': lastLogin,
  'created_at': '2026-01-05T08:00:00Z',
};

/// An entry of the audit log.
Json auditJson({
  String id = 'a1',
  String action = 'SHIPMENT_CREATED',
  String entityType = 'shipment',
  String? entityId = 's1',
  Json? metadata,
  bool byUser = true,
  String? ip = '203.0.113.7',
}) => {
  'id': id,
  'action': action,
  'entity_type': entityType,
  'entity_id': entityId,
  'metadata': metadata,
  'ip_address': ip,
  'request_id': 'req-$id',
  'user': byUser
      ? {'id': 'u1', 'full_name': 'سارا محمدی', 'username': 'armin.operator'}
      : null,
  'created_at': '2026-11-09T07:15:00Z',
};

/// What the customer portal tells about a shipment.
Json customerShipmentJson({
  String code = 'ARMN-7K2M-9QXD-4T8B',
  String status = 'ACTIVE',
  String? description = 'دو پالت قطعات یدکی',
  int documents = 2,
  List<Json>? details,
}) => {
  'tracking_code': code,
  'status': status,
  'company_name': 'ترابر شرق',
  'description': description,
  'registered_at': '2026-11-09T07:15:00Z',
  'document_count': documents,
  'product_details':
      details ??
      [
        {'label': 'وزن (کیلوگرم)', 'data_type': 'NUMBER', 'value': 1250},
        {'label': 'نوع بسته‌بندی', 'data_type': 'SELECT', 'value': 'پالت'},
        {'label': 'شکستنی', 'data_type': 'BOOLEAN', 'value': true},
      ],
  'session_expires_at': '2026-11-10T09:00:00Z',
};

/// A document as the customer portal lists it.
Json customerDocumentJson({
  String id = 'd1',
  String name = 'waybill.pdf',
  int size = 204800,
}) => {
  'id': id,
  'name': name,
  'mime_type': 'application/pdf',
  'extension': 'pdf',
  'file_size': size,
  'uploaded_at': '2026-11-09T09:30:00Z',
};
