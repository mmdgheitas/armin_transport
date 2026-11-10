/// What several screens show about shipments.
library;

import 'package:material_ui/material_ui.dart';

import '../../core/api/models.dart';
import '../../core/format.dart';
import '../../widgets/feedback.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';

/// The columns of a list of shipments. The company is only of interest to users who see more than one.
List<TableColumn<Shipment>> shipmentColumns({required bool showCompany, bool showCodeType = false}) => [
  TableColumn<Shipment>('کد رهگیری', (context, shipment) => TrackingCodeText(shipment.trackingCode)),
  TableColumn<Shipment>(
    'توضیحات',
    (context, shipment) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Text(orDash(shipment.description), maxLines: 2, overflow: TextOverflow.ellipsis),
    ),
  ),
  if (showCompany) TableColumn<Shipment>('شرکت', (context, shipment) => Text(orDash(shipment.company?.name))),
  if (showCodeType) TableColumn<Shipment>('نوع کد', (context, shipment) => Text(shipment.codeTypeLabel)),
  TableColumn<Shipment>('وضعیت', (context, shipment) => StatusBadge.shipment(shipment.status)),
  TableColumn<Shipment>('تاریخ ثبت', (context, shipment) => Text(formatDateTime(shipment.createdAt))),
];
