/// The list of shipments with its filters.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/models.dart';
import '../../core/product_fields.dart';
import '../../core/providers.dart';
import '../../routing.dart';
import '../../widgets/fields.dart';
import '../../widgets/form_layout.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';
import '../shared/pick_lists.dart';
import 'shipment_widgets.dart';

const String _defaultSort = '-created_at';

const List<(String?, String)> _sortOptions = [
  ('-created_at', 'جدیدترین'),
  ('created_at', 'قدیمی‌ترین'),
  ('-updated_at', 'آخرین تغییر'),
  ('tracking_code', 'کد رهگیری (صعودی)'),
];

/// The filters in effect. Records compare by value, so the table loads again exactly when one of them changes.
typedef _Filters = ({
  String search,
  String? status,
  String? codeType,
  String? companyId,
  String? from,
  String? to,
  String sort,
});

const _Filters _noFilters = (
  search: '',
  status: null,
  codeType: null,
  companyId: null,
  from: null,
  to: null,
  sort: _defaultSort,
);

class ShipmentsPage extends ConsumerStatefulWidget {
  const ShipmentsPage({super.key});

  @override
  ConsumerState<ShipmentsPage> createState() => _ShipmentsPageState();
}

class _ShipmentsPageState extends ConsumerState<ShipmentsPage> {
  final GlobalKey<PagedTableState<Shipment>> _table = GlobalKey<PagedTableState<Shipment>>();
  final TextEditingController _search = TextEditingController();
  String? _status;
  String? _codeType;
  String? _companyId;
  String _sort = _defaultSort;
  JalaliDateValue _from = const JalaliDateValue();
  JalaliDateValue _to = const JalaliDateValue();
  Map<String, String> _errors = const <String, String>{};

  /// Changes when the filters are cleared, so that the date fields start over.
  int _formVersion = 0;

  _Filters _applied = _noFilters;
  List<Company> _companies = const <Company>[];

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authProvider);
    if (auth != null && auth.isGlobal) _loadCompanies(auth);
  }

  Future<void> _loadCompanies(AuthSession auth) async {
    try {
      final companies = await loadAllCompanies(ref.read(apiProvider), auth.settings);
      if (mounted) setState(() => _companies = companies);
    } catch (_) {
      // The list works without the company filter; the table reports real failures.
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _hasFilters =>
      _applied.search.isNotEmpty ||
      _applied.status != null ||
      _applied.codeType != null ||
      _applied.companyId != null ||
      _applied.from != null ||
      _applied.to != null;

  void _apply() {
    final errors = <String, String>{
      if (_from.incomplete) 'from': invalidDateMessage,
      if (_to.incomplete) 'to': invalidDateMessage,
    };
    setState(() {
      _errors = errors;
      if (errors.isNotEmpty) return;
      _applied = (
        search: _search.text.trim(),
        status: _status,
        codeType: _codeType,
        companyId: _companyId,
        from: _from.date,
        to: _to.date,
        sort: _sort,
      );
    });
  }

  void _clear() {
    setState(() {
      _search.clear();
      _status = null;
      _codeType = null;
      _companyId = null;
      _from = const JalaliDateValue();
      _to = const JalaliDateValue();
      _errors = const <String, String>{};
      _formVersion += 1;
      _applied = (
        search: '',
        status: null,
        codeType: null,
        companyId: null,
        from: null,
        to: null,
        sort: _sort,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final api = ref.watch(apiProvider);
    // A shipment was changed on its own page, which lies on top of this list.
    ref.listen<int>(shipmentsRevisionProvider, (previous, next) => _table.currentState?.reload());
    if (auth == null) return const SizedBox.shrink();
    final isGlobal = auth.isGlobal;
    final canCreate = auth.can('shipment:create');
    final applied = _applied;
    final hasFilters = _hasFilters;
    Widget createButton() => FilledButton.icon(
      onPressed: () => context.go(AppPaths.newShipment),
      icon: const Icon(Icons.add, size: 18),
      label: const Text('ثبت محمولهٔ جدید'),
    );

    return PageBody(
      children: [
        PageHeader(
          title: 'محموله‌ها',
          description: isGlobal ? 'محموله‌های همهٔ شرکت‌ها' : 'محموله‌های شرکت شما',
          actions: [if (canCreate) createButton()],
        ),
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilterPanel(
                active: hasFilters,
                onApply: _apply,
                onClear: _clear,
                fields: [
                  AppTextField(
                    label: 'جست‌وجو',
                    controller: _search,
                    placeholder: 'کد رهگیری یا توضیحات',
                    maxLength: 100,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _apply(),
                  ),
                  if (isGlobal)
                    ChoiceField<String>(
                      label: 'شرکت',
                      value: _companyId,
                      options: companyOptions(_companies, placeholder: 'همهٔ شرکت‌ها'),
                      onChanged: (value) => setState(() => _companyId = value),
                    ),
                  ChoiceField<String>(
                    label: 'وضعیت',
                    value: _status,
                    options: const [(null, 'همه'), ('ACTIVE', 'فعال'), ('ARCHIVED', 'بایگانی‌شده')],
                    onChanged: (value) => setState(() => _status = value),
                  ),
                  ChoiceField<String>(
                    label: 'نوع کد رهگیری',
                    value: _codeType,
                    options: const [(null, 'همه'), ('AUTO', 'خودکار'), ('MANUAL', 'دستی')],
                    onChanged: (value) => setState(() => _codeType = value),
                  ),
                  JalaliDateField(
                    key: ValueKey<String>('from-$_formVersion'),
                    label: 'ثبت از تاریخ',
                    initial: _from,
                    error: _errors['from'],
                    onChanged: (value) => _from = value,
                  ),
                  JalaliDateField(
                    key: ValueKey<String>('to-$_formVersion'),
                    label: 'ثبت تا تاریخ',
                    initial: _to,
                    error: _errors['to'],
                    onChanged: (value) => _to = value,
                  ),
                  ChoiceField<String>(
                    label: 'ترتیب',
                    value: _sort,
                    options: _sortOptions,
                    onChanged: (value) => setState(() => _sort = value ?? _defaultSort),
                  ),
                ],
              ),
              PagedTable<Shipment>(
                key: _table,
                filters: applied,
                load: (page) => api.shipments(
                  page: page,
                  search: applied.search.isEmpty ? null : applied.search,
                  status: applied.status,
                  codeType: applied.codeType,
                  companyId: isGlobal ? applied.companyId : null,
                  createdFrom: startOfLocalDay(applied.from),
                  createdTo: endOfLocalDay(applied.to),
                  sort: applied.sort == _defaultSort ? null : applied.sort,
                ),
                emptyIcon: Icons.inventory_2_outlined,
                emptyTitle: hasFilters ? 'محموله‌ای با این مشخصات پیدا نشد.' : 'هنوز محموله‌ای ثبت نشده است.',
                emptyText: hasFilters ? 'فیلترها را تغییر دهید یا حذف کنید.' : null,
                emptyAction: !hasFilters && canCreate ? createButton() : null,
                onOpen: (shipment) => context.go(AppPaths.shipment(shipment.id)),
                columns: shipmentColumns(showCompany: isGlobal, detailed: true),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
