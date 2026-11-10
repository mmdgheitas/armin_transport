/// Registering a new shipment.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_error.dart';
import '../../core/api/armin_api.dart';
import '../../core/api/models.dart';
import '../../core/product_fields.dart';
import '../../core/providers.dart';
import '../../core/tracking.dart';
import '../../routing.dart';
import '../../widgets/async_block.dart';
import '../../widgets/buttons.dart';
import '../../widgets/feedback.dart';
import '../../widgets/fields.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../shared/pick_lists.dart';
import 'shipment_widgets.dart';

typedef _FormData = ({List<ProductField> fields, List<Company> companies});

class ShipmentNewPage extends ConsumerWidget {
  const ShipmentNewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final api = ref.watch(apiProvider);
    if (auth == null) return const SizedBox.shrink();
    final isGlobal = auth.isGlobal;
    return PageBody(
      maxWidth: 900,
      children: [
        const PageHeader(
          title: 'ثبت محمولهٔ جدید',
          description: 'پس از ثبت، کد رهگیری را در اختیار مشتری قرار دهید و سندها را بارگذاری کنید.',
          leading: BackToShipments(),
        ),
        AsyncBlock<_FormData>(
          load: () async {
            final fields = await loadActiveProductFields(api, auth.settings);
            final companies = isGlobal
                ? await loadAllCompanies(api, auth.settings, isActive: true)
                : const <Company>[];
            return (fields: fields, companies: companies);
          },
          builder: (context, data) {
            if (isGlobal && data.companies.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Notice('برای ثبت محموله ابتدا باید دست‌کم یک شرکت فعال تعریف شود.', tone: Tone.warning),
                  if (auth.can('company:view')) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton(
                        onPressed: () => context.go(AppPaths.companies),
                        child: const Text('مدیریت شرکت‌ها'),
                      ),
                    ),
                  ],
                ],
              );
            }
            return _NewShipmentForm(
              fields: data.fields,
              companies: data.companies,
              isGlobal: isGlobal,
              canUseManualCode: auth.can('tracking_code:manual'),
              codeRules: auth.settings.trackingCode,
            );
          },
        ),
      ],
    );
  }
}

class _NewShipmentForm extends ConsumerStatefulWidget {
  const _NewShipmentForm({
    required this.fields,
    required this.companies,
    required this.isGlobal,
    required this.canUseManualCode,
    required this.codeRules,
  });

  final List<ProductField> fields;
  final List<Company> companies;
  final bool isGlobal;
  final bool canUseManualCode;
  final TrackingCodeRules codeRules;

  @override
  ConsumerState<_NewShipmentForm> createState() => _NewShipmentFormState();
}

class _NewShipmentFormState extends ConsumerState<_NewShipmentForm> with FormSupport<_NewShipmentForm> {
  final TextEditingController _description = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final FocusNode _codeFocus = FocusNode();
  late final Map<String, FieldInput> _inputs = productInputs(widget.fields);
  late String? _companyId = widget.companies.length == 1 ? widget.companies.first.id : null;
  bool _manual = false;

  @override
  Set<String> get fieldNames => {
    'company_id',
    'tracking_code',
    'description',
    for (final field in widget.fields) 'values.${field.fieldKey}',
  };

  @override
  void showFormFailure(Object error) {
    super.showFormFailure(error);
    // The code is taken: say so where the code was typed.
    if (_manual && error is ApiError && error.code == 'tracking_code_taken') {
      errors = {...errors, 'tracking_code': error.message};
      formError = null;
    }
  }

  @override
  void dispose() {
    _description.dispose();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final problems = <String, String>{};
    final companyId = _companyId;
    if (widget.isGlobal && companyId == null) problems['company_id'] = 'شرکت را انتخاب کنید.';
    String? code;
    if (_manual) {
      code = normalizeTrackingCode(_code.text);
      _code.text = code;
      final problem = trackingCodeProblem(code, widget.codeRules);
      if (problem != null) problems['tracking_code'] = problem;
    }
    final description = _description.text.trim();
    final collected = collectFieldValues(widget.fields, _inputs);
    collected.errors.forEach((key, message) => problems['values.$key'] = message);

    final api = ref.read(apiProvider);
    final router = GoRouter.of(context);
    Done<Shipment>? created;
    final done = await runForm(problems: problems, () async {
      created = await api.createShipment(
        companyId: widget.isGlobal ? companyId : null,
        trackingCode: code,
        description: description.isEmpty ? null : description,
        productValues: widget.fields.isEmpty ? null : collected.values,
      );
    });
    final result = created;
    if (!done || result == null) return;
    if (!mounted) return;
    ref.read(shipmentsRevisionProvider.notifier).bump();
    showMessage(context, result.message);
    router.go(AppPaths.shipment(result.value.id));
  }

  @override
  Widget build(BuildContext context) {
    final formError = this.formError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'اطلاعات محموله',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.isGlobal) ...[
                ChoiceField<String>(
                  label: 'شرکت',
                  isRequired: true,
                  enabled: !busy,
                  value: _companyId,
                  error: errors['company_id'],
                  options: companyOptions(widget.companies, placeholder: 'انتخاب کنید'),
                  onChanged: (value) => setState(() => _companyId = value),
                ),
                const SizedBox(height: 16),
              ],
              if (widget.canUseManualCode) ...[
                FieldShell(
                  label: 'کد رهگیری',
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment<bool>(value: false, label: Text('تولید خودکار')),
                        ButtonSegment<bool>(value: true, label: Text('ورود دستی')),
                      ],
                      selected: {_manual},
                      onSelectionChanged: busy
                          ? null
                          : (selection) {
                              setState(() => _manual = selection.first);
                              if (_manual) _codeFocus.requestFocus();
                            },
                    ),
                  ),
                ),
                if (_manual) ...[
                  const SizedBox(height: 16),
                  AppTextField(
                    label: 'کد رهگیری دستی',
                    controller: _code,
                    focusNode: _codeFocus,
                    isRequired: true,
                    ltr: true,
                    enabled: !busy,
                    maxLength: 200,
                    error: errors['tracking_code'],
                    hint: 'حروف انگلیسی، رقم و خط تیره. کد پس از ثبت یکتا می‌ماند و قابل استفادهٔ دوباره نیست.',
                  ),
                ],
              ] else
                const Notice('کد رهگیری پس از ثبت به‌صورت خودکار، یکتا و غیرقابل‌حدس تولید می‌شود.'),
              const SizedBox(height: 16),
              AppTextField(
                label: 'توضیحات',
                controller: _description,
                multiline: true,
                enabled: !busy,
                maxLength: 5000,
                error: errors['description'],
                hint: 'مثلاً نوع بار و مقصد. بسته به تنظیمات سامانه ممکن است برای مشتری نمایش داده شود.',
              ),
            ],
          ),
        ),
        if (widget.fields.isNotEmpty) ...[
          const SizedBox(height: 16),
          SectionCard(
            title: 'مشخصات کالا',
            child: ProductFieldsGrid(fields: widget.fields, inputs: _inputs, errors: fieldErrorsFromApi(errors)),
          ),
        ],
        if (formError != null) ...[const SizedBox(height: 16), Notice(formError, tone: Tone.danger)],
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: busy ? null : () => context.go(AppPaths.shipments),
              child: const Text('انصراف'),
            ),
            BusyButton(label: 'ثبت محموله', icon: Icons.check, busy: busy, onPressed: _submit),
          ],
        ),
      ],
    );
  }
}
