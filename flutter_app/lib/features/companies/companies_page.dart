/// The transport companies that use the system: the list, and the form for a new or an existing company.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../routing.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/feedback.dart';
import '../../widgets/fields.dart';
import '../../widgets/form_layout.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';

/// The filters in effect. Records compare by value, so the table loads again exactly when one of them changes.
typedef _Filters = ({String search, bool? isActive});

const _Filters _noFilters = (search: '', isActive: null);

class CompaniesPage extends ConsumerStatefulWidget {
  const CompaniesPage({super.key});

  @override
  ConsumerState<CompaniesPage> createState() => _CompaniesPageState();
}

class _CompaniesPageState extends ConsumerState<CompaniesPage> {
  final GlobalKey<PagedTableState<Company>> _table = GlobalKey<PagedTableState<Company>>();
  final TextEditingController _search = TextEditingController();
  bool? _isActive;
  _Filters _applied = _noFilters;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _apply() => setState(() => _applied = (search: _search.text.trim(), isActive: _isActive));

  void _clear() {
    setState(() {
      _search.clear();
      _isActive = null;
      _applied = _noFilters;
    });
  }

  void _reload() {
    _table.currentState?.reload();
  }

  /// Opens the form for [company], or for a new company when it is `null`.
  /// The form closes with the message of the server once the change is made.
  Future<void> _edit(Company? company) async {
    final message = await showFormDialog<String>(context, (context) => _CompanyDialog(company: company));
    if (message == null) return;
    if (!mounted) return;
    showMessage(context, message);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final api = ref.watch(apiProvider);
    if (auth == null) return const SizedBox.shrink();
    final canUpdate = auth.can('company:update');
    final canSeeUsers = auth.can('user:view');
    final applied = _applied;
    final hasFilters = applied.search.isNotEmpty || applied.isActive != null;

    return PageBody(
      children: [
        PageHeader(
          title: 'شرکت‌ها',
          description: 'شرکت‌های حمل‌ونقلی که از سامانه استفاده می‌کنند. داده‌های هر شرکت از شرکت‌های دیگر جداست.',
          actions: [
            if (auth.can('company:create'))
              FilledButton.icon(
                onPressed: () => _edit(null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('شرکت جدید'),
              ),
          ],
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
                    placeholder: 'نام یا کد شرکت',
                    maxLength: 100,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _apply(),
                  ),
                  ChoiceField<bool>(
                    label: 'وضعیت',
                    value: _isActive,
                    options: const [(null, 'همه'), (true, 'فعال'), (false, 'غیرفعال')],
                    onChanged: (value) => setState(() => _isActive = value),
                  ),
                ],
              ),
              PagedTable<Company>(
                key: _table,
                filters: applied,
                load: (page) => api.companies(
                  page: page,
                  search: applied.search.isEmpty ? null : applied.search,
                  isActive: applied.isActive,
                ),
                emptyIcon: Icons.business_center_outlined,
                emptyTitle: hasFilters ? 'شرکتی با این مشخصات پیدا نشد.' : 'هنوز شرکتی تعریف نشده است.',
                columns: [
                  TableColumn<Company>('نام شرکت', (context, company) => CellText(company.name, bold: true)),
                  TableColumn<Company>('کد', (context, company) => LtrText(company.companyCode)),
                  TableColumn<Company>('تلفن', (context, company) {
                    final phone = company.phone;
                    return phone == null || phone.isEmpty ? const Text(emptyPlaceholder) : LtrText(phone);
                  }),
                  TableColumn<Company>('وضعیت', (context, company) => StatusBadge.active(company.isActive)),
                  TableColumn<Company>('تاریخ ایجاد', (context, company) => Text(formatDateTime(company.createdAt))),
                ],
                actions: !canUpdate && !canSeeUsers
                    ? null
                    : (context, company) => [
                        if (canSeeUsers)
                          IconButton(
                            tooltip: 'کارمندان ${company.name}',
                            icon: const Icon(Icons.group_outlined, size: 20),
                            onPressed: () => context.go(AppPaths.usersOf(company.id)),
                          ),
                        if (canUpdate)
                          IconButton(
                            tooltip: 'ویرایش ${company.name}',
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            onPressed: () => _edit(company),
                          ),
                      ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompanyDialog extends ConsumerStatefulWidget {
  const _CompanyDialog({required this.company});

  /// The company to edit, or `null` for a new one.
  final Company? company;

  @override
  ConsumerState<_CompanyDialog> createState() => _CompanyDialogState();
}

class _CompanyDialogState extends ConsumerState<_CompanyDialog> with FormSupport<_CompanyDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.company?.name ?? '');
  late final TextEditingController _code = TextEditingController(text: widget.company?.companyCode ?? '');
  late final TextEditingController _phone = TextEditingController(text: widget.company?.phone ?? '');
  late final TextEditingController _address = TextEditingController(text: widget.company?.address ?? '');
  late bool _isActive = widget.company?.isActive ?? true;

  /// The company with the numbers of its employees and shipments, once the server has answered.
  Company? _details;

  @override
  Set<String> get fieldNames => const {'name', 'company_code', 'phone', 'address'};

  @override
  void initState() {
    super.initState();
    final company = widget.company;
    if (company != null) _loadDetails(company.id);
  }

  Future<void> _loadDetails(String id) async {
    try {
      final details = await ref.read(apiProvider).company(id);
      if (mounted) setState(() => _details = details);
    } catch (_) {
      // The numbers are for information only; the form works without them.
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  /// Whoever creates a company says whether it starts active; later only some users may change that.
  bool _maySetActive(AuthSession? auth) => widget.company == null || (auth?.can('company:set_active') ?? false);

  Future<void> _submit() async {
    final company = widget.company;
    final name = _name.text.trim();
    final code = _code.text.trim();
    final phone = _phone.text.trim();
    final address = _address.text.trim();
    final payload = <String, dynamic>{
      'name': name,
      'company_code': code,
      'phone': phone.isEmpty ? null : phone,
      'address': address.isEmpty ? null : address,
      if (_maySetActive(ref.read(authProvider))) 'is_active': _isActive,
    };
    final api = ref.read(apiProvider);
    String? message;
    final done = await runForm(
      problems: requiredProblems(
        {'name': name, 'company_code': code},
        const {'name': 'نام شرکت را وارد کنید.', 'company_code': 'کد شرکت را وارد کنید.'},
      ),
      () async {
        final result = company == null
            ? await api.createCompany(payload)
            : await api.updateCompany(company.id, payload);
        message = result.message;
      },
    );
    if (!done) return;
    if (!mounted) return;
    Navigator.of(context).pop(message ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final company = widget.company;
    // Shown only when the server has told both numbers: a guessed zero would be a wrong statement.
    final employees = _details?.employeeCount;
    final shipments = _details?.shipmentCount;
    final maySetActive = _maySetActive(ref.watch(authProvider));
    return FormDialog(
      title: company == null ? 'شرکت جدید' : 'ویرایش ${company.name}',
      submitLabel: company == null ? 'ایجاد شرکت' : 'ذخیرهٔ تغییرات',
      busy: busy,
      error: formError,
      onSubmit: _submit,
      children: [
        if (employees != null && shipments != null)
          Notice('${formatNumber(employees)} کارمند و ${formatNumber(shipments)} محموله برای این شرکت ثبت شده است.'),
        AppTextField(
          label: 'نام شرکت',
          controller: _name,
          isRequired: true,
          maxLength: 200,
          autofocus: company == null,
          enabled: !busy,
          error: errors['name'],
        ),
        AppTextField(
          label: 'کد شرکت',
          controller: _code,
          isRequired: true,
          ltr: true,
          maxLength: 50,
          enabled: !busy,
          error: errors['company_code'],
          hint: 'شناسهٔ کوتاه و یکتا با حروف انگلیسی، رقم، خط تیره یا زیرخط (مثلاً ARMIN).',
        ),
        AppTextField(
          label: 'تلفن',
          controller: _phone,
          ltr: true,
          maxLength: 30,
          keyboardType: TextInputType.phone,
          enabled: !busy,
          error: errors['phone'],
        ),
        AppTextField(
          label: 'نشانی',
          controller: _address,
          multiline: true,
          maxLength: 2000,
          enabled: !busy,
          error: errors['address'],
        ),
        if (maySetActive)
          CheckField(
            label: 'شرکت فعال است',
            value: _isActive,
            enabled: !busy,
            hint: 'با غیرفعال شدن شرکت، کارمندان آن دیگر نمی‌توانند وارد سامانه شوند.',
            onChanged: (value) => setState(() => _isActive = value),
          ),
      ],
    );
  }
}
