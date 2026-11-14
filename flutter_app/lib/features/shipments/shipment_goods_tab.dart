/// The goods of a shipment: the values of the fields the administrator defined.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/armin_api.dart';
import '../../core/api/models.dart';
import '../../core/format.dart';
import '../../core/product_fields.dart';
import '../../core/providers.dart';
import '../../theme.dart';
import '../../widgets/async_block.dart';
import '../../widgets/buttons.dart';
import '../../widgets/feedback.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import 'shipment_widgets.dart';

class ShipmentGoodsTab extends ConsumerStatefulWidget {
  const ShipmentGoodsTab({super.key, required this.shipment});

  final Shipment shipment;

  @override
  ConsumerState<ShipmentGoodsTab> createState() => _ShipmentGoodsTabState();
}

class _ShipmentGoodsTabState extends ConsumerState<ShipmentGoodsTab> {
  /// What the last save returned: newer than what was loaded.
  List<ProductValueItem>? _saved;
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiProvider);
    final auth = ref.watch(authProvider);
    final editable = !widget.shipment.isArchived && auth != null && auth.can('product_value:edit');
    return AsyncBlock<List<ProductValueItem>>(
      load: () => api.productValues(widget.shipment.id),
      builder: (context, loaded) {
        final items = _saved ?? loaded;
        if (_editing && editable) {
          return _GoodsForm(
            shipmentId: widget.shipment.id,
            items: items,
            onCancel: () => setState(() => _editing = false),
            onSaved: (saved) => setState(() {
              _saved = saved;
              _editing = false;
            }),
          );
        }
        return _values(items, editable);
      },
    );
  }

  Widget _values(List<ProductValueItem> items, bool editable) {
    // A field that was switched off is still shown as long as this shipment has a value for it.
    final visible = [
      for (final item in items)
        if (item.field.isActive || item.value != null) item,
    ];
    if (visible.isEmpty) {
      return const EmptyBlock(icon: Icons.tune, title: 'فیلدی برای مشخصات کالا تعریف نشده است.');
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (editable && items.any((item) => item.field.isActive)) ...[
            Row(
              children: [
                const Expanded(
                  child: Text('مقادیر ثبت‌شده برای این محموله', style: TextStyle(fontSize: 13, color: AppColors.muted)),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _editing = true),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('ویرایش مشخصات'),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          KeyValueList([for (final item in visible) (item.field.label, _MarkedValue(item))]),
        ],
      ),
    );
  }
}

/// The value of a field, marked when the field or the value needs attention.
class _MarkedValue extends StatelessWidget {
  const _MarkedValue(this.item);

  final ProductValueItem item;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(formatFieldValue(item.field.dataType, item.displayValue), style: const TextStyle(height: 1.6)),
        if (!item.field.isActive) const StatusBadge('فیلد غیرفعال'),
        if (item.isOutdated) const StatusBadge('نیازمند بازبینی', tone: Tone.warning),
      ],
    );
  }
}

class _GoodsForm extends ConsumerStatefulWidget {
  const _GoodsForm({required this.shipmentId, required this.items, required this.onCancel, required this.onSaved});

  final String shipmentId;
  final List<ProductValueItem> items;
  final VoidCallback onCancel;
  final void Function(List<ProductValueItem> items) onSaved;

  @override
  ConsumerState<_GoodsForm> createState() => _GoodsFormState();
}

class _GoodsFormState extends ConsumerState<_GoodsForm> with FormSupport<_GoodsForm> {
  late final List<ProductField> _fields = [
    for (final item in widget.items)
      if (item.field.isActive) item.field,
  ];
  late final Map<String, FieldInput> _inputs = productInputs(_fields, {
    for (final item in widget.items) item.field.fieldKey: item.value,
  });

  @override
  Set<String> get fieldNames => {for (final field in _fields) 'values.${field.fieldKey}'};

  Future<void> _submit() async {
    final collected = collectFieldValues(_fields, _inputs);
    final api = ref.read(apiProvider);
    Done<List<ProductValueItem>>? saved;
    final done = await runForm(
      problems: {for (final entry in collected.errors.entries) 'values.${entry.key}': entry.value},
      () async {
        saved = await api.saveProductValues(widget.shipmentId, collected.values);
      },
    );
    final result = saved;
    if (!done || result == null) return;
    if (!mounted) return;
    showMessage(context, result.message);
    widget.onSaved(result.value);
  }

  @override
  Widget build(BuildContext context) {
    final formError = this.formError;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ProductFieldsGrid(fields: _fields, inputs: _inputs, errors: fieldErrorsFromApi(errors)),
          if (formError != null) ...[const SizedBox(height: 16), Notice(formError, tone: Tone.danger)],
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(onPressed: busy ? null : widget.onCancel, child: const Text('انصراف')),
              BusyButton(label: 'ذخیرهٔ مشخصات', icon: Icons.check, busy: busy, onPressed: _submit),
            ],
          ),
        ],
      ),
    );
  }
}
