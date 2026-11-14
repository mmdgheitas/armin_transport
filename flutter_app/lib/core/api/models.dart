/// Data classes for the JSON documents of the Armin Transport API.
///
/// Parsing is forgiving: a missing or mistyped member becomes an empty value, so that one
/// unexpected field in a response does not take a whole screen down.
library;

import '../tracking.dart';

typedef Json = Map<String, dynamic>;

Json asJson(Object? value) =>
    value is Map ? value.map<String, dynamic>((key, item) => MapEntry(key.toString(), item)) : <String, dynamic>{};

List<Json> asJsonList(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is Map) asJson(item),
      ]
    : <Json>[];

String _text(Object? value, [String fallback = '']) => value is String ? value : fallback;
String? _optionalText(Object? value) => value is String && value.isNotEmpty ? value : null;
int _integer(Object? value, [int fallback = 0]) => value is int ? value : (value is num ? value.toInt() : fallback);
bool _flag(Object? value, [bool fallback = false]) => value is bool ? value : fallback;
DateTime? _instant(Object? value) => value is String ? DateTime.tryParse(value) : null;
List<String> _texts(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is String) item,
      ]
    : <String>[];

// ---------------------------------------------------------------------------------------------- lists

class Pagination {
  const Pagination({this.page = 1, this.perPage = 20, this.total = 0, this.totalPages = 0, this.hasNext = false});

  factory Pagination.fromJson(Json json) => Pagination(
    page: _integer(json['page'], 1),
    perPage: _integer(json['per_page'], 20),
    total: _integer(json['total']),
    totalPages: _integer(json['total_pages']),
    hasNext: _flag(json['has_next']),
  );

  final int page;
  final int perPage;
  final int total;
  final int totalPages;
  final bool hasNext;
}

/// One page of a list: `{ items: [...], pagination: {...} }`.
class PageOf<T> {
  const PageOf(this.items, this.pagination);

  factory PageOf.fromJson(Object? data, T Function(Json json) convert) {
    final json = asJson(data);
    return PageOf<T>([
      for (final item in asJsonList(json['items'])) convert(item),
    ], Pagination.fromJson(asJson(json['pagination'])));
  }

  final List<T> items;
  final Pagination pagination;
}

// ---------------------------------------------------------------------------------------------- people and companies

class CompanyRef {
  const CompanyRef({required this.id, required this.name, this.companyCode = '', this.isActive = true});

  factory CompanyRef.fromJson(Json json) => CompanyRef(
    id: _text(json['id']),
    name: _text(json['name']),
    companyCode: _text(json['company_code']),
    isActive: _flag(json['is_active'], true),
  );

  final String id;
  final String name;
  final String companyCode;
  final bool isActive;
}

class PersonRef {
  const PersonRef({required this.id, required this.fullName, this.username});

  factory PersonRef.fromJson(Json json) =>
      PersonRef(id: _text(json['id']), fullName: _text(json['full_name']), username: _optionalText(json['username']));

  final String id;
  final String fullName;
  final String? username;
}

class Company {
  const Company({
    required this.id,
    required this.name,
    required this.companyCode,
    this.phone,
    this.address,
    this.isActive = true,
    this.createdAt,
    this.employeeCount,
    this.shipmentCount,
  });

  factory Company.fromJson(Json json) => Company(
    id: _text(json['id']),
    name: _text(json['name']),
    companyCode: _text(json['company_code']),
    phone: _optionalText(json['phone']),
    address: _optionalText(json['address']),
    isActive: _flag(json['is_active'], true),
    createdAt: _instant(json['created_at']),
    employeeCount: json['employee_count'] is int ? json['employee_count'] as int : null,
    shipmentCount: json['shipment_count'] is int ? json['shipment_count'] as int : null,
  );

  final String id;
  final String name;
  final String companyCode;
  final String? phone;
  final String? address;
  final bool isActive;
  final DateTime? createdAt;
  final int? employeeCount;
  final int? shipmentCount;
}

class UserAccount {
  const UserAccount({
    required this.id,
    required this.username,
    required this.fullName,
    required this.role,
    this.isActive = true,
    this.companyId,
    this.company,
    this.lastLoginAt,
    this.createdAt,
  });

  factory UserAccount.fromJson(Json json) => UserAccount(
    id: _text(json['id']),
    username: _text(json['username']),
    fullName: _text(json['full_name']),
    role: _text(json['role'], 'EMPLOYEE'),
    isActive: _flag(json['is_active'], true),
    companyId: _optionalText(json['company_id']),
    company: json['company'] is Map ? CompanyRef.fromJson(asJson(json['company'])) : null,
    lastLoginAt: _instant(json['last_login_at']),
    createdAt: _instant(json['created_at']),
  );

  final String id;
  final String username;
  final String fullName;
  final String role;
  final bool isActive;
  final String? companyId;
  final CompanyRef? company;
  final DateTime? lastLoginAt;
  final DateTime? createdAt;

  bool get isAdmin => role == 'SUPER_ADMIN';
  String get roleLabel => isAdmin ? 'مدیر مرکزی' : 'کارمند';
}

// ---------------------------------------------------------------------------------------------- session

class UploadSettings {
  const UploadSettings({
    this.maxFileSizeBytes = 10 * 1024 * 1024,
    this.maxFilesPerUpload = 10,
    this.allowedExtensions = const <String>[],
    this.customerVisibleDefault = true,
  });

  factory UploadSettings.fromJson(Json json) => UploadSettings(
    maxFileSizeBytes: _integer(json['max_file_size_bytes'], 10 * 1024 * 1024),
    maxFilesPerUpload: _integer(json['max_files_per_upload'], 10),
    allowedExtensions: _texts(json['allowed_extensions']),
    customerVisibleDefault: _flag(json['customer_visible_default'], true),
  );

  final int maxFileSizeBytes;
  final int maxFilesPerUpload;
  final List<String> allowedExtensions;
  final bool customerVisibleDefault;
}

/// What the server tells its clients about its configuration (`app_settings`).
class ClientSettings {
  const ClientSettings({
    this.upload = const UploadSettings(),
    this.trackingCode = const TrackingCodeRules(),
    this.passwordMinLength = 10,
    this.defaultPageSize = 20,
    this.maxPageSize = 100,
  });

  factory ClientSettings.fromJson(Json json) {
    final tracking = asJson(json['tracking_code']);
    const defaults = TrackingCodeRules();
    return ClientSettings(
      upload: UploadSettings.fromJson(asJson(json['upload'])),
      trackingCode: TrackingCodeRules(
        minLength: _integer(tracking['min_length'], defaults.minLength),
        maxLength: _integer(tracking['max_length'], defaults.maxLength),
        pattern: _text(tracking['pattern'], defaults.pattern),
      ),
      passwordMinLength: _integer(asJson(json['password'])['min_length'], 10),
      defaultPageSize: _integer(asJson(json['pagination'])['default_page_size'], 20),
      maxPageSize: _integer(asJson(json['pagination'])['max_page_size'], 100),
    );
  }

  final UploadSettings upload;
  final TrackingCodeRules trackingCode;
  final int passwordMinLength;
  final int defaultPageSize;
  final int maxPageSize;
}

/// A signed-in session: the tokens and what the server said about the user.
class AuthSession {
  AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
    required Json user,
    required List<String> permissions,
    required Json settings,
  }) : _userJson = user,
       _settingsJson = settings,
       user = UserAccount.fromJson(user),
       permissions = Set<String>.unmodifiable(permissions),
       settings = ClientSettings.fromJson(settings);

  /// From the `data` of a login, refresh or change-password response.
  /// Returns `null` when the response does not carry the tokens.
  static AuthSession? fromAuthResponse(Object? data, DateTime now) {
    final json = asJson(data);
    final access = _optionalText(json['access_token']);
    final refresh = _optionalText(json['refresh_token']);
    if (access == null || refresh == null) return null;
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: now.add(Duration(seconds: _integer(json['expires_in'], 900))),
      refreshExpiresAt: now.add(Duration(seconds: _integer(json['refresh_expires_in'], 1209600))),
      user: asJson(json['user']),
      permissions: _texts(json['permissions']),
      settings: asJson(json['app_settings']),
    );
  }

  /// From the form written by [toStorageJson]. Returns `null` for anything that is not a complete session.
  static AuthSession? fromStorageJson(Object? stored) {
    final json = asJson(stored);
    final access = _optionalText(json['access_token']);
    final refresh = _optionalText(json['refresh_token']);
    final accessExpiry = _instant(json['access_expires_at']);
    final refreshExpiry = _instant(json['refresh_expires_at']);
    final user = asJson(json['user']);
    if (json['version'] != 1 || access == null || refresh == null || accessExpiry == null || refreshExpiry == null) {
      return null;
    }
    if (_text(user['id']).isEmpty) return null;
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: accessExpiry,
      refreshExpiresAt: refreshExpiry,
      user: user,
      permissions: _texts(json['permissions']),
      settings: asJson(json['app_settings']),
    );
  }

  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
  final UserAccount user;
  final Set<String> permissions;
  final ClientSettings settings;
  final Json _userJson;
  final Json _settingsJson;

  bool can(String permission) => permissions.contains(permission);

  /// True for the central administrator, who sees the data of every company.
  bool get isGlobal => can('scope:global');

  /// The same tokens with the profile of a `/auth/me` response.
  AuthSession withProfile(Object? profile) {
    final json = asJson(profile);
    return AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessExpiresAt: accessExpiresAt,
      refreshExpiresAt: refreshExpiresAt,
      user: json['user'] is Map ? asJson(json['user']) : _userJson,
      permissions: json['permissions'] is List ? _texts(json['permissions']) : permissions.toList(),
      settings: json['app_settings'] is Map ? asJson(json['app_settings']) : _settingsJson,
    );
  }

  Json toStorageJson() => <String, dynamic>{
    'version': 1,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'access_expires_at': accessExpiresAt.toUtc().toIso8601String(),
    'refresh_expires_at': refreshExpiresAt.toUtc().toIso8601String(),
    'user': _userJson,
    'permissions': permissions.toList(),
    'app_settings': _settingsJson,
  };
}

// ---------------------------------------------------------------------------------------------- shipments

class Shipment {
  const Shipment({
    required this.id,
    required this.trackingCode,
    this.trackingCodeType = 'AUTO',
    this.status = 'ACTIVE',
    this.description,
    this.companyId = '',
    this.company,
    this.createdBy,
    this.documentCount = 0,
    this.createdAt,
    this.updatedAt,
  });

  factory Shipment.fromJson(Json json) => Shipment(
    id: _text(json['id']),
    trackingCode: _text(json['tracking_code']),
    trackingCodeType: _text(json['tracking_code_type'], 'AUTO'),
    status: _text(json['status'], 'ACTIVE'),
    description: _optionalText(json['description']),
    companyId: _text(json['company_id']),
    company: json['company'] is Map ? CompanyRef.fromJson(asJson(json['company'])) : null,
    createdBy: json['created_by'] is Map ? PersonRef.fromJson(asJson(json['created_by'])) : null,
    documentCount: _integer(json['document_count']),
    createdAt: _instant(json['created_at']),
    updatedAt: _instant(json['updated_at']),
  );

  final String id;
  final String trackingCode;
  final String trackingCodeType;
  final String status;
  final String? description;
  final String companyId;
  final CompanyRef? company;
  final PersonRef? createdBy;
  final int documentCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isArchived => status == 'ARCHIVED';
  bool get hasManualCode => trackingCodeType == 'MANUAL';
  String get statusLabel => isArchived ? 'بایگانی‌شده' : 'فعال';
  String get codeTypeLabel => hasManualCode ? 'دستی' : 'خودکار';
}

class ShipmentDocument {
  const ShipmentDocument({
    required this.id,
    required this.originalName,
    this.mimeType = 'application/octet-stream',
    this.extension = '',
    this.fileSize = 0,
    this.isCustomerVisible = false,
    this.uploadedBy,
    this.createdAt,
  });

  factory ShipmentDocument.fromJson(Json json) => ShipmentDocument(
    id: _text(json['id']),
    originalName: _text(json['original_name']),
    mimeType: _text(json['mime_type'], 'application/octet-stream'),
    extension: _text(json['extension']),
    fileSize: _integer(json['file_size']),
    isCustomerVisible: _flag(json['is_customer_visible']),
    uploadedBy: json['uploaded_by'] is Map ? PersonRef.fromJson(asJson(json['uploaded_by'])) : null,
    createdAt: _instant(json['created_at']),
  );

  final String id;
  final String originalName;
  final String mimeType;
  final String extension;
  final int fileSize;
  final bool isCustomerVisible;
  final PersonRef? uploadedBy;
  final DateTime? createdAt;
}

class TrackingHistoryEntry {
  const TrackingHistoryEntry({required this.id, this.oldCode, required this.newCode, this.changedBy, this.changedAt});

  factory TrackingHistoryEntry.fromJson(Json json) => TrackingHistoryEntry(
    id: _text(json['id']),
    oldCode: _optionalText(json['old_code']),
    newCode: _text(json['new_code']),
    changedBy: json['changed_by'] is Map ? PersonRef.fromJson(asJson(json['changed_by'])) : null,
    changedAt: _instant(json['changed_at']),
  );

  final String id;
  final String? oldCode;
  final String newCode;
  final PersonRef? changedBy;
  final DateTime? changedAt;
}

// ---------------------------------------------------------------------------------------------- goods fields

class ProductFieldOption {
  const ProductFieldOption({required this.value, required this.label});

  factory ProductFieldOption.fromJson(Json json) =>
      ProductFieldOption(value: _text(json['value']), label: _text(json['label']));

  final String value;
  final String label;
}

/// The definition of one dynamic field of the goods of a shipment.
class ProductField {
  const ProductField({
    required this.id,
    required this.fieldKey,
    required this.label,
    required this.dataType,
    this.isRequired = false,
    this.isActive = true,
    this.isCustomerVisible = false,
    this.displayOrder = 0,
    this.validationRules = const <String, dynamic>{},
    this.options = const <ProductFieldOption>[],
    this.version = 1,
  });

  factory ProductField.fromJson(Json json) => ProductField(
    id: _text(json['id']),
    fieldKey: _text(json['field_key']),
    label: _text(json['label']),
    dataType: _text(json['data_type'], 'TEXT'),
    isRequired: _flag(json['is_required']),
    isActive: _flag(json['is_active'], true),
    isCustomerVisible: _flag(json['is_customer_visible']),
    displayOrder: _integer(json['display_order']),
    validationRules: asJson(json['validation_rules']),
    options: [for (final item in asJsonList(json['options'])) ProductFieldOption.fromJson(item)],
    version: _integer(json['version'], 1),
  );

  final String id;
  final String fieldKey;
  final String label;
  final String dataType;
  final bool isRequired;
  final bool isActive;
  final bool isCustomerVisible;
  final int displayOrder;
  final Json validationRules;
  final List<ProductFieldOption> options;
  final int version;

  bool get hasOptions => dataType == 'SELECT' || dataType == 'MULTI_SELECT';
}

/// The value a shipment holds for one field, together with the definition of that field.
class ProductValueItem {
  const ProductValueItem({required this.field, this.value, this.displayValue, this.isOutdated = false});

  factory ProductValueItem.fromJson(Json json) => ProductValueItem(
    field: ProductField.fromJson(asJson(json['field'])),
    value: json['value'],
    displayValue: json['display_value'],
    isOutdated: _flag(json['is_outdated']),
  );

  final ProductField field;

  /// The stored value in the API format of the field's type; `null` when nothing is stored.
  final Object? value;

  /// The value as it is shown: option labels instead of option values.
  final Object? displayValue;

  /// True when the definition of the field has changed since the value was stored.
  final bool isOutdated;
}

// ---------------------------------------------------------------------------------------------- administration

class AuditLogEntry {
  const AuditLogEntry({
    required this.id,
    required this.action,
    this.entityType = '',
    this.entityId,
    this.metadata,
    this.ipAddress,
    this.requestId,
    this.user,
    this.createdAt,
  });

  factory AuditLogEntry.fromJson(Json json) => AuditLogEntry(
    id: _text(json['id']),
    action: _text(json['action']),
    entityType: _text(json['entity_type']),
    entityId: _optionalText(json['entity_id']),
    metadata: json['metadata'],
    ipAddress: _optionalText(json['ip_address']),
    requestId: _optionalText(json['request_id']),
    user: json['user'] is Map ? PersonRef.fromJson(asJson(json['user'])) : null,
    createdAt: _instant(json['created_at']),
  );

  final String id;
  final String action;
  final String entityType;
  final String? entityId;
  final Object? metadata;
  final String? ipAddress;
  final String? requestId;
  final PersonRef? user;
  final DateTime? createdAt;
}

class ActiveCount {
  const ActiveCount({this.total = 0, this.active = 0});

  factory ActiveCount.fromJson(Json json) =>
      ActiveCount(total: _integer(json['total']), active: _integer(json['active']));

  final int total;
  final int active;
}

class DashboardSummary {
  const DashboardSummary({
    this.isGlobal = false,
    this.company,
    this.companies,
    this.employees,
    this.shipmentsTotal = 0,
    this.shipmentsActive = 0,
    this.shipmentsArchived = 0,
    this.documents = 0,
    this.recentShipments = const <Shipment>[],
  });

  factory DashboardSummary.fromJson(Json json) {
    final shipments = asJson(json['shipments']);
    return DashboardSummary(
      isGlobal: json['scope'] == 'GLOBAL',
      company: json['company'] is Map ? CompanyRef.fromJson(asJson(json['company'])) : null,
      companies: json['companies'] is Map ? ActiveCount.fromJson(asJson(json['companies'])) : null,
      employees: json['employees'] is Map ? ActiveCount.fromJson(asJson(json['employees'])) : null,
      shipmentsTotal: _integer(shipments['total']),
      shipmentsActive: _integer(shipments['active']),
      shipmentsArchived: _integer(shipments['archived']),
      documents: _integer(json['documents']),
      recentShipments: [for (final item in asJsonList(json['recent_shipments'])) Shipment.fromJson(item)],
    );
  }

  final bool isGlobal;
  final CompanyRef? company;
  final ActiveCount? companies;
  final ActiveCount? employees;
  final int shipmentsTotal;
  final int shipmentsActive;
  final int shipmentsArchived;
  final int documents;
  final List<Shipment> recentShipments;
}

// ---------------------------------------------------------------------------------------------- customer portal

/// Temporary access to one shipment, granted for a correct tracking code.
class CustomerGrant {
  const CustomerGrant({required this.accessToken, this.expiresAt});

  static CustomerGrant? fromJson(Object? data) {
    final json = asJson(data);
    final token = _optionalText(json['access_token']);
    return token == null ? null : CustomerGrant(accessToken: token, expiresAt: _instant(json['expires_at']));
  }

  final String accessToken;
  final DateTime? expiresAt;
}

class CustomerProductDetail {
  const CustomerProductDetail({required this.label, required this.dataType, this.value});

  factory CustomerProductDetail.fromJson(Json json) => CustomerProductDetail(
    label: _text(json['label']),
    dataType: _text(json['data_type'], 'TEXT'),
    value: json['value'],
  );

  final String label;
  final String dataType;
  final Object? value;
}

class CustomerShipment {
  const CustomerShipment({
    required this.trackingCode,
    this.status = 'ACTIVE',
    this.companyName,
    this.description,
    this.registeredAt,
    this.documentCount = 0,
    this.productDetails = const <CustomerProductDetail>[],
    this.sessionExpiresAt,
  });

  factory CustomerShipment.fromJson(Json json) => CustomerShipment(
    trackingCode: _text(json['tracking_code']),
    status: _text(json['status'], 'ACTIVE'),
    companyName: _optionalText(json['company_name']),
    description: _optionalText(json['description']),
    registeredAt: _instant(json['registered_at']),
    documentCount: _integer(json['document_count']),
    productDetails: [for (final item in asJsonList(json['product_details'])) CustomerProductDetail.fromJson(item)],
    sessionExpiresAt: _instant(json['session_expires_at']),
  );

  final String trackingCode;
  final String status;
  final String? companyName;
  final String? description;
  final DateTime? registeredAt;
  final int documentCount;
  final List<CustomerProductDetail> productDetails;
  final DateTime? sessionExpiresAt;
}

class CustomerDocument {
  const CustomerDocument({
    required this.id,
    required this.name,
    this.mimeType = 'application/octet-stream',
    this.extension = '',
    this.fileSize = 0,
    this.uploadedAt,
  });

  factory CustomerDocument.fromJson(Json json) => CustomerDocument(
    id: _text(json['id']),
    name: _text(json['name']),
    mimeType: _text(json['mime_type'], 'application/octet-stream'),
    extension: _text(json['extension']),
    fileSize: _integer(json['file_size']),
    uploadedAt: _instant(json['uploaded_at']),
  );

  final String id;
  final String name;
  final String mimeType;
  final String extension;
  final int fileSize;
  final DateTime? uploadedAt;
}
