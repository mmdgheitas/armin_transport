/// Complete lists for dropdowns, and the notice that tells other screens about a change.
library;

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/armin_api.dart';
import '../../core/api/models.dart';

const int _bulkPageSize = 100;
const int _bulkPageLimit = 50;

/// Loads every page of a list. Bounded, for pick lists such as the companies.
/// The page size follows the limit the server announced, so that the request is never refused.
Future<List<T>> loadAllPages<T>(
  Future<PageOf<T>> Function(int page, int perPage) load, {
  required ClientSettings settings,
}) async {
  final perPage = math.min(_bulkPageSize, settings.maxPageSize);
  final items = <T>[];
  for (var page = 1; page <= _bulkPageLimit; page += 1) {
    final batch = await load(page, perPage);
    items.addAll(batch.items);
    if (!batch.pagination.hasNext || batch.items.isEmpty) break;
  }
  return items;
}

Future<List<Company>> loadAllCompanies(ArminApi api, ClientSettings settings, {bool? isActive}) => loadAllPages<Company>(
  (page, perPage) => api.companies(page: page, perPage: perPage, isActive: isActive),
  settings: settings,
);

/// Every active goods field in display order: the form for the goods of a shipment.
Future<List<ProductField>> loadActiveProductFields(ArminApi api, ClientSettings settings) => loadAllPages<ProductField>(
  (page, perPage) => api.productFields(page: page, perPage: perPage),
  settings: settings,
);

String companyLabel(Company company) => company.isActive
    ? '${company.name} (${company.companyCode})'
    : '${company.name} (${company.companyCode}) - غیرفعال';

/// The options of a company dropdown; with [placeholder] the first one stands for "no company chosen".
List<(String?, String)> companyOptions(List<Company> companies, {String? placeholder}) => [
  if (placeholder != null) (null, placeholder),
  for (final company in companies) (company.id, companyLabel(company)),
];

class RevisionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// Tells the listeners that something they show may have changed.
  void bump() => state += 1;
}

/// Counts the changes made to shipments. The list of shipments stays alive underneath the page of
/// a single shipment; it watches this number and loads again when it moves.
final shipmentsRevisionProvider = NotifierProvider<RevisionNotifier, int>(RevisionNotifier.new);
