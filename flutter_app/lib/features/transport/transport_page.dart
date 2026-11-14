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
      final response = await _api.get(path, query: {'page': page, 'q': _search.text, if (widget.companyId != null) 'company_id': widget.companyId});
      final companies = widget.companyId != null && _admin ? await _all('/transport/companies') : <Json>[];
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
    final employees = kind == 'shipment' ? await _all('/transport/employees') : <Json>[];
    if (!mounted) return null;
    final labels = switch (kind) {
      'company' => {'name': 'اسم شرکت'},
      'account' => {'username': 'یوزرنیم شرکت', 'password': 'پسورد شرکت'},
      'employee' => {'full_name': 'اسم کامل', 'username': 'یوزرنیم', 'password': 'پسورد'},
      'code' => {'tracking_code': 'کد دستی و یکتای بار'},
      _ => {'tracking_code': 'کد دستی و یکتای بار', 'upload_limit': 'تعداد فایل برای هر کارمند', 'truck_count': 'تعداد کامیون', 'border_count': 'تعداد مرز'},
    };
    final controls = {for (final key in labels.keys) key: TextEditingController(text: initial?[key]?.toString() ?? '')};
    final countries = <String>{};
    final assigned = <String>{};
    String? employeeCountry;
    final formKey = GlobalKey<FormState>();
    String? localError;
    final result = await showDialog<Json>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, update) => AlertDialog(
      title: Text(switch (kind) { 'company' => 'ثبت شرکت', 'account' => 'حساب ورود شرکت', 'employee' => 'تعریف کارمند', 'code' => 'ویرایش کد', _ => 'تعریف محموله' }),
      content: SizedBox(width: 560, child: SingleChildScrollView(child: Form(key: formKey, child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final entry in labels.entries) Padding(padding: const EdgeInsets.only(bottom: 16), child: TextFormField(
          controller: controls[entry.key], obscureText: entry.key == 'password',
          maxLines: entry.key == 'tracking_code' ? null : 1,
          keyboardType: entry.key.endsWith('count') || entry.key == 'upload_limit' ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(labelText: entry.value),
          validator: (value) {
            if (value == null || value.isEmpty) return 'این فیلد الزامی است.';
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
            if (kind == 'shipment') ...{'company_id': widget.companyId, 'countries': countries.toList(), 'employee_ids': assigned.toList()}};
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
              return OutlinedButton(onPressed: _busy ? null : () => _download(file), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (image) Expanded(child: FutureBuilder<DownloadedFile>(future: _file(file), builder: (context, snapshot) => snapshot.hasData
                    ? Image.memory(snapshot.data!.bytes, fit: BoxFit.contain, errorBuilder: (context, error, stack) => const Icon(Icons.description))
                    : const Icon(Icons.image_outlined))) else const Icon(Icons.description_outlined, size: 34),
                Text(file['original_name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis), const Text('دانلود'),
              ]));
            });
        }), const SizedBox(height: 24), const Divider(thickness: 2),
      ],
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
          company?['account_username'] == null ? OutlinedButton(onPressed: _busy ? null : () => _create('account'), child: const Text('تعریف حساب شرکت')) : Text('حساب شرکت: ${company?['account_username']}')]),
        const SizedBox(height: 20), Row(children: [Expanded(child: TextField(controller: _search, decoration: const InputDecoration(labelText: 'جست‌وجو'), onSubmitted: (_) => _load())),
          const SizedBox(width: 12), FilledButton(onPressed: () => _load(), child: const Text('جست‌وجو'))]),
        const SizedBox(height: 24),
        for (final item in _items) Padding(padding: const EdgeInsets.only(bottom: 16), child: Card(child: ListTile(
          contentPadding: const EdgeInsets.all(20),
          title: Text(_companyList ? item['name'] as String : widget.view == 'employees' ? item['full_name'] as String : item['tracking_code'] as String),
          subtitle: Text(_companyList ? 'مشاهدهٔ بارها' : widget.view == 'employees' ? '${item['username']} · ${item['country']}' : '${item['company_name']} · ${(item['countries'] as List).join(' / ')}'),
          onTap: widget.view == 'employees' ? null : () => context.go(_companyList ? '/companies/${item['id']}' : '/loads/${item['id']}'),
          trailing: widget.view == 'employees' ? null : const Icon(Icons.arrow_back),
        ))),
        if (_items.isEmpty && !_loading) const Text('موردی برای نمایش وجود ندارد.'),
        if (_more) OutlinedButton(onPressed: _loading ? null : () => _load(more: true), child: const Text('موارد بیشتر')),
      ],
    ]));
  }
}
