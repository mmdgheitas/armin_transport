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
