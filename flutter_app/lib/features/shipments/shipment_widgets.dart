/// What several screens show about shipments.
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/models.dart';
import '../../core/format.dart';
import '../../core/product_fields.dart';
import '../../routing.dart';
import '../../theme.dart';
import '../../widgets/feedback.dart';
import '../../widgets/form_layout.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';
import '../../widgets/product_field_control.dart';

/// The columns of a list of shipments. The company is only of interest to users who see more than one;
/// [detailed] adds what the full list shows beyond the summary on the dashboard.
List<TableColumn<Shipment>> shipmentColumns({required bool showCompany, bool detailed = false}) => [
  TableColumn<Shipment>('کد رهگیری', (context, shipment) => TrackingCodeText(shipment.trackingCode)),
  TableColumn<Shipment>(
    'توضیحات',
    (context, shipment) => CellText(orDash(shipment.description), maxWidth: detailed ? 260 : 320),
  ),
  if (showCompany)
    TableColumn<Shipment>('شرکت', (context, shipment) => CellText(orDash(shipment.company?.name), maxWidth: 200)),
  if (detailed) ...[
    TableColumn<Shipment>(
      'ثبت‌کننده',
      (context, shipment) => CellText(orDash(shipment.createdBy?.fullName), maxWidth: 180),
    ),
    TableColumn<Shipment>('نوع کد', (context, shipment) => Text(shipment.codeTypeLabel)),
    TableColumn<Shipment>('سندها', (context, shipment) => Text(formatNumber(shipment.documentCount))),
  ],
  TableColumn<Shipment>('وضعیت', (context, shipment) => StatusBadge.shipment(shipment.status)),
  TableColumn<Shipment>('تاریخ ثبت', (context, shipment) => Text(formatDateTime(shipment.createdAt))),
];

/// Leads back to the list of shipments; shown before the title of the pages that lie on top of it.
class BackToShipments extends StatelessWidget {
  const BackToShipments({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'بازگشت به فهرست',
      // Mirrored in a right-to-left layout: it points to where the user came from.
      icon: const Icon(Icons.arrow_back),
      onPressed: () => context.go(AppPaths.shipments),
    );
  }
}

/// The state of the controls for [fields], showing the stored values in [current] (keyed by field key).
Map<String, FieldInput> productInputs(
  List<ProductField> fields, [
  Map<String, Object?> current = const <String, Object?>{},
]) => {for (final field in fields) field.fieldKey: FieldInput.fromApiValue(field, current[field.fieldKey])};

/// The controls for the goods of a shipment, as many side by side as fit.
class ProductFieldsGrid extends StatelessWidget {
  const ProductFieldsGrid({super.key, required this.fields, required this.inputs, required this.errors});

  final List<ProductField> fields;

  /// The state of the controls by field key, as made by [productInputs].
  final Map<String, FieldInput> inputs;

  /// Messages by field key.
  final Map<String, String> errors;

  @override
  Widget build(BuildContext context) {
    return FormGrid(
      minColumnWidth: 280,
      maxColumns: 2,
      children: [
        for (final field in fields)
          ProductFieldControl(
            key: ValueKey<String>(field.id),
            field: field,
            input: inputs[field.fieldKey] ?? FieldInput(),
            error: errors[field.fieldKey],
          ),
      ],
    );
  }
}

/// A row of tabs above content that the caller swaps.
class TabStrip extends StatelessWidget {
  const TabStrip({super.key, required this.labels, required this.selected, required this.onSelect});

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (index, label) in labels.indexed)
              Semantics(
                button: true,
                selected: index == selected,
                child: InkWell(
                  onTap: () => onSelect(index),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          width: 2,
                          color: index == selected ? AppColors.primary : const Color(0x00000000),
                        ),
                      ),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontWeight: index == selected ? FontWeight.w700 : FontWeight.w500,
                        color: index == selected ? AppColors.primary : AppColors.muted,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
