/// The employees of the companies: the list, the form for a new or an existing employee, and a new password.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/feedback.dart';
import '../../widgets/fields.dart';
import '../../widgets/form_layout.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';
import '../shared/pick_lists.dart';

/// The filters in effect. Records compare by value, so the table loads again exactly when one of them changes.
typedef _Filters = ({String search, String? companyId, String? role, bool? isActive});

/// What a password has to fulfil, as the server announced it.
String _passwordHint(ClientSettings settings) =>
    'دست‌کم ${toPersianDigits(settings.passwordMinLength)} نویسه؛ نباید شامل نام کاربری باشد.';

class UsersPage extends ConsumerStatefulWidget {
  const UsersPage({super.key, this.companyId});

  /// Shows the employees of this company only; the filter can be changed on the page.
  final String? companyId;

  @override
  ConsumerState<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends ConsumerState<UsersPage> {
  final GlobalKey<PagedTableState<UserAccount>> _table = GlobalKey<PagedTableState<UserAccount>>();
  final TextEditingController _search = TextEditingController();
  late String? _companyId = widget.companyId;
  String? _role;
  bool? _isActive;
  late _Filters _applied = (search: '', companyId: widget.companyId, role: null, isActive: null);

  /// Every company, for the filter and the forms; `null` until the server has answered.
  List<Company>? _companies;
  Future<List<Company>>? _companiesLoad;

  @override
  void initState() {
    super.initState();
    _loadCompanies();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Loads the companies once. After a failure the next call tries again.
  Future<List<Company>> _loadCompanies() {
    final running = _companiesLoad;
    if (running != null) return running;
    final auth = ref.read(authProvider);
    if (auth == null) return Future<List<Company>>.value(const <Company>[]);
    final load = loadAllCompanies(ref.read(apiProvider), auth.settings);
    _companiesLoad = load;
    load.then(
      (companies) {
        if (mounted) setState(() => _companies = companies);
      },
      onError: (Object _) {
        // Whoever needs the list says so: the form shows the failure and offers to try again.
        _companiesLoad = null;
      },
    );
    return load;
  }

  void _apply() {
    setState(() {
      _applied = (search: _search.text.trim(), companyId: _companyId, role: _role, isActive: _isActive);
    });
  }

  void _clear() {
    setState(() {
      _search.clear();
      _companyId = null;
      _role = null;
      _isActive = null;
      _applied = (search: '', companyId: null, role: null, isActive: null);
    });
  }

  void _reload() {
    _table.currentState?.reload();
  }

  /// Shows a form in a dialog; it closes with the message of the server once the change is made.
  Future<void> _openForm(Widget form, {bool reloads = true}) async {
    final message = await showFormDialog<String>(context, (context) => form);
    if (message == null) return;
    if (!mounted) return;
    showMessage(context, message);
    if (reloads) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final api = ref.watch(apiProvider);
    if (auth == null) return const SizedBox.shrink();
    final canUpdate = auth.can('user:update');
    final canReset = auth.can('user:reset_password');
    final applied = _applied;
    final hasFilters =
        applied.search.isNotEmpty || applied.companyId != null || applied.role != null || applied.isActive != null;

    return PageBody(
      children: [
        PageHeader(
          title: 'کاربران',
          description: 'کارمندان شرکت‌ها. هر کارمند فقط به محموله‌های شرکت خود دسترسی دارد.',
          actions: [
            if (auth.can('user:create'))
              FilledButton.icon(
                onPressed: () => _openForm(
                  _UserDialog(
                    user: null,
                    companies: _companies,
                    loadCompanies: _loadCompanies,
                    initialCompanyId: applied.companyId,
                  ),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('کارمند جدید'),
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
                    placeholder: 'نام یا نام کاربری',
                    maxLength: 100,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _apply(),
                  ),
                  ChoiceField<String>(
                    label: 'شرکت',
                    value: _companyId,
                    options: companyOptions(_companies ?? const <Company>[], placeholder: 'همهٔ شرکت‌ها'),
                    onChanged: (value) => setState(() => _companyId = value),
                  ),
                  ChoiceField<String>(
                    label: 'نقش',
                    value: _role,
                    options: const [(null, 'همه'), ('EMPLOYEE', 'کارمند'), ('SUPER_ADMIN', 'مدیر مرکزی')],
                    onChanged: (value) => setState(() => _role = value),
                  ),
                  ChoiceField<bool>(
                    label: 'وضعیت',
                    value: _isActive,
                    options: const [(null, 'همه'), (true, 'فعال'), (false, 'غیرفعال')],
                    onChanged: (value) => setState(() => _isActive = value),
                  ),
                ],
              ),
              PagedTable<UserAccount>(
                key: _table,
                filters: applied,
                load: (page) => api.users(
                  page: page,
                  search: applied.search.isEmpty ? null : applied.search,
                  companyId: applied.companyId,
                  role: applied.role,
                  isActive: applied.isActive,
                ),
                emptyIcon: Icons.group_outlined,
                emptyTitle: 'کاربری با این مشخصات پیدا نشد.',
                columns: [
                  TableColumn<UserAccount>('نام', (context, user) => CellText(user.fullName, bold: true)),
                  TableColumn<UserAccount>('نام کاربری', (context, user) => LtrText(user.username)),
                  TableColumn<UserAccount>(
                    'نقش',
                    (context, user) =>
                        user.isAdmin ? StatusBadge(user.roleLabel, tone: Tone.info) : Text(user.roleLabel),
                  ),
                  TableColumn<UserAccount>(
                    'شرکت',
                    (context, user) => CellText(orDash(user.company?.name), maxWidth: 200),
                  ),
                  TableColumn<UserAccount>('وضعیت', (context, user) => StatusBadge.active(user.isActive)),
                  TableColumn<UserAccount>(
                    'آخرین ورود',
                    (context, user) =>
                        Text(user.lastLoginAt == null ? 'هنوز وارد نشده' : formatDateTime(user.lastLoginAt)),
                  ),
                ],
                actions: !canUpdate && !canReset
                    ? null
                    : (context, user) => [
                        // The accounts of administrators are managed on the server, never through the app.
                        if (canReset && !user.isAdmin)
                          IconButton(
                            tooltip: 'بازنشانی رمز ${user.fullName}',
                            icon: const Icon(Icons.key_outlined, size: 20),
                            onPressed: () =>
                                _openForm(_PasswordDialog(user: user, settings: auth.settings), reloads: false),
                          ),
                        if (canUpdate && !user.isAdmin)
                          IconButton(
                            tooltip: 'ویرایش ${user.fullName}',
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            onPressed: () => _openForm(
                              _UserDialog(
                                user: user,
                                companies: _companies,
                                loadCompanies: _loadCompanies,
                                initialCompanyId: null,
                              ),
                            ),
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

class _UserDialog extends ConsumerStatefulWidget {
  const _UserDialog({
    required this.user,
    required this.companies,
    required this.loadCompanies,
    required this.initialCompanyId,
  });

  /// The employee to edit, or `null` for a new one.
  final UserAccount? user;

  /// The companies to choose from when the page has them already; otherwise [loadCompanies] gets them.
  final List<Company>? companies;
  final Future<List<Company>> Function() loadCompanies;

  /// The company a new employee is to belong to unless the user chooses another one.
  final String? initialCompanyId;

  @override
  ConsumerState<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends ConsumerState<_UserDialog> with FormSupport<_UserDialog> {
  late final TextEditingController _fullName = TextEditingController(text: widget.user?.fullName ?? '');
  late final TextEditingController _username = TextEditingController(text: widget.user?.username ?? '');
  final TextEditingController _password = TextEditingController();
  late String _accountRole = widget.user?.role ?? 'EMPLOYEE';
  late String? _companyId = widget.user?.companyId ?? widget.initialCompanyId;
  late bool _isActive = widget.user?.isActive ?? true;

  late List<Company>? _companies = widget.companies;
  Object? _loadError;

  @override
  Set<String> get fieldNames => const {'full_name', 'username', 'company_id', 'password'};

  @override
  void initState() {
    super.initState();
    if (widget.companies == null) _load();
  }

  Future<void> _load() async {
    try {
      final companies = await widget.loadCompanies();
      if (!mounted) return;
      setState(() {
        _companies = companies;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  void _retry() {
    setState(() => _loadError = null);
    _load();
  }

  @override
  void dispose() {
    _fullName.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Whoever creates an account says whether it starts active; later only some users may change that.
  bool _maySetActive(AuthSession? auth) => widget.user == null || (auth?.can('user:set_active') ?? false);

  Future<void> _submit() async {
    final user = widget.user;
    final fullName = _fullName.text.trim();
    final username = _username.text.trim();
    final companyId = _companyId;
    // A password is taken as typed: spaces at its ends belong to it.
    final password = _password.text;
    final payload = <String, dynamic>{
      'full_name': fullName,
      'username': username,
      if (_accountRole == 'CUSTOMER') 'company_id': companyId,
      if (user == null) 'role': _accountRole,
      if (_maySetActive(ref.read(authProvider))) 'is_active': _isActive,
      if (user == null) 'password': password,
    };
    final api = ref.read(apiProvider);
    String? message;
    final done = await runForm(
      problems: requiredProblems(
        {'full_name': fullName, 'username': username, 'company_id': companyId, 'password': password},
        {
          'full_name': 'نام را وارد کنید.',
          'username': 'نام کاربری را وارد کنید.',
          if (_accountRole == 'CUSTOMER') 'company_id': 'شرکت را انتخاب کنید.',
          if (user == null) 'password': 'رمز عبور را وارد کنید.',
        },
      ),
      () async {
        final result = user == null ? await api.createUser(payload) : await api.updateUser(user.id, payload);
        message = result.message;
      },
    );
    if (!done) return;
    if (!mounted) return;
    Navigator.of(context).pop(message ?? '');
  }

  /// The dialog while there is nothing to fill in: the companies are on their way, or there are none.
  Widget _waiting(String title, Widget content, {List<Widget> actions = const <Widget>[]}) {
    return DialogFrame(
      title: title,
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('انصراف')),
        ...actions,
      ],
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final auth = ref.watch(authProvider);
    final title = user == null ? 'کارمند جدید' : 'ویرایش ${user.fullName}';
    final companies = _companies;
    final loadError = _loadError;
    if (loadError != null) return _waiting(title, ErrorBlock(error: loadError, onRetry: _retry));
    if (companies == null) return _waiting(title, const LoadingBlock(text: 'در حال دریافت فهرست شرکت‌ها…'));
    return FormDialog(
      title: title,
      submitLabel: user == null ? 'ایجاد کارمند' : 'ذخیرهٔ تغییرات',
      busy: busy,
      error: formError,
      onSubmit: _submit,
      children: [
        AppTextField(
          label: 'نام و نام خانوادگی',
          controller: _fullName,
          isRequired: true,
          maxLength: 200,
          autofocus: user == null,
          enabled: !busy,
          error: errors['full_name'],
        ),
        AppTextField(
          label: 'نام کاربری',
          controller: _username,
          isRequired: true,
          ltr: true,
          maxLength: 100,
          enabled: !busy,
          error: errors['username'],
          hint: 'حروف انگلیسی، رقم، نقطه، خط تیره و زیرخط؛ دست‌کم ۳ نویسه.',
        ),
        ChoiceField<String>(label: 'نوع حساب', value: _accountRole,
          enabled: !busy && user == null,
          options: const [('EMPLOYEE', 'کارمند مشترک'), ('CUSTOMER', 'حساب شرکت')],
          onChanged: (value) => setState(() => _accountRole = value ?? 'EMPLOYEE')),
        if (_accountRole == 'CUSTOMER') ChoiceField<String>(
          label: 'شرکت',
          isRequired: true,
          value: _companyId,
          enabled: !busy,
          error: errors['company_id'],
          options: companyOptions(companies, placeholder: 'انتخاب کنید'),
          onChanged: (value) => setState(() => _companyId = value),
        ),
        if (user == null)
          PasswordField(
            label: 'رمز عبور اولیه',
            controller: _password,
            isNew: true,
            enabled: !busy,
            error: errors['password'],
            hint: auth == null ? null : _passwordHint(auth.settings),
          ),
        if (_maySetActive(auth))
          CheckField(
            label: 'حساب کاربری فعال است',
            value: _isActive,
            enabled: !busy,
            hint: 'با غیرفعال شدن حساب، همهٔ نشست‌های کاربر بسته می‌شود.',
            onChanged: (value) => setState(() => _isActive = value),
          ),
      ],
    );
  }
}

class _PasswordDialog extends ConsumerStatefulWidget {
  const _PasswordDialog({required this.user, required this.settings});

  final UserAccount user;
  final ClientSettings settings;

  @override
  ConsumerState<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends ConsumerState<_PasswordDialog> with FormSupport<_PasswordDialog> {
  final TextEditingController _password = TextEditingController();

  @override
  Set<String> get fieldNames => const {'new_password'};

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;
    final api = ref.read(apiProvider);
    String? message;
    final done = await runForm(
      problems: requiredProblems({'new_password': password}, const {'new_password': 'رمز عبور جدید را وارد کنید.'}),
      () async {
        message = await api.resetPassword(widget.user.id, password);
      },
    );
    if (!done) return;
    if (!mounted) return;
    Navigator.of(context).pop(message ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog(
      title: 'بازنشانی رمز عبور',
      submitLabel: 'تغییر رمز عبور',
      submitIcon: Icons.key_outlined,
      busy: busy,
      error: formError,
      onSubmit: _submit,
      children: [
        Notice(
          'با تغییر رمز، همهٔ نشست‌های فعال «${widget.user.fullName}» بسته می‌شود و باید با رمز جدید وارد شود.',
          tone: Tone.warning,
        ),
        PasswordField(
          label: 'رمز عبور جدید',
          controller: _password,
          isNew: true,
          enabled: !busy,
          error: errors['new_password'],
          hint: _passwordHint(widget.settings),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
      ],
    );
  }
}
