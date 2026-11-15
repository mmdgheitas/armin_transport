/// New transport-only frontend. Previous management screens remain in source.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/providers.dart';
import '../../theme.dart';

const _countries = ['CI', 'KZ', 'UZ'];

class TransportPage extends ConsumerStatefulWidget {
  const TransportPage({super.key, required this.view, this.companyId, this.shipmentId});
  final String view;
  final String? companyId;
  final String? shipmentId;

  @override
  ConsumerState<TransportPage> createState() => _TransportPageState();
}

class _TransportPageState extends ConsumerState<TransportPage> {
  final _search = TextEditingController();
  Json _data = {};
  List<Json> _items = [];
  List<Json> _companies = [];
  String? _country;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _deleted = false;
  int _page = 1;
  bool _more = false;
  final Map<String, Future<DownloadedFile>> _previews = {};
  bool get _admin => ref.read(authProvider)?.user.role == 'SUPER_ADMIN';
  ApiClient get _api => ref.read(apiClientProvider);
  bool get _companyList => widget.view == 'companies' || widget.view == 'transport';
  bool get _home => widget.view == 'home' && _admin;

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _search.dispose(); super.dispose(); }

  Future<List<Json>> _all(String path) async {
    final result = <Json>[];
    for (var page = 1; ; page++) {
      final response = await _api.get(path, query: {'page': page, 'per_page': 20});
      final data = response.json;
      result.addAll(asJsonList(data['items']));
      if (asJson(data['pagination'])['has_next'] != true) return result;
    }
  }

  Future<void> _load({bool more = false}) async {
    setState(() { _loading = true; _error = null; });
    try {
      if (_home) { if (mounted) setState(() => _loading = false); return; }
      if (widget.view == 'detail') {
        final response = await _api.get('/transport/shipments/${widget.shipmentId}');
        if (!mounted) return;
        setState(() { _data = response.json; _loading = false; });
        return;
      }
      final path = _companyList ? '/transport/companies' : widget.view == 'employees' ? '/transport/employees' : '/transport/shipments';
      final page = more ? _page + 1 : 1;
      final response = await _api.get(path, query: {'page': page, 'q': _search.text, if (_admin) 'deleted': _deleted, if (widget.companyId != null) 'company_id': widget.companyId});
      final companies = widget.companyId != null && _admin ? [(await _api.get('/transport/companies/${widget.companyId}')).json] : <Json>[];
      if (!mounted) return;
      setState(() {
        _items = [...(more ? _items : <Json>[]), ...asJsonList(response.json['items'])];
        _companies = companies;
        _page = page; _more = asJson(response.json['pagination'])['has_next'] == true; _loading = false;
      });
    } catch (error) { if (mounted) setState(() { _error = error.toString(); _loading = false; }); }
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try { await action(); }
    catch (error) { if (mounted) setState(() => _error = error.toString()); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<Json?> _form(String kind, {Json? initial}) async {
    final activeEmployees = kind == 'shipment' ? await _all('/transport/employees') : <Json>[];
    final employees = [...activeEmployees, ...asJsonList(initial?['employees']).where((employee) => !activeEmployees.any((item) => item['id'] == employee['id']))];
    if (!mounted) return null;
    final minPassword = ref.read(authProvider)?.settings.passwordMinLength ?? 10;
    final labels = switch (kind) {
      'company' => {'name': 'اسم شرکت'},
      'account' => {'username': 'یوزرنیم شرکت', 'password': 'پسورد شرکت'},
      'employee' => {'full_name': 'اسم کامل', 'username': 'یوزرنیم', 'password': 'پسورد'},
      'code' => {'tracking_code': 'کد دستی و یکتای بار'},
      'file' => {'original_name': 'نام فایل'},
      _ => {'tracking_code': 'کد دستی و یکتای بار', 'upload_limit': 'تعداد فایل برای هر کارمند', 'truck_count': 'تعداد کامیون', 'border_count': 'تعداد مرز'},
    };
    final controls = {for (final key in labels.keys) key: TextEditingController(text: initial?[key]?.toString() ?? '')};
    final countries = <String>{...((initial?['countries'] as List?) ?? []).whereType<String>()};
    final assigned = <String>{for (final employee in asJsonList(initial?['employees'])) employee['id'] as String};
    String? employeeCountry = initial?['country'] as String?;
    final formKey = GlobalKey<FormState>();
    String? localError;
    final result = await showDialog<Json>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, update) => AlertDialog(
      title: Text(switch (kind) { 'company' => 'ثبت شرکت', 'account' => 'حساب ورود شرکت', 'employee' => 'تعریف کارمند', 'code' => 'ویرایش کد', _ => 'تعریف محموله' }),
      content: SizedBox(width: 560, child: SingleChildScrollView(child: Form(key: formKey, child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final entry in labels.entries) Padding(padding: const EdgeInsets.only(bottom: 16), child: TextFormField(
          controller: controls[entry.key], obscureText: entry.key == 'password',
          maxLines: entry.key == 'tracking_code' ? null : 1,
          keyboardType: entry.key.endsWith('count') || entry.key == 'upload_limit' ? TextInputType.number : TextInputType.text,
          maxLength: entry.key == 'password' ? 128 : entry.key == 'username' ? 100 : (entry.key == 'name' || entry.key == 'full_name') ? 200 : entry.key == 'original_name' ? 255 : null,
          decoration: InputDecoration(labelText: entry.value, helperText: entry.key == 'password' ? '$minPassword تا ۱۲۸ نویسه؛ نباید شامل یوزرنیم باشد.${initial != null ? ' خالی یعنی بدون تغییر' : ''}' : entry.key == 'username' ? '۳ تا ۱۰۰ نویسه؛ حروف انگلیسی، رقم، نقطه، خط تیره و زیرخط' : (entry.key == 'name' || entry.key == 'full_name') ? '۱ تا ۲۰۰ نویسه' : entry.key == 'tracking_code' ? 'بدون سقف طول؛ حروف و فاصله‌ها عیناً ذخیره می‌شوند.' : null, helperMaxLines: 3),
          validator: (value) {
            if (entry.key == 'password' && initial != null && (value == null || value.isEmpty)) return null;
            if (value == null || value.isEmpty) return 'این فیلد الزامی است.';
            if (entry.key == 'password' && value.length < minPassword) return 'حداقل $minPassword نویسه وارد کنید.';
            if (entry.key == 'username' && !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{2,99}$').hasMatch(value)) return 'یوزرنیم باید ۳ تا ۱۰۰ نویسه با حروف مجاز باشد.';
            if (entry.key.endsWith('count') || entry.key == 'upload_limit') {
              final number = int.tryParse(value);
              if (number == null || number < (entry.key == 'border_count' ? 0 : 1)) return 'تعداد صحیح وارد کنید.';
            }
            return null;
          },
        )),
        if (kind == 'employee') DropdownButtonFormField<String>(initialValue: employeeCountry,
          decoration: const InputDecoration(labelText: 'کشور'), items: [for (final value in _countries) DropdownMenuItem(value: value, child: Text(value))],
          onChanged: (value) => employeeCountry = value, validator: (value) => value == null ? 'کشور را انتخاب کنید.' : null),
        if (kind == 'shipment') ...[
          Wrap(spacing: 12, children: [for (final country in _countries) FilterChip(label: Text(country), selected: countries.contains(country), onSelected: (selected) => update(() {
            if (selected) { countries.add(country); } else { countries.remove(country); assigned.removeWhere((id) => employees.any((employee) => employee['id'] == id && employee['country'] == country)); }
          }))]),
          const SizedBox(height: 16), const Text('تخصیص کارمند'),
          for (final employee in employees) CheckboxListTile(title: Text('${employee['full_name']} · ${employee['country']}'), value: assigned.contains(employee['id']),
            onChanged: !countries.contains(employee['country']) ? null : (value) => update(() { if (value == true) { assigned.add(employee['id'] as String); } else { assigned.remove(employee['id']); } })),
        ],
        if (localError != null) Text(localError!),
      ])))),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('انصراف')),
        FilledButton(onPressed: () {
          if (!formKey.currentState!.validate()) return;
          if (kind == 'shipment' && countries.isEmpty) { update(() => localError = 'حداقل یک کشور انتخاب کنید.'); return; }
          final payload = <String, dynamic>{for (final entry in controls.entries) entry.key: entry.key.endsWith('count') || entry.key == 'upload_limit' ? int.parse(entry.value.text) : entry.value.text,
            if (kind == 'employee') 'country': employeeCountry,
            if (kind == 'shipment') ...{'company_id': initial?['company_id'] ?? widget.companyId, 'countries': countries.toList(), 'employee_ids': assigned.toList()}};
          if (initial != null && payload['password'] == '') payload.remove('password');
          Navigator.pop(dialogContext, payload);
        }, child: const Text('ثبت'))],
    )));
    // Wait until the dialog transition no longer uses the controllers.
    Future<void>.delayed(const Duration(seconds: 1), () { for (final controller in controls.values) { controller.dispose(); } });
    return result;
  }

  Future<void> _create(String kind) async => _perform(() async {
    final payload = await _form(kind);
    if (payload == null) return;
    final path = switch (kind) { 'company' => '/transport/companies', 'employee' => '/transport/employees', 'account' => '/transport/companies/${widget.companyId}/account', _ => '/transport/shipments' };
    await _api.post(path, json: payload);
    await _load();
  });


  Future<void> _edit(String kind, Json item, String path) async => _perform(() async {
    final payload = await _form(kind, initial: item);
    if (payload == null) return;
    await _api.patch(path, json: payload);
    _previews.clear();
    await _load();
  });

  Future<void> _change(String label, String path, {bool restore = false, String? back}) async => _perform(() async {
    final confirmed = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
      title: Text(label), content: Text(restore ? 'بازیابی انجام شود؟' : 'حذف نرم انجام شود؟ اطلاعات و فایل‌ها باقی می‌مانند و ادمین می‌تواند بازیابی کند.'),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('انصراف')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(label))],
    ));
    if (confirmed != true) return;
    if (restore) { await _api.post(path); } else { await _api.delete(path); }
    _previews.clear();
    if (back != null) { if (mounted) context.go(back); } else { await _load(); }
  });

  Future<void> _replace(Json file) async => _perform(() async {
    final gateway = ref.read(fileGatewayProvider);
    final picked = await gateway.pickFiles(dialogTitle: 'انتخاب یک فایل جایگزین');
    if (picked.isEmpty) return;
    try {
      if (picked.length != 1) throw StateError('دقیقاً یک فایل انتخاب کنید.');
      final selected = picked.single;
      await _api.upload('/transport/files/${file['id']}/replace', files: [UploadPart(filename: selected.name, bytes: await selected.readBytes())], fields: const {});
      _previews.remove(file['id']);
      await _load();
    } finally { await gateway.discardTemporaryFiles(); }
  });

  Widget _accountActions(Json company) {
    final path = '/transport/companies/${company['id']}/account';
    if (company['account_deleted'] == true) return OutlinedButton(onPressed: _busy ? null : () => _change('بازیابی حساب', '$path/restore', restore: true), child: const Text('بازیابی حساب شرکت'));
    return Wrap(spacing: 8, children: [
      Text('حساب شرکت: ${company['account_username']}'),
      OutlinedButton(onPressed: _busy ? null : () => _edit('account', {'username': company['account_username']}, path), child: const Text('ویرایش حساب / پسورد')),
      OutlinedButton(onPressed: _busy ? null : () => _change('حذف حساب شرکت', path), child: const Text('حذف حساب شرکت')),
    ]);
  }

  Widget _itemActions(Json item) {
    final kind = _companyList ? 'company' : widget.view == 'employees' ? 'employee' : 'shipment';
    final path = '/transport/${_companyList ? 'companies' : widget.view == 'employees' ? 'employees' : 'shipments'}/${item['id']}';
    if (item['deleted_at'] != null) return OutlinedButton(onPressed: _busy ? null : () => _change('بازیابی', '$path/restore', restore: true), child: const Text('بازیابی'));
    return Wrap(spacing: 8, children: [
      OutlinedButton(onPressed: _busy ? null : () async {
        if (kind == 'shipment') {
          await _perform(() async {
            final detail = (await _api.get(path)).json;
            final payload = await _form('shipment', initial: detail);
            if (payload != null) { await _api.patch(path, json: payload); await _load(); }
          });
        } else { await _edit(kind, item, path); }
      }, child: const Text('ویرایش')),
      OutlinedButton(onPressed: _busy ? null : () => _change('حذف', path), child: const Text('حذف')),
    ]);
  }

  Future<DownloadedFile> _file(Json file) => _previews.putIfAbsent(file['id'] as String, () => _api.download('/documents/${file['id']}/download'));

  Future<void> _download(Json file) async => _perform(() async {
    final result = await _file(file);
    await ref.read(fileGatewayProvider).saveFile(name: file['original_name'] as String, bytes: result.bytes, mimeType: result.contentType);
  });

  Future<void> _upload(String country) async => _perform(() async {
    final gateway = ref.read(fileGatewayProvider);
    final picked = await gateway.pickFiles(dialogTitle: 'انتخاب فایل');
    if (picked.isEmpty) return;
    try {
      final parts = <UploadPart>[for (final file in picked) UploadPart(filename: file.name, bytes: await file.readBytes())];
      await _api.upload('/transport/shipments/${widget.shipmentId}/files', files: parts, fields: {'country': country});
      await _load();
    } finally { await gateway.discardTemporaryFiles(); }
  });

  Widget _gallery() {
    final employee = ref.read(authProvider)?.user.role == 'EMPLOYEE';
    final ownCountry = ref.read(authProvider)?.user.country;
    final active = (_data['countries'] as List? ?? []).whereType<String>().where((value) => !employee || value == ownCountry).toList();
    final selected = active.contains(_country) ? _country : active.firstOrNull;
    final groups = asJsonList(_data['groups']).where((group) => group['country'] == selected);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_data['company_name']?.toString() ?? '', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      SelectableText(_data['tracking_code']?.toString() ?? '', style: const TextStyle(fontSize: 22)),
      Text('${_data['truck_count']} کامیون · ${_data['border_count']} مرز'),
      if (_admin) Align(alignment: AlignmentDirectional.centerEnd, child: OutlinedButton(onPressed: _busy ? null : () => _perform(() async {
        final payload = await _form('code', initial: _data); if (payload == null) return;
        await _api.patch('/transport/shipments/${widget.shipmentId}/code', json: payload); await _load();
      }), child: const Text('ویرایش کد'))),
      if (_admin) Wrap(spacing: 8, children: [
        FilledButton(onPressed: _busy ? null : () => _edit('shipment', _data, '/transport/shipments/${widget.shipmentId}'), child: const Text('ویرایش بار / تخصیص‌ها')),
        OutlinedButton(onPressed: _busy ? null : () => _change('حذف بار', '/transport/shipments/${widget.shipmentId}', back: '/companies/${_data['company_id']}'), child: const Text('حذف بار')),
      ]),
      const SizedBox(height: 20),
      Row(children: [for (final country in active) Expanded(child: Padding(padding: const EdgeInsets.all(4), child: country == selected
        ? FilledButton(onPressed: () => setState(() => _country = country), child: Text(country))
        : OutlinedButton(onPressed: () => setState(() => _country = country), child: Text(country))))]),
      for (final group in groups) ...[
        const SizedBox(height: 28), Text('${group['full_name']} : ${asJsonList(group['files']).length} فایل', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text('ظرفیت: ${group['limit']} فایل'), const SizedBox(height: 16),
        LayoutBuilder(builder: (context, constraints) {
          final files = asJsonList(group['files']);
          final count = (group['limit'] as int?) ?? 0;
          return GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: files.length > count ? files.length : count,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: constraints.maxWidth < 500 ? 2 : (constraints.maxWidth / 175).floor(), crossAxisSpacing: 14, mainAxisSpacing: 14),
            itemBuilder: (context, index) {
              if (index >= files.length) return FilledButton(onPressed: group['can_upload'] == true && !_busy ? () => _upload(selected!) : null,
                style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.add, size: 32), Text(group['can_upload'] == true ? 'آپلود فایل' : 'بدون فایل')]));
              final file = files[index];
              final image = RegExp(r'\.(png|jpe?g|webp|gif|bmp)$', caseSensitive: false).hasMatch(file['original_name'] as String);
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _download(file), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (image) Expanded(child: FutureBuilder<DownloadedFile>(future: _file(file), builder: (context, snapshot) => snapshot.hasData
                    ? Image.memory(snapshot.data!.bytes, fit: BoxFit.contain, errorBuilder: (context, error, stack) => const Icon(Icons.description))
                    : const Icon(Icons.image_outlined))) else const Icon(Icons.description_outlined, size: 34),
                Text(file['original_name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis), const Text('دانلود'),
              ]))), if (group['can_manage'] == true) PopupMenuButton<String>(enabled: !_busy, tooltip: 'مدیریت فایل', onSelected: (value) {
                if (value == 'rename') { _edit('file', file, '/transport/files/${file['id']}'); }
                if (value == 'replace') { _replace(file); }
                if (value == 'delete') { _change('حذف فایل', '/transport/files/${file['id']}'); }
              }, itemBuilder: (context) => const [PopupMenuItem(value: 'rename', child: Text('تغییر نام')), PopupMenuItem(value: 'replace', child: Text('جایگزینی فایل')), PopupMenuItem(value: 'delete', child: Text('حذف فایل'))]),
              ]);
            });
        }), const SizedBox(height: 24), const Divider(thickness: 2),
      ],
      if (_admin) ...[const Text('فایل‌های حذف‌شده', style: TextStyle(fontSize: 20)),
        for (final file in asJsonList(_data['deleted_files'])) ListTile(title: Text(file['original_name'] as String), trailing: OutlinedButton(onPressed: _busy ? null : () => _change('بازیابی فایل', '/transport/files/${file['id']}/restore', restore: true), child: const Text('بازیابی')))],
      if (groups.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('هنوز فایلی ثبت نشده است.')),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final company = _companies.where((item) => item['id'] == widget.companyId).firstOrNull;
    return SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_error != null) Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [Text(_error!), TextButton(onPressed: () => _load(), child: const Text('تلاش مجدد'))]))),
      if (_loading) const LinearProgressIndicator(),
      if (_home) ...[
        const SizedBox(height: 30), Container(padding: const EdgeInsets.all(36), color: AppColors.primary, child: const Text('کنترل ترانسپورت', style: TextStyle(color: Colors.white, fontSize: 32))),
        const SizedBox(height: 36), LayoutBuilder(builder: (context, constraints) => GridView.count(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: constraints.maxWidth < 800 ? 2 : 5, crossAxisSpacing: 20, mainAxisSpacing: 20,
          children: [FilledButton(onPressed: () => context.go('/transport'), child: const Text('ترانسپورت کنترل')),
            for (var index = 0; index < 4; index++) Semantics(label: 'بخش خالی ${index + 1}', child: Container(decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(12))))])),
      ] else if (widget.view == 'detail') _gallery() else ...[
        Row(children: [Expanded(child: Text(_companyList ? 'لیست شرکت‌ها' : widget.view == 'employees' ? 'مدیریت کارمند' : company?['name']?.toString() ?? 'بارهای من', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
          if (_admin && widget.view == 'companies') FilledButton(onPressed: _busy ? null : () => _create('company'), child: const Text('ثبت شرکت')),
          if (_admin && widget.view == 'employees') FilledButton(onPressed: _busy ? null : () => _create('employee'), child: const Text('تعریف کارمند')),
        ]),
        if (_admin && widget.companyId != null) Wrap(spacing: 12, children: [FilledButton(onPressed: _busy ? null : () => _create('shipment'), child: const Text('تعریف محموله')),
          company?['account_username'] == null ? OutlinedButton(onPressed: _busy ? null : () => _create('account'), child: const Text('تعریف حساب شرکت')) : _accountActions(company!)]),
        if (_admin) Align(alignment: AlignmentDirectional.centerStart, child: OutlinedButton(onPressed: _loading ? null : () { setState(() => _deleted = !_deleted); _load(); }, child: Text(_deleted ? 'نمایش فعال‌ها' : 'حذف‌شده‌ها / بازیابی'))),
        const SizedBox(height: 20), Row(children: [Expanded(child: TextField(controller: _search, decoration: const InputDecoration(labelText: 'جست‌وجو'), onSubmitted: (_) => _load())),
          const SizedBox(width: 12), FilledButton(onPressed: () => _load(), child: const Text('جست‌وجو'))]),
        const SizedBox(height: 24),
        for (final item in _items) Padding(padding: const EdgeInsets.only(bottom: 16), child: Card(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [ListTile(
          contentPadding: const EdgeInsets.all(20),
          title: Text(_companyList ? item['name'] as String : widget.view == 'employees' ? item['full_name'] as String : item['tracking_code'] as String),
          subtitle: Text(_companyList ? 'مشاهدهٔ بارها' : widget.view == 'employees' ? '${item['username']} · ${item['country']}' : '${item['company_name']} · ${(item['countries'] as List).join(' / ')}'),
          onTap: widget.view == 'employees' || item['deleted_at'] != null ? null : () => context.go(_companyList ? '/companies/${item['id']}' : '/loads/${item['id']}'),
          trailing: widget.view == 'employees' ? null : const Icon(Icons.arrow_back),
        ), if (_admin) Padding(padding: const EdgeInsets.all(12), child: _itemActions(item)),
        ]))),
        if (_items.isEmpty && !_loading) const Text('موردی برای نمایش وجود ندارد.'),
        if (_more) OutlinedButton(onPressed: _loading ? null : () => _load(more: true), child: const Text('موارد بیشتر')),
      ],
    ]));
  }
}
