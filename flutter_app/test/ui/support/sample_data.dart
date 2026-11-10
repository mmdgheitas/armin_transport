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
  'company': {'id': 'c1', 'name': 'حمل‌ونقل آرمین', 'company_code': 'ARMIN', 'is_active': true},
  'created_by': {'id': 'u1', 'full_name': 'سارا محمدی', 'username': 'armin.operator'},
  'document_count': documents,
  'created_at': '2026-11-09T07:15:00Z',
  'updated_at': '2026-11-09T07:15:00Z',
};

Json dashboardJson({bool global = false, List<Json>? recent}) => {
  'scope': global ? 'GLOBAL' : 'COMPANY',
  'company': global ? null : {'id': 'c1', 'name': 'حمل‌ونقل آرمین', 'company_code': 'ARMIN', 'is_active': true},
  'shipments': {'total': 1284, 'active': 1200, 'archived': 84},
  'documents': 3120,
  if (global) 'companies': {'total': 7, 'active': 6},
  if (global) 'employees': {'total': 31, 'active': 28},
  'recent_shipments': recent ?? [shipmentJson(), shipmentJson(id: 's2', code: 'ARMN-22AA-33BB-44CC', status: 'ARCHIVED')],
};

Json companyJson({String id = 'c1', String name = 'ترابر شرق', String code = 'SHARGH', bool active = true}) => {
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
  Json rules = const <String, dynamic>{},
  List<Json> options = const <Json>[],
}) => {
  'id': id,
  'field_key': key,
  'label': label,
  'data_type': type,
  'is_required': required,
  'is_active': active,
  'is_customer_visible': true,
  'display_order': 1,
  'validation_rules': rules,
  'options': options,
  'version': 1,
};

/// The value a shipment holds for a goods field.
Json valueJson(Json field, Object? value, {Object? display, bool outdated = false}) => {
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
  'uploaded_by': {'id': 'u1', 'full_name': 'سارا محمدی', 'username': 'armin.operator'},
  'created_at': '2026-11-09T09:30:00Z',
};

Json historyJson({String id = 'h1', String? oldCode, required String newCode}) => {
  'id': id,
  'old_code': oldCode,
  'new_code': newCode,
  'changed_by': {'id': 'u1', 'full_name': 'سارا محمدی', 'username': 'armin.operator'},
  'changed_at': '2026-11-09T07:15:00Z',
};
