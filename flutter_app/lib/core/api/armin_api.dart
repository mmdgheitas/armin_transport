/// Typed access to the endpoints of the Armin Transport API.
library;

import 'api_client.dart';
import 'api_error.dart';
import 'models.dart';

/// The outcome of a change: the new state and the confirmation message of the server.
class Done<T> {
  const Done(this.value, this.message);

  final T value;
  final String message;
}

String _id(String value) => Uri.encodeComponent(value);

class ArminApi {
  const ArminApi(this.client);

  final ApiClient client;

  // -------------------------------------------------------------------------------------------- server

  /// The version the server reports about itself. Completes with an error when the address is not an Armin server.
  Future<String> serverVersion() async {
    final result = await client.get('/health', auth: false);
    final version = result.json['version'];
    return version is String ? version : '';
  }

  Future<DashboardSummary> dashboard() async =>
      DashboardSummary.fromJson((await client.get('/dashboard/summary')).json);

  // -------------------------------------------------------------------------------------------- shipments

  Future<PageOf<Shipment>> shipments({
    int page = 1,
    int? perPage,
    String? search,
    String? status,
    String? codeType,
    String? companyId,
    String? createdFrom,
    String? createdTo,
    String? sort,
  }) async {
    final result = await client.get(
      '/shipments',
      query: {
        'page': page,
        'per_page': perPage,
        'q': search,
        'status': status,
        'tracking_code_type': codeType,
        'company_id': companyId,
        'created_from': createdFrom,
        'created_to': createdTo,
        'sort': sort,
      },
    );
    return PageOf<Shipment>.fromJson(result.data, Shipment.fromJson);
  }

  Future<Shipment> shipment(String id) async => Shipment.fromJson((await client.get('/shipments/${_id(id)}')).json);

  /// [companyId] is needed only from an administrator; [trackingCode] only for a manual code.
  Future<Done<Shipment>> createShipment({
    String? companyId,
    String? trackingCode,
    String? description,
    Json? productValues,
  }) async {
    final result = await client.post(
      '/shipments',
      json: <String, dynamic>{
        'company_id': ?companyId,
        'tracking_code': ?trackingCode,
        'description': ?description,
        'product_values': ?productValues,
      },
    );
    return Done(Shipment.fromJson(result.json), result.message);
  }

  /// A `null` [description] removes the description.
  Future<Done<Shipment>> updateDescription(String id, String? description) async {
    final result = await client.patch('/shipments/${_id(id)}', json: <String, dynamic>{'description': description});
    return Done(Shipment.fromJson(result.json), result.message);
  }

  Future<Done<Shipment>> archiveShipment(String id) async {
    final result = await client.post('/shipments/${_id(id)}/archive');
    return Done(Shipment.fromJson(result.json), result.message);
  }

  Future<Done<Shipment>> unarchiveShipment(String id) async {
    final result = await client.post('/shipments/${_id(id)}/unarchive');
    return Done(Shipment.fromJson(result.json), result.message);
  }

  /// Replaces the tracking code: with [manualCode], or with a newly generated one when it is `null`.
  Future<Done<Shipment>> changeTrackingCode(String id, {String? manualCode}) async {
    final result = await client.post(
      '/shipments/${_id(id)}/tracking-code',
      json: manualCode == null ? <String, dynamic>{'generate': true} : <String, dynamic>{'tracking_code': manualCode},
    );
    return Done(Shipment.fromJson(result.json), result.message);
  }

  Future<PageOf<TrackingHistoryEntry>> trackingHistory(String id, {int page = 1, int? perPage}) async {
    final result = await client.get(
      '/shipments/${_id(id)}/tracking-history',
      query: {'page': page, 'per_page': perPage},
    );
    return PageOf<TrackingHistoryEntry>.fromJson(result.data, TrackingHistoryEntry.fromJson);
  }

  /// Ends every customer session of the shipment. The value is the number of sessions ended.
  Future<Done<int>> revokeCustomerSessions(String id) async {
    final result = await client.post('/shipments/${_id(id)}/customer-sessions/revoke');
    final revoked = result.json['revoked'];
    return Done(revoked is int ? revoked : 0, result.message);
  }

  // -------------------------------------------------------------------------------------------- goods

  Future<List<ProductValueItem>> productValues(String shipmentId) async {
    final result = await client.get('/shipments/${_id(shipmentId)}/product-values');
    return [for (final item in asJsonList(result.json['items'])) ProductValueItem.fromJson(item)];
  }

  Future<Done<List<ProductValueItem>>> saveProductValues(String shipmentId, Json values) async {
    final result = await client.put(
      '/shipments/${_id(shipmentId)}/product-values',
      json: <String, dynamic>{'values': values},
    );
    return Done([for (final item in asJsonList(result.json['items'])) ProductValueItem.fromJson(item)], result.message);
  }

  /// Every active field, in display order: the form for the goods of a new shipment.
  Future<List<ProductField>> activeProductFields({int pageSize = 100}) async {
    final fields = <ProductField>[];
    for (var page = 1; ; page += 1) {
      final batch = await productFields(page: page, perPage: pageSize);
      fields.addAll(batch.items);
      if (!batch.pagination.hasNext || batch.items.isEmpty) break;
    }
    return fields;
  }

  Future<PageOf<ProductField>> productFields({
    int page = 1,
    int? perPage,
    String? search,
    bool includeInactive = false,
  }) async {
    final result = await client.get(
      '/product-fields',
      query: {'page': page, 'per_page': perPage, 'q': search, 'include_inactive': includeInactive ? 'true' : null},
    );
    return PageOf<ProductField>.fromJson(result.data, ProductField.fromJson);
  }

  Future<Done<ProductField>> createProductField(Json definition) async {
    final result = await client.post('/product-fields', json: definition);
    return Done(ProductField.fromJson(result.json), result.message);
  }

  Future<Done<ProductField>> updateProductField(String id, Json changes) async {
    final result = await client.patch('/product-fields/${_id(id)}', json: changes);
    return Done(ProductField.fromJson(result.json), result.message);
  }

  // -------------------------------------------------------------------------------------------- documents

  Future<PageOf<ShipmentDocument>> documents(String shipmentId, {int page = 1, int? perPage}) async {
    final result = await client.get(
      '/shipments/${_id(shipmentId)}/documents',
      query: {'page': page, 'per_page': perPage},
    );
    return PageOf<ShipmentDocument>.fromJson(result.data, ShipmentDocument.fromJson);
  }

  Future<Done<List<ShipmentDocument>>> uploadDocuments(
    String shipmentId, {
    required List<UploadPart> files,
    required bool customerVisible,
    void Function(int sent, int total)? onProgress,
  }) async {
    final result = await client.upload(
      '/shipments/${_id(shipmentId)}/documents',
      files: files,
      fields: <String, String>{'customer_visible': customerVisible ? 'true' : 'false'},
      onProgress: onProgress,
    );
    return Done([for (final item in asJsonList(result.data)) ShipmentDocument.fromJson(item)], result.message);
  }

  Future<Done<ShipmentDocument>> setDocumentVisibility(String documentId, {required bool customerVisible}) async {
    final result = await client.patch(
      '/documents/${_id(documentId)}',
      json: <String, dynamic>{'is_customer_visible': customerVisible},
    );
    return Done(ShipmentDocument.fromJson(result.json), result.message);
  }

  Future<String> deleteDocument(String documentId) async =>
      (await client.delete('/documents/${_id(documentId)}')).message;

  Future<DownloadedFile> downloadDocument(String documentId) =>
      client.download('/documents/${_id(documentId)}/download');

  // -------------------------------------------------------------------------------------------- companies

  Future<PageOf<Company>> companies({int page = 1, int? perPage, String? search, bool? isActive}) async {
    final result = await client.get(
      '/companies',
      query: {'page': page, 'per_page': perPage, 'q': search, 'is_active': isActive},
    );
    return PageOf<Company>.fromJson(result.data, Company.fromJson);
  }

  /// A company with the numbers of its employees and shipments.
  Future<Company> company(String id) async => Company.fromJson((await client.get('/companies/${_id(id)}')).json);

  Future<Done<Company>> createCompany(Json company) async {
    final result = await client.post('/companies', json: company);
    return Done(Company.fromJson(result.json), result.message);
  }

  Future<Done<Company>> updateCompany(String id, Json changes) async {
    final result = await client.patch('/companies/${_id(id)}', json: changes);
    return Done(Company.fromJson(result.json), result.message);
  }

  // -------------------------------------------------------------------------------------------- users

  Future<PageOf<UserAccount>> users({
    int page = 1,
    int? perPage,
    String? search,
    String? companyId,
    String? role,
    bool? isActive,
  }) async {
    final result = await client.get(
      '/users',
      query: {
        'page': page,
        'per_page': perPage,
        'q': search,
        'company_id': companyId,
        'role': role,
        'is_active': isActive,
      },
    );
    return PageOf<UserAccount>.fromJson(result.data, UserAccount.fromJson);
  }

  Future<Done<UserAccount>> createUser(Json user) async {
    final result = await client.post('/users', json: user);
    return Done(UserAccount.fromJson(result.json), result.message);
  }

  Future<Done<UserAccount>> updateUser(String id, Json changes) async {
    final result = await client.patch('/users/${_id(id)}', json: changes);
    return Done(UserAccount.fromJson(result.json), result.message);
  }

  Future<String> resetPassword(String userId, String newPassword) async {
    final result = await client.post(
      '/users/${_id(userId)}/reset-password',
      json: <String, dynamic>{'new_password': newPassword},
    );
    return result.message;
  }

  // -------------------------------------------------------------------------------------------- audit log

  Future<PageOf<AuditLogEntry>> auditLogs({
    int page = 1,
    int? perPage,
    String? action,
    String? entityType,
    String? userId,
    String? createdFrom,
    String? createdTo,
  }) async {
    final result = await client.get(
      '/audit-logs',
      query: {
        'page': page,
        'per_page': perPage,
        'action': action,
        'entity_type': entityType,
        'user_id': userId,
        'created_from': createdFrom,
        'created_to': createdTo,
      },
    );
    return PageOf<AuditLogEntry>.fromJson(result.data, AuditLogEntry.fromJson);
  }

  // -------------------------------------------------------------------------------------------- customer portal

  /// Exchanges a tracking code for temporary access to its shipment.
  Future<CustomerGrant> customerLookup(String trackingCode) async {
    final result = await client.post(
      '/customer/lookup',
      auth: false,
      json: <String, dynamic>{'tracking_code': trackingCode},
    );
    final grant = CustomerGrant.fromJson(result.data);
    if (grant == null) throw ApiError(code: 'unexpected_response');
    return grant;
  }

  String _access(CustomerGrant grant, String rest) => '/customer/access/${_id(grant.accessToken)}$rest';

  Future<CustomerShipment> customerShipment(CustomerGrant grant) async =>
      CustomerShipment.fromJson((await client.get(_access(grant, '/shipment'), auth: false)).json);

  Future<PageOf<CustomerDocument>> customerDocuments(CustomerGrant grant, {int page = 1, int? perPage}) async {
    final result = await client.get(
      _access(grant, '/documents'),
      auth: false,
      query: {'page': page, 'per_page': perPage},
    );
    return PageOf<CustomerDocument>.fromJson(result.data, CustomerDocument.fromJson);
  }

  Future<DownloadedFile> downloadCustomerDocument(CustomerGrant grant, String documentId) =>
      client.download(_access(grant, '/documents/${_id(documentId)}/download'), auth: false);

  /// Ends the access before it expires (best effort: it expires on its own in any case).
  Future<void> endCustomerAccess(CustomerGrant grant) async {
    try {
      await client.post(_access(grant, '/revoke'), auth: false);
    } on ApiError {
      // Nothing to do: the grant is forgotten by the app either way.
    }
  }
}
