/// One shipment: what it is, its goods, its documents and the history of its tracking code.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_error.dart';
import '../../core/api/models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/tracking.dart';
import '../../theme.dart';
import '../../widgets/async_block.dart';
import '../../widgets/buttons.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/feedback.dart';
import '../../widgets/fields.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';
import '../shared/pick_lists.dart';
import 'shipment_documents_tab.dart';
import 'shipment_goods_tab.dart';
import 'shipment_widgets.dart';

class ShipmentDetailPage extends ConsumerStatefulWidget {
  const ShipmentDetailPage({super.key, required this.shipmentId});

  final String shipmentId;

  @override
  ConsumerState<ShipmentDetailPage> createState() => _ShipmentDetailPageState();
}

class _ShipmentDetailPageState extends ConsumerState<ShipmentDetailPage> {
  final GlobalKey<AsyncBlockState<Shipment>> _block = GlobalKey<AsyncBlockState<Shipment>>();

  /// The tab the user chose; kept here so that it survives loading the shipment again.
  String? _tab;

  /// The shipment changed: show its new state here and in the list underneath.
  void _changed() {
    ref.read(shipmentsRevisionProvider.notifier).bump();
    _block.currentState?.reload(quiet: true);
  }

  /// Runs a change that needs no form and says how it went.
  Future<void> _run(Future<String> Function() action, {bool reloads = true}) async {
    try {
      final message = await action();
      if (!mounted) return;
      showMessage(context, message);
      if (reloads) _changed();
    } catch (error) {
      if (!mounted) return;
      showError(context, error);
    }
  }

  Future<void> _copy(String code) async {
    try {
      await Clipboard.setData(ClipboardData(text: code));
      if (!mounted) return;
      showMessage(context, 'کد رهگیری کپی شد.');
    } catch (_) {
      if (!mounted) return;
      showMessage(context, 'کپی کردن ممکن نشد؛ کد را دستی انتخاب کنید.', error: true);
    }
  }

  /// Shows a form in a dialog; the form closes with the message of the server when the change was made.
  Future<void> _openForm(Widget form) async {
    final message = await showFormDialog<String>(context, (context) => form);
    if (message == null) return;
    if (!mounted) return;
    showMessage(context, message);
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiProvider);
    final auth = ref.watch(authProvider);
    if (auth == null) return const SizedBox.shrink();
    return PageBody(
      children: [
        const PageHeader(title: 'جزئیات محموله', leading: BackToShipments()),
        AsyncBlock<Shipment>(
          key: _block,
          reloadKey: widget.shipmentId,
          loadingText: 'در حال دریافت اطلاعات محموله…',
          load: () => api.shipment(widget.shipmentId),
          builder: (context, shipment) {
            final tabs = _tabs(shipment, auth);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _summary(shipment, auth),
                if (tabs != null) ...[const SizedBox(height: 16), tabs],
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _summary(Shipment shipment, AuthSession auth) {
    final api = ref.read(apiProvider);
    final archived = shipment.isArchived;
    final actions = <Widget>[
      if (!archived && auth.can('shipment:update'))
        OutlinedButton.icon(
          onPressed: () => _openForm(_DescriptionDialog(shipment: shipment)),
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: const Text('ویرایش توضیحات'),
        ),
      if (!archived && auth.can('tracking_code:change'))
        OutlinedButton.icon(
          onPressed: () => _openForm(
            _CodeDialog(
              shipment: shipment,
              manualAllowed: auth.can('tracking_code:manual'),
              rules: auth.settings.trackingCode,
            ),
          ),
          icon: const Icon(Icons.autorenew, size: 18),
          label: const Text('تغییر کد رهگیری'),
        ),
      if (auth.can('customer_session:revoke'))
        ActionButton(
          label: 'لغو دسترسی مشتریان',
          icon: Icons.block,
          confirm: () => confirmAction(
            context,
            title: 'لغو دسترسی مشتریان',
            message:
                'همهٔ نشست‌های فعال مشتریان برای این محموله بسته می‌شود. '
                'مشتری با وارد کردن دوبارهٔ کد رهگیری می‌تواند وارد شود.',
            confirmLabel: 'لغو دسترسی‌ها',
          ),
          // The shipment itself stays as it is.
          onPressed: () => _run(() async => (await api.revokeCustomerSessions(shipment.id)).message, reloads: false),
        ),
      if (!archived && auth.can('shipment:archive'))
        ActionButton(
          label: 'بایگانی',
          icon: Icons.archive_outlined,
          danger: true,
          confirm: () => confirmAction(
            context,
            title: 'بایگانی محموله',
            message:
                'محمولهٔ بایگانی‌شده فقط قابل مشاهده است و دیگر نمی‌توان آن را ویرایش کرد یا سندی به آن افزود. '
                'ادامه می‌دهید؟',
            confirmLabel: 'بایگانی شود',
            danger: true,
          ),
          onPressed: () => _run(() async => (await api.archiveShipment(shipment.id)).message),
        ),
      if (archived && auth.can('shipment:unarchive'))
        ActionButton(
          label: 'خروج از بایگانی',
          icon: Icons.unarchive_outlined,
          onPressed: () => _run(() async => (await api.unarchiveShipment(shipment.id)).message),
        ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      // Selectable, for the rare device on which copying fails.
                      child: SelectableText(
                        shipment.trackingCode,
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: AppColors.primaryDark,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'کپی کد رهگیری',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () => _copy(shipment.trackingCode),
                    ),
                  ],
                ),
                StatusBadge.shipment(shipment.status),
                StatusBadge('کد ${shipment.codeTypeLabel}'),
              ],
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
            if (archived) ...[
              const SizedBox(height: 12),
              const Notice(
                'این محموله بایگانی شده است و فقط می‌توان آن را مشاهده و سندهایش را دریافت کرد.',
                tone: Tone.warning,
              ),
            ],
            const SizedBox(height: 16),
            KeyValueList([
              ('شرکت', orDash(shipment.company?.name)),
              ('ثبت‌کننده', orDash(shipment.createdBy?.fullName)),
              ('تاریخ ثبت', formatDateTime(shipment.createdAt, long: true)),
              ('آخرین تغییر', formatDateTime(shipment.updatedAt, long: true)),
              ('تعداد سندها', formatNumber(shipment.documentCount)),
              ('توضیحات', orDash(shipment.description)),
            ]),
          ],
        ),
      ),
    );
  }

  /// The parts of the shipment the user may see, one at a time; `null` when there is none.
  Widget? _tabs(Shipment shipment, AuthSession auth) {
    final tabs = <(String, String)>[
      if (auth.can('product_value:view')) ('details', 'مشخصات کالا'),
      if (auth.can('document:view')) ('documents', 'سندها (${formatNumber(shipment.documentCount)})'),
      if (auth.can('tracking_code:history')) ('history', 'تاریخچهٔ کد رهگیری'),
    ];
    if (tabs.isEmpty) return null;
    final chosen = tabs.indexWhere((tab) => tab.$1 == _tab);
    final index = chosen < 0 ? 0 : chosen;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TabStrip(
            labels: [for (final tab in tabs) tab.$2],
            selected: index,
            onSelect: (selected) => setState(() => _tab = tabs[selected].$1),
          ),
          // Each tab is a widget of its own type: choosing another tab starts it afresh.
          switch (tabs[index].$1) {
            'documents' => ShipmentDocumentsTab(shipment: shipment, onChanged: _changed),
            'history' => _HistoryTab(shipment: shipment),
            _ => ShipmentGoodsTab(shipment: shipment),
          },
        ],
      ),
    );
  }
}

/// Every tracking code the shipment has had, the newest first.
class _HistoryTab extends ConsumerWidget {
  const _HistoryTab({required this.shipment});

  final Shipment shipment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    return PagedTable<TrackingHistoryEntry>(
      // A new code adds an entry.
      filters: shipment.trackingCode,
      load: (page) => api.trackingHistory(shipment.id, page: page),
      emptyIcon: Icons.history,
      emptyTitle: 'تغییری در کد رهگیری ثبت نشده است.',
      columns: [
        TableColumn<TrackingHistoryEntry>('کد قبلی', (context, entry) {
          final oldCode = entry.oldCode;
          return oldCode == null ? const Text('— (ثبت اولیه)') : TrackingCodeText(oldCode);
        }),
        TableColumn<TrackingHistoryEntry>('کد جدید', (context, entry) => TrackingCodeText(entry.newCode)),
        TableColumn<TrackingHistoryEntry>('تغییردهنده', (context, entry) => Text(orDash(entry.changedBy?.fullName))),
        TableColumn<TrackingHistoryEntry>('زمان', (context, entry) => Text(formatDateTime(entry.changedAt))),
      ],
    );
  }
}

class _DescriptionDialog extends ConsumerStatefulWidget {
  const _DescriptionDialog({required this.shipment});

  final Shipment shipment;

  @override
  ConsumerState<_DescriptionDialog> createState() => _DescriptionDialogState();
}

class _DescriptionDialogState extends ConsumerState<_DescriptionDialog> with FormSupport<_DescriptionDialog> {
  late final TextEditingController _text = TextEditingController(text: widget.shipment.description ?? '');

  @override
  Set<String> get fieldNames => const {'description'};

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _text.text.trim();
    final api = ref.read(apiProvider);
    String? message;
    final done = await runForm(() async {
      message = (await api.updateDescription(widget.shipment.id, text.isEmpty ? null : text)).message;
    });
    if (!done) return;
    if (!mounted) return;
    Navigator.of(context).pop(message ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog(
      title: 'ویرایش توضیحات',
      busy: busy,
      error: formError,
      onSubmit: _submit,
      children: [
        AppTextField(
          label: 'توضیحات',
          controller: _text,
          multiline: true,
          maxLength: 5000,
          autofocus: true,
          enabled: !busy,
          error: errors['description'],
        ),
      ],
    );
  }
}

class _CodeDialog extends ConsumerStatefulWidget {
  const _CodeDialog({required this.shipment, required this.manualAllowed, required this.rules});

  final Shipment shipment;

  /// Whether the user may choose the new code; otherwise the server generates it.
  final bool manualAllowed;
  final TrackingCodeRules rules;

  @override
  ConsumerState<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends ConsumerState<_CodeDialog> with FormSupport<_CodeDialog> {
  final TextEditingController _code = TextEditingController();

  @override
  Set<String> get fieldNames => const {'tracking_code'};

  @override
  void showFormFailure(Object error) {
    super.showFormFailure(error);
    // The code is taken: say so where the code was typed.
    if (widget.manualAllowed && error is ApiError && error.code == 'tracking_code_taken') {
      errors = {'tracking_code': error.message};
      formError = null;
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final manual = widget.manualAllowed ? normalizeTrackingCode(_code.text) : '';
    if (widget.manualAllowed) _code.text = manual;
    final problem = manual.isEmpty ? null : trackingCodeProblem(manual, widget.rules);
    final api = ref.read(apiProvider);
    String? message;
    final done = await runForm(problems: {if (problem != null) 'tracking_code': problem}, () async {
      final changed = await api.changeTrackingCode(widget.shipment.id, manualCode: manual.isEmpty ? null : manual);
      message = changed.message;
    });
    if (!done) return;
    if (!mounted) return;
    Navigator.of(context).pop(message ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog(
      title: 'تغییر کد رهگیری',
      submitLabel: widget.manualAllowed ? 'تغییر کد' : 'تولید کد جدید',
      submitIcon: Icons.autorenew,
      busy: busy,
      error: formError,
      onSubmit: _submit,
      children: [
        const Notice(
          'با تغییر کد، کد فعلی برای همیشه از کار می‌افتد، دسترسی مشتریانی که با آن وارد شده‌اند لغو می‌شود '
          'و کد قدیمی دیگر قابل استفاده نیست.',
          tone: Tone.warning,
        ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [const Text('کد فعلی:'), TrackingCodeText(widget.shipment.trackingCode)],
        ),
        if (widget.manualAllowed)
          AppTextField(
            label: 'کد رهگیری جدید',
            controller: _code,
            ltr: true,
            maxLength: 200,
            autofocus: true,
            enabled: !busy,
            error: errors['tracking_code'],
            hint: 'برای تولید خودکار کد جدید، این فیلد را خالی بگذارید.',
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),
      ],
    );
  }
}
