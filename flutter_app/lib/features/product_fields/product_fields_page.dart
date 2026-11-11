/// The definitions of the goods fields: what is recorded for every shipment besides its description.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/models.dart';
import '../../core/format.dart';
import '../../core/product_fields.dart';
import '../../core/providers.dart';
import '../../theme.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/feedback.dart';
import '../../widgets/fields.dart';
import '../../widgets/form_layout.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';

/// The filters in effect. Records compare by value, so the table loads again exactly when one of them changes.
typedef _Filters = ({String search, bool onlyActive});

const _Filters _noFilters = (search: '', onlyActive: false);

final RegExp _fieldKeyPattern = RegExp(r'^[a-z][a-z0-9_]{1,99}$');
final RegExp _orderPattern = RegExp(r'^\d{1,6}$');
const int _maxOrder = 100000;

const String _patternHint =
    'مقدار باید به‌طور کامل با الگو منطبق باشد. تکرار تودرتو، انتخاب (|) درون تکرار و ارجاع به گروه پذیرفته نمی‌شود.';

bool _hasOptions(String dataType) => dataType == 'SELECT' || dataType == 'MULTI_SELECT';

class ProductFieldsPage extends ConsumerStatefulWidget {
  const ProductFieldsPage({super.key});

  @override
  ConsumerState<ProductFieldsPage> createState() => _ProductFieldsPageState();
}

class _ProductFieldsPageState extends ConsumerState<ProductFieldsPage> {
  final GlobalKey<PagedTableState<ProductField>> _table = GlobalKey<PagedTableState<ProductField>>();
  final TextEditingController _search = TextEditingController();
  bool _onlyActive = false;
  _Filters _applied = _noFilters;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _apply() => setState(() => _applied = (search: _search.text.trim(), onlyActive: _onlyActive));

  void _clear() {
    setState(() {
      _search.clear();
      _onlyActive = false;
      _applied = _noFilters;
    });
  }

  void _reload() {
    _table.currentState?.reload();
  }

  /// Opens the form for [field], or for a new field when it is `null`.
  /// The form closes with the message of the server once the change is made.
  Future<void> _edit(ProductField? field) async {
    final message = await showFormDialog<String>(context, (context) => _FieldDialog(field: field));
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
    final applied = _applied;
    final hasFilters = applied.search.isNotEmpty || applied.onlyActive;

    return PageBody(
      children: [
        PageHeader(
          title: 'فیلدهای محموله',
          description: 'مشخصات دلخواهی که برای هر محموله ثبت می‌شود. این تعریف‌ها بین همهٔ شرکت‌ها مشترک است.',
          actions: [
            FilledButton.icon(
              onPressed: () => _edit(null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('فیلد جدید'),
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
                    placeholder: 'برچسب یا کلید فیلد',
                    maxLength: 100,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _apply(),
                  ),
                  ChoiceField<bool>(
                    label: 'وضعیت',
                    value: _onlyActive,
                    options: const [(false, 'همهٔ فیلدها'), (true, 'فقط فعال')],
                    onChanged: (value) => setState(() => _onlyActive = value ?? false),
                  ),
                ],
              ),
              PagedTable<ProductField>(
                key: _table,
                filters: applied,
                load: (page) => api.productFields(
                  page: page,
                  search: applied.search.isEmpty ? null : applied.search,
                  includeInactive: !applied.onlyActive,
                ),
                emptyIcon: Icons.tune,
                emptyTitle: hasFilters ? 'فیلدی با این مشخصات پیدا نشد.' : 'هنوز فیلدی تعریف نشده است.',
                emptyText: hasFilters
                    ? null
                    : 'با تعریف فیلد، مشخصاتی مانند وزن، تعداد یا نوع بسته‌بندی به فرم محموله‌ها افزوده می‌شود.',
                columns: [
                  TableColumn<ProductField>('ترتیب', (context, field) => Text(formatNumber(field.displayOrder))),
                  TableColumn<ProductField>('برچسب', (context, field) => _LabelCell(field)),
                  TableColumn<ProductField>('کلید', (context, field) => LtrText(field.fieldKey)),
                  TableColumn<ProductField>('نوع', (context, field) => Text(_typeText(field))),
                  TableColumn<ProductField>(
                    'الزامی',
                    (context, field) =>
                        field.isRequired ? const StatusBadge('الزامی', tone: Tone.warning) : const Text('اختیاری'),
                  ),
                  TableColumn<ProductField>(
                    'نمایش به مشتری',
                    (context, field) => field.isCustomerVisible
                        ? const StatusBadge('قابل مشاهده', tone: Tone.success)
                        : const StatusBadge('پنهان'),
                  ),
                  TableColumn<ProductField>('وضعیت', (context, field) => StatusBadge.active(field.isActive)),
                ],
                actions: (context, field) => [
                  IconButton(
                    tooltip: 'ویرایش فیلد ${field.label}',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _edit(field),
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

String _typeText(ProductField field) {
  final label = fieldTypeLabels[field.dataType] ?? field.dataType;
  return field.hasOptions ? '$label (${formatNumber(field.options.length)} گزینه)' : label;
}

/// The label of a field with what its rules ask for below it.
class _LabelCell extends StatelessWidget {
  const _LabelCell(this.field);

  final ProductField field;

  @override
  Widget build(BuildContext context) {
    final rules = describeRules(field);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            field.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (rules != null)
            Text(
              rules,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
        ],
      ),
    );
  }
}

/// One row of the option editor.
class _OptionRow {
  _OptionRow(this.id, {String value = '', String label = ''})
    : value = TextEditingController(text: value),
      label = TextEditingController(text: label);

  /// Tells the rows apart when one of them is removed.
  final int id;
  final TextEditingController value;
  final TextEditingController label;

  void dispose() {
    value.dispose();
    label.dispose();
  }
}

class _FieldDialog extends ConsumerStatefulWidget {
  const _FieldDialog({required this.field});

  /// The definition to edit, or `null` for a new one.
  final ProductField? field;

  @override
  ConsumerState<_FieldDialog> createState() => _FieldDialogState();
}

class _FieldDialogState extends ConsumerState<_FieldDialog> with FormSupport<_FieldDialog> {
  late final TextEditingController _label = TextEditingController(text: widget.field?.label ?? '');
  late final TextEditingController _key = TextEditingController(text: widget.field?.fieldKey ?? '');
  late final TextEditingController _order = TextEditingController(text: '${widget.field?.displayOrder ?? 0}');
  late String _type = widget.field?.dataType ?? 'TEXT';
  late bool _isRequired = widget.field?.isRequired ?? false;
  late bool _isCustomerVisible = widget.field?.isCustomerVisible ?? false;
  late bool _isActive = widget.field?.isActive ?? true;

  /// The state of the rule controls of the current type, keyed by the name of the rule.
  late Map<String, FieldInput> _rules = _rulesFor(_type, widget.field?.validationRules);
  Map<String, String> _ruleErrors = const <String, String>{};

  /// Changes with the type, so that the controls of the new type start empty.
  int _rulesVersion = 0;

  final List<_OptionRow> _options = <_OptionRow>[];
  int _nextOptionId = 0;

  @override
  Set<String> get fieldNames =>
      const {'label', 'field_key', 'data_type', 'display_order', 'options', 'validation_rules'};

  /// What the server says about a single option or rule is shown below the list it belongs to.
  @override
  String fieldFor(String name) {
    if (name.startsWith('options.')) return 'options';
    if (name.startsWith('validation_rules.')) return 'validation_rules';
    return name;
  }

  static Map<String, FieldInput> _rulesFor(String type, Map<String, dynamic>? current) => {
    for (final definition in ruleDefinitions[type] ?? const <RuleDefinition>[])
      definition.key: ruleValueToInput(definition.kind, current?[definition.key]),
  };

  @override
  void initState() {
    super.initState();
    for (final option in widget.field?.options ?? const <ProductFieldOption>[]) {
      _options.add(_OptionRow(_nextOptionId++, value: option.value, label: option.label));
    }
    if (_options.isEmpty) _options.add(_OptionRow(_nextOptionId++));
  }

  @override
  void dispose() {
    _label.dispose();
    _key.dispose();
    _order.dispose();
    for (final row in _options) {
      row.dispose();
    }
    super.dispose();
  }

  void _setType(String type) {
    setState(() {
      _type = type;
      _rules = _rulesFor(type, null);
      _ruleErrors = const <String, String>{};
      _rulesVersion += 1;
    });
  }

  void _addOption() => setState(() => _options.add(_OptionRow(_nextOptionId++)));

  void _removeOption(_OptionRow row) {
    setState(() => _options.remove(row));
    // The row is gone from the screen with the next frame; its controllers are let go afterwards.
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  Future<void> _submit() async {
    final field = widget.field;
    final label = _label.text.trim();
    final key = _key.text.trim();
    final orderText = toLatinDigits(_order.text).trim();
    final order = _orderPattern.hasMatch(orderText) ? int.parse(orderText) : null;
    final type = _type;
    final options = buildOptions([for (final row in _options) (value: row.value.text, label: row.label.text)]);
    final rules = buildValidationRules(type, _rules);

    final problems = requiredProblems(
      {'label': label, 'field_key': key},
      const {'label': 'برچسب را وارد کنید.', 'field_key': 'کلید فیلد را وارد کنید.'},
    );
    if (field == null && !problems.containsKey('field_key') && !_fieldKeyPattern.hasMatch(key)) {
      problems['field_key'] =
          'کلید باید با حرف کوچک انگلیسی شروع شود و فقط شامل حروف کوچک، رقم و زیرخط باشد (۲ تا ۱۰۰ نویسه).';
    }
    if (order == null || order > _maxOrder) problems['display_order'] = 'عددی بین ۰ و ۱۰۰٬۰۰۰ وارد کنید.';
    final optionsError = options.error;
    if (_hasOptions(type) && optionsError != null) problems['options'] = optionsError;
    if (rules.errors.isNotEmpty) problems['validation_rules'] = 'قواعد مشخص‌شده را اصلاح کنید.';
    setState(() => _ruleErrors = rules.errors);

    final payload = <String, dynamic>{
      'label': label,
      'is_required': _isRequired,
      'is_customer_visible': _isCustomerVisible,
      'is_active': _isActive,
      'display_order': order,
      'validation_rules': rules.rules,
      'options': _hasOptions(type) ? options.options : null,
      if (field == null) 'field_key': key,
      if (field == null) 'data_type': type,
    };
    final api = ref.read(apiProvider);
    String? message;
    final done = await runForm(problems: problems, () async {
      final result = field == null
          ? await api.createProductField(payload)
          : await api.updateProductField(field.id, payload);
      message = result.message;
    });
    if (!done) return;
    if (!mounted) return;
    Navigator.of(context).pop(message ?? '');
  }

  Widget _heading(String title, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(hint, style: const TextStyle(fontSize: 12, color: AppColors.muted, height: 1.6)),
      ],
    );
  }

  Widget _problem(String message) => Text(message, style: const TextStyle(fontSize: 12, color: AppColors.danger, height: 1.5));

  Widget _optionEditor() {
    final error = errors['options'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _heading(
          'گزینه‌ها',
          '«مقدار» شناسهٔ ثابتی است که ذخیره می‌شود (بهتر است انگلیسی و کوتاه باشد) و «برچسب» متنی است که کاربران می‌بینند.',
        ),
        for (final row in _options)
          Padding(
            key: ValueKey<int>(row.id),
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: row.value,
                    enabled: !busy,
                    textDirection: TextDirection.ltr,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      hintText: 'value',
                      hintTextDirection: TextDirection.ltr,
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: row.label,
                    enabled: !busy,
                    maxLength: 200,
                    decoration: const InputDecoration(hintText: 'برچسب', counterText: ''),
                  ),
                ),
                IconButton(
                  tooltip: 'حذف گزینه',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: busy ? null : () => _removeOption(row),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: busy ? null : _addOption,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('افزودن گزینه'),
          ),
        ),
        if (error != null) ...[const SizedBox(height: 6), _problem(error)],
      ],
    );
  }

  Widget _ruleEditor(List<RuleDefinition> definitions) {
    final error = errors['validation_rules'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _heading('قواعد اعتبارسنجی', 'همهٔ قواعد اختیاری‌اند؛ موارد خالی اعمال نمی‌شوند.'),
        const SizedBox(height: 10),
        FormGrid(
          minColumnWidth: 230,
          children: [
            for (final definition in definitions)
              if (definition.kind == 'text')
                FullRow(child: _rule(definition))
              else
                _rule(definition),
          ],
        ),
        if (error != null) ...[const SizedBox(height: 6), _problem(error)],
      ],
    );
  }

  Widget _rule(RuleDefinition definition) => _RuleControl(
    key: ValueKey<String>('$_rulesVersion-${definition.key}'),
    definition: definition,
    input: _rules[definition.key] ?? FieldInput(),
    error: _ruleErrors[definition.key],
  );

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final isNew = field == null;
    final definitions = ruleDefinitions[_type] ?? const <RuleDefinition>[];
    return FormDialog(
      title: field == null ? 'فیلد جدید' : 'ویرایش فیلد «${field.label}»',
      submitLabel: isNew ? 'تعریف فیلد' : 'ذخیرهٔ تغییرات',
      width: 640,
      busy: busy,
      error: formError,
      onSubmit: _submit,
      children: [
        if (!isNew)
          const Notice(
            'تغییر برچسب، الزامی بودن، قواعد یا گزینه‌ها نسخهٔ فیلد را افزایش می‌دهد و مقادیر ثبت‌شدهٔ قبلی '
            'با نشان «نیازمند بازبینی» مشخص می‌شوند.',
          ),
        FormGrid(
          minColumnWidth: 230,
          children: [
            AppTextField(
              label: 'برچسب',
              controller: _label,
              isRequired: true,
              maxLength: 200,
              autofocus: isNew,
              enabled: !busy,
              error: errors['label'],
              hint: 'عنوانی که در فرم‌ها و برای مشتری نمایش داده می‌شود.',
            ),
            AppTextField(
              label: 'کلید فیلد',
              controller: _key,
              isRequired: true,
              ltr: true,
              maxLength: 100,
              enabled: isNew && !busy,
              error: errors['field_key'],
              hint: isNew
                  ? 'حروف کوچک انگلیسی، رقم و زیرخط؛ مثلاً weight_kg. پس از ایجاد قابل تغییر نیست.'
                  : 'کلید فیلد قابل تغییر نیست.',
            ),
            ChoiceField<String>(
              label: 'نوع داده',
              isRequired: true,
              value: _type,
              enabled: isNew && !busy,
              error: errors['data_type'],
              options: [for (final entry in fieldTypeLabels.entries) (entry.key, entry.value)],
              onChanged: (value) {
                if (value != null && value != _type) _setType(value);
              },
              hint: isNew
                  ? 'پس از ایجاد قابل تغییر نیست.'
                  : 'نوع داده قابل تغییر نیست؛ در صورت نیاز این فیلد را غیرفعال و فیلد تازه‌ای تعریف کنید.',
            ),
            AppTextField(
              label: 'ترتیب نمایش',
              controller: _order,
              ltr: true,
              maxLength: 6,
              keyboardType: TextInputType.number,
              enabled: !busy,
              error: errors['display_order'],
              hint: 'فیلدها به ترتیب صعودی این عدد نمایش داده می‌شوند.',
            ),
          ],
        ),
        FormGrid(
          minColumnWidth: 230,
          children: [
            CheckField(
              label: 'وارد کردن این فیلد الزامی است',
              value: _isRequired,
              enabled: !busy,
              onChanged: (value) => setState(() => _isRequired = value),
            ),
            CheckField(
              label: 'به مشتری نمایش داده شود',
              value: _isCustomerVisible,
              enabled: !busy,
              hint: 'مشتری مقدار این فیلد را در صفحهٔ رهگیری می‌بیند.',
              onChanged: (value) => setState(() => _isCustomerVisible = value),
            ),
            CheckField(
              label: 'فیلد فعال است',
              value: _isActive,
              enabled: !busy,
              hint: 'فیلد غیرفعال در فرم‌ها نمایش داده نمی‌شود، ولی مقادیر ثبت‌شدهٔ قبلی حفظ می‌شوند.',
              onChanged: (value) => setState(() => _isActive = value),
            ),
          ],
        ),
        if (_hasOptions(_type)) _optionEditor(),
        if (definitions.isNotEmpty) _ruleEditor(definitions),
      ],
    );
  }
}

/// The control for one validation rule. It edits [input]; the dialog reads all of them when the form is sent.
class _RuleControl extends StatefulWidget {
  const _RuleControl({super.key, required this.definition, required this.input, required this.error});

  final RuleDefinition definition;
  final FieldInput input;
  final String? error;

  @override
  State<_RuleControl> createState() => _RuleControlState();
}

class _RuleControlState extends State<_RuleControl> {
  late final TextEditingController _text = TextEditingController(text: widget.input.text);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final definition = widget.definition;
    final input = widget.input;
    switch (definition.kind) {
      case 'date':
      case 'datetime':
        return JalaliDateField(
          label: definition.label,
          error: widget.error,
          withTime: definition.kind == 'datetime',
          initial: JalaliDateValue(date: input.date, incomplete: input.dateIncomplete, time: input.time),
          onChanged: (value) {
            input.date = value.date;
            input.dateIncomplete = value.incomplete;
            input.time = value.time;
          },
        );
      case 'text':
        return AppTextField(
          label: definition.label,
          controller: _text,
          error: widget.error,
          hint: _patternHint,
          ltr: true,
          maxLength: 200,
          onChanged: (text) => input.text = text,
        );
      default:
        return AppTextField(
          label: definition.label,
          controller: _text,
          error: widget.error,
          ltr: true,
          maxLength: 40,
          keyboardType: TextInputType.numberWithOptions(signed: true, decimal: definition.kind == 'decimal'),
          onChanged: (text) => input.text = text,
        );
    }
  }
}
