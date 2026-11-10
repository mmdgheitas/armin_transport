/// The customer portal: look up a shipment by its tracking code and read what the company shares about it.
///
/// A correct code yields a short-lived access token. It is kept in memory only and given up when the screen is left.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_error.dart';
import '../../core/api/armin_api.dart';
import '../../core/api/models.dart';
import '../../core/config.dart';
import '../../core/files.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/tracking.dart';
import '../../routing.dart';
import '../../theme.dart';
import '../../widgets/async_block.dart';
import '../../widgets/buttons.dart';
import '../../widgets/downloads.dart';
import '../../widgets/feedback.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';
import '../shell/public_scaffold.dart';

const String _sessionEnded = 'نشست مشاهدهٔ محموله به پایان رسیده است. برای ادامه، کد رهگیری را دوباره وارد کنید.';

bool _isSessionOver(Object error) => error is ApiError && error.status == 401;

class TrackScreen extends ConsumerStatefulWidget {
  const TrackScreen({super.key});

  @override
  ConsumerState<TrackScreen> createState() => _TrackScreenState();
}

class _TrackScreenState extends ConsumerState<TrackScreen> {
  final TextEditingController _code = TextEditingController();
  final FocusNode _codeFocus = FocusNode();
  bool _busy = false;
  String? _error;
  String? _notice;

  /// The access in use, together with the API it was granted by.
  ({ArminApi api, CustomerGrant grant})? _access;

  @override
  void dispose() {
    final access = _access;
    // Best effort: the access expires on its own within minutes.
    if (access != null) unawaited(access.api.endCustomerAccess(access.grant).catchError((Object _) {}));
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    if (_busy) return;
    final code = normalizeTrackingCode(_code.text);
    _code.text = code;
    if (code.isEmpty) {
      setState(() {
        _error = 'کد رهگیری را وارد کنید.';
        _notice = null;
      });
      _codeFocus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final api = ref.read(apiProvider);
    try {
      final grant = await api.customerLookup(code);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _access = (api: api, grant: grant);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = messageOf(error);
      });
      _codeFocus.requestFocus();
      _code.selection = TextSelection(baseOffset: 0, extentOffset: _code.text.length);
    }
  }

  /// Back to the form. The access is forgotten here; [notice] tells the visitor why.
  void _showLookup([String? notice]) {
    if (!mounted) return;
    setState(() {
      _access = null;
      _notice = notice;
      _error = null;
      _code.clear();
    });
  }

  Future<void> _finish() async {
    final access = _access;
    if (access != null) await access.api.endCustomerAccess(access.grant);
    _showLookup();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appSessionProvider);
    final signedIn = ref.watch(authProvider) != null;
    final access = _access;
    final server = ServerAddress.parse(app.serverUrl ?? '').displayHost;
    return PublicScaffold(
      action: signedIn
          ? OutlinedButton.icon(
              onPressed: () => context.go(AppPaths.dashboard),
              icon: const Icon(Icons.dashboard_outlined, size: 18),
              label: const Text('بازگشت به پنل'),
            )
          : OutlinedButton.icon(
              onPressed: () => context.go(AppPaths.login),
              icon: const Icon(Icons.lock_outline, size: 18),
              label: const Text('ورود کارکنان'),
            ),
      children: [
        if (access == null)
          ..._lookupForm()
        else
          _ShipmentView(
            // A new access starts with a fresh view.
            key: ValueKey<String>(access.grant.accessToken),
            api: access.api,
            grant: access.grant,
            files: ref.watch(fileGatewayProvider),
            onSessionOver: () => _showLookup(_sessionEnded),
            onFinish: _finish,
          ),
        if (access == null && server.isNotEmpty) ...[
          const SizedBox(height: 16),
          ServerLine(host: server, canChange: !app.serverIsFixed),
        ],
      ],
    );
  }

  List<Widget> _lookupForm() {
    final error = _error;
    final notice = _notice;
    return [
      const SizedBox(height: 16),
      const Text(
        'رهگیری محموله',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text(
        'کد رهگیری‌ای را که هنگام تحویل بار دریافت کرده‌اید وارد کنید تا وضعیت و سندهای محموله را ببینید.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.muted, height: 1.8),
      ),
      const SizedBox(height: 24),
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                label: 'کد رهگیری',
                child: TextField(
                  controller: _code,
                  focusNode: _codeFocus,
                  enabled: !_busy,
                  autofocus: true,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.characters,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.search,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 200,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500, letterSpacing: 1),
                  decoration: const InputDecoration(
                    hintText: 'ABCD-1234-EFGH-5678',
                    hintTextDirection: TextDirection.ltr,
                    counterText: '',
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 18),
                  ),
                  onSubmitted: (_) => _lookup(),
                ),
              ),
              const SizedBox(height: 12),
              BusyButton(label: 'رهگیری', icon: Icons.search, busy: _busy, onPressed: _lookup),
              if (error != null) ...[const SizedBox(height: 16), Notice(error, tone: Tone.danger)],
              if (error == null && notice != null) ...[const SizedBox(height: 16), Notice(notice)],
            ],
          ),
        ),
      ),
    ];
  }
}

class _ShipmentView extends StatelessWidget {
  const _ShipmentView({
    super.key,
    required this.api,
    required this.grant,
    required this.files,
    required this.onSessionOver,
    required this.onFinish,
  });

  final ArminApi api;
  final CustomerGrant grant;
  final FileGateway files;
  final VoidCallback onSessionOver;
  final Future<void> Function() onFinish;

  /// Runs a request of the portal. When the access is over, the visitor is sent back to the form.
  Future<T> _guarded<T>(Future<T> Function() request) async {
    try {
      return await request();
    } catch (error) {
      if (_isSessionOver(error)) onSessionOver();
      rethrow;
    }
  }

  Future<void> _download(BuildContext context, CustomerDocument document) async {
    try {
      final saved = await saveDownload(
        download: () => api.downloadCustomerDocument(grant, document.id),
        files: files,
        fallbackName: document.name,
      );
      if (!context.mounted) return;
      if (saved) showMessage(context, 'سند ذخیره شد.');
    } catch (error) {
      if (_isSessionOver(error)) {
        onSessionOver();
        return;
      }
      if (!context.mounted) return;
      showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AsyncBlock<CustomerShipment>(
      loadingText: 'در حال دریافت اطلاعات محموله…',
      load: () => _guarded(() => api.customerShipment(grant)),
      builder: (context, shipment) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text('محموله', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                              TrackingCodeText(shipment.trackingCode, fontSize: 17),
                              StatusBadge.shipment(shipment.status),
                            ],
                          ),
                          ActionButton(label: 'پایان و جست‌وجوی کد دیگر', icon: Icons.logout, onPressed: onFinish),
                        ],
                      ),
                      const SizedBox(height: 16),
                      KeyValueList([
                        ('شرکت حمل‌ونقل', shipment.companyName),
                        ('تاریخ ثبت', formatDateTime(shipment.registeredAt, long: true)),
                        ('تعداد سندها', formatNumber(shipment.documentCount)),
                        ('توضیحات', shipment.description),
                      ]),
                    ],
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 3),
                        child: Icon(Icons.schedule, size: 16, color: AppColors.muted),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'برای حفظ امنیت، این صفحه تا ساعت ${formatTime(shipment.sessionExpiresAt)} در دسترس است '
                          'و پس از آن باید کد رهگیری را دوباره وارد کنید.',
                          style: const TextStyle(fontSize: 13, color: AppColors.muted, height: 1.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'مشخصات کالا',
            padded: shipment.productDetails.isNotEmpty,
            child: shipment.productDetails.isEmpty
                ? const EmptyBlock(icon: Icons.inventory_2_outlined, title: 'مشخصاتی برای نمایش ثبت نشده است.')
                : KeyValueList([
                    for (final detail in shipment.productDetails)
                      (detail.label, formatFieldValue(detail.dataType, detail.value)),
                  ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'سندهای محموله',
            padded: false,
            child: PagedTable<CustomerDocument>(
              load: (page) => _guarded(() => api.customerDocuments(grant, page: page, perPage: 20)),
              emptyTitle: 'سندی برای این محموله در دسترس نیست.',
              emptyIcon: Icons.description_outlined,
              columns: [
                TableColumn<CustomerDocument>('نام سند', (context, document) => FileNameText(document.name)),
                TableColumn<CustomerDocument>('حجم', (context, document) => Text(formatFileSize(document.fileSize))),
                TableColumn<CustomerDocument>(
                  'تاریخ بارگذاری',
                  (context, document) => Text(formatDateTime(document.uploadedAt)),
                ),
              ],
              actions: (context, document) => [
                ActionButton(
                  label: 'دریافت',
                  icon: Icons.download_outlined,
                  onPressed: () => _download(context, document),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
