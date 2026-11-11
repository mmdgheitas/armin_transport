/// The audit log: who did what and when. It can be read and filtered, never changed.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/models.dart';
import '../../core/format.dart';
import '../../core/product_fields.dart';
import '../../core/providers.dart';
import '../../routing.dart';
import '../../theme.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/feedback.dart';
import '../../widgets/fields.dart';
import '../../widgets/form_layout.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';
import 'audit_labels.dart';

/// The filters in effect. Records compare by value, so the table loads again exactly when one of them changes.
typedef _Filters = ({String? action, String? entityType, String? from, String? to});

const _Filters _noFilters = (action: null, entityType: null, from: null, to: null);

class AuditLogsPage extends ConsumerStatefulWidget {
  const AuditLogsPage({super.key});

  @override
  ConsumerState<AuditLogsPage> createState() => _AuditLogsPageState();
}

class _AuditLogsPageState extends ConsumerState<AuditLogsPage> {
  String? _action;
  String? _entityType;
  JalaliDateValue _from = const JalaliDateValue();
  JalaliDateValue _to = const JalaliDateValue();
  Map<String, String> _errors = const <String, String>{};

  /// Changes when the filters are cleared, so that the date fields start over.
  int _formVersion = 0;

  _Filters _applied = _noFilters;

  void _apply() {
    final errors = <String, String>{
      if (_from.incomplete) 'from': invalidDateMessage,
      if (_to.incomplete) 'to': invalidDateMessage,
    };
    setState(() {
      _errors = errors;
      if (errors.isNotEmpty) return;
      _applied = (action: _action, entityType: _entityType, from: _from.date, to: _to.date);
    });
  }

  void _clear() {
    setState(() {
      _action = null;
      _entityType = null;
      _from = const JalaliDateValue();
      _to = const JalaliDateValue();
      _errors = const <String, String>{};
      _formVersion += 1;
      _applied = _noFilters;
    });
  }

  /// Shows everything the log holds about [entry]; from there the user may go on to the shipment it is about.
  Future<void> _show(AuditLogEntry entry, {required bool canOpenShipment}) async {
    final shipmentId = canOpenShipment && entry.entityType == 'shipment' ? entry.entityId : null;
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => _EntryDialog(entry: entry, opensShipment: shipmentId != null),
    );
    if (open != true || shipmentId == null) return;
    if (!mounted) return;
    context.go(AppPaths.shipment(shipmentId));
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final api = ref.watch(apiProvider);
    if (auth == null) return const SizedBox.shrink();
    final canOpenShipment = auth.can('shipment:view');
    final applied = _applied;
    final hasFilters =
        applied.action != null || applied.entityType != null || applied.from != null || applied.to != null;

    return PageBody(
      children: [
        const PageHeader(
          title: 'گزارش رویدادها',
          description: 'سابقهٔ ورودها، تغییرات و دسترسی‌ها برای بازبینی امنیتی. این گزارش قابل ویرایش یا حذف نیست.',
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
                  ChoiceField<String>(
                    label: 'رویداد',
                    value: _action,
                    options: [
                      (null, 'همهٔ رویدادها'),
                      for (final entry in auditActionLabels.entries) (entry.key, entry.value),
                    ],
                    onChanged: (value) => setState(() => _action = value),
                  ),
                  ChoiceField<String>(
                    label: 'موجودیت',
                    value: _entityType,
                    options: [
                      (null, 'همه'),
                      for (final entry in auditEntityLabels.entries) (entry.key, entry.value),
                    ],
                    onChanged: (value) => setState(() => _entityType = value),
                  ),
                  JalaliDateField(
                    key: ValueKey<String>('from-$_formVersion'),
                    label: 'از تاریخ',
                    initial: _from,
                    error: _errors['from'],
                    onChanged: (value) => _from = value,
                  ),
                  JalaliDateField(
                    key: ValueKey<String>('to-$_formVersion'),
                    label: 'تا تاریخ',
                    initial: _to,
                    error: _errors['to'],
                    onChanged: (value) => _to = value,
                  ),
                ],
              ),
              PagedTable<AuditLogEntry>(
                filters: applied,
                load: (page) => api.auditLogs(
                  page: page,
                  action: applied.action,
                  entityType: applied.entityType,
                  createdFrom: startOfLocalDay(applied.from),
                  createdTo: endOfLocalDay(applied.to),
                ),
                emptyIcon: Icons.list_alt_outlined,
                emptyTitle: hasFilters ? 'رویدادی با این مشخصات پیدا نشد.' : 'هنوز رویدادی ثبت نشده است.',
                onOpen: (entry) => _show(entry, canOpenShipment: canOpenShipment),
                columns: [
                  TableColumn<AuditLogEntry>('زمان', (context, entry) => Text(formatDateTime(entry.createdAt))),
                  TableColumn<AuditLogEntry>(
                    'رویداد',
                    (context, entry) => StatusBadge(
                      auditActionLabel(entry.action),
                      tone: auditWarningActions.contains(entry.action) ? Tone.warning : Tone.info,
                    ),
                  ),
                  TableColumn<AuditLogEntry>(
                    'کاربر',
                    (context, entry) => CellText(orDash(entry.user?.fullName), maxWidth: 200),
                  ),
                  TableColumn<AuditLogEntry>('موجودیت', (context, entry) => Text(auditEntityLabel(entry.entityType))),
                  TableColumn<AuditLogEntry>('نشانی IP', (context, entry) {
                    final address = entry.ipAddress;
                    return address == null ? const Text(emptyPlaceholder) : LtrText(address);
                  }),
                ],
                actions: (context, entry) => [
                  IconButton(
                    tooltip: 'نمایش جزئیات رویداد',
                    icon: const Icon(Icons.visibility_outlined, size: 20),
                    onPressed: () => _show(entry, canOpenShipment: canOpenShipment),
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

/// Text that is written left to right and can be marked and copied: identifiers, addresses.
class _CopyableText extends StatelessWidget {
  const _CopyableText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      SelectableText(text, textDirection: TextDirection.ltr, style: const TextStyle(height: 1.6));
}

/// Everything the log holds about one entry. Closes with `true` when the user wants to see the shipment.
class _EntryDialog extends StatelessWidget {
  const _EntryDialog({required this.entry, required this.opensShipment});

  final AuditLogEntry entry;

  /// Whether the entry is about a shipment that the user may open.
  final bool opensShipment;

  @override
  Widget build(BuildContext context) {
    final user = entry.user;
    final username = user?.username;
    final entityId = entry.entityId;
    final address = entry.ipAddress;
    final requestId = entry.requestId;
    final metadata = entry.metadata;
    final String userText;
    if (user == null) {
      userText = 'بدون کاربر (مشتری یا سامانه)';
    } else {
      userText = username == null ? user.fullName : '${user.fullName} (${ltrIsolate(username)})';
    }
    return DialogFrame(
      title: auditActionLabel(entry.action),
      width: 560,
      actions: [
        if (opensShipment)
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.inventory_2_outlined, size: 18),
            label: const Text('مشاهدهٔ محموله'),
          ),
        FilledButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('بستن')),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyValueList([
            ('زمان', formatDateTime(entry.createdAt, long: true)),
            ('کاربر', userText),
            ('رویداد', LtrText(entry.action)),
            ('موجودیت', auditEntityLabel(entry.entityType)),
            ('شناسهٔ موجودیت', entityId == null ? null : _CopyableText(entityId)),
            ('نشانی IP', address == null ? null : _CopyableText(address)),
            ('شناسهٔ درخواست', requestId == null ? null : _CopyableText(requestId)),
          ]),
          if (metadata is Map && metadata.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('جزئیات', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(radiusSmall),
                border: Border.all(color: AppColors.border),
              ),
              child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(metadata),
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['Consolas', 'Courier New'],
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
