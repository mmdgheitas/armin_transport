/// The documents of a shipment: the list, who may see what, and adding new ones.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_error.dart';
import '../../core/api/models.dart';
import '../../core/files.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../theme.dart';
import '../../widgets/buttons.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/downloads.dart';
import '../../widgets/feedback.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';

class ShipmentDocumentsTab extends ConsumerStatefulWidget {
  const ShipmentDocumentsTab({super.key, required this.shipment, required this.onChanged});

  final Shipment shipment;

  /// Called after documents were added or removed: the shipment counts them.
  final VoidCallback onChanged;

  @override
  ConsumerState<ShipmentDocumentsTab> createState() => _ShipmentDocumentsTabState();
}

class _ShipmentDocumentsTabState extends ConsumerState<ShipmentDocumentsTab> {
  final GlobalKey<PagedTableState<ShipmentDocument>> _table = GlobalKey<PagedTableState<ShipmentDocument>>();

  void _listChanged({int? page}) {
    _table.currentState?.reload(page: page);
    widget.onChanged();
  }

  Future<void> _download(ShipmentDocument document) async {
    final api = ref.read(apiProvider);
    final files = ref.read(fileGatewayProvider);
    try {
      final saved = await saveDownload(
        download: () => api.downloadDocument(document.id),
        files: files,
        fallbackName: document.originalName,
      );
      if (!mounted) return;
      if (saved) showMessage(context, 'سند ذخیره شد.');
    } catch (error) {
      if (!mounted) return;
      showError(context, error);
    }
  }

  Future<void> _delete(ShipmentDocument document) async {
    final api = ref.read(apiProvider);
    try {
      final message = await api.deleteDocument(document.id);
      if (!mounted) return;
      showMessage(context, message);
      _listChanged();
    } catch (error) {
      if (!mounted) return;
      showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiProvider);
    final auth = ref.watch(authProvider);
    if (auth == null) return const SizedBox.shrink();
    final shipment = widget.shipment;
    final archived = shipment.isArchived;
    final canToggle = !archived && auth.can('document:set_visibility');
    final canDownload = auth.can('document:download');
    final canDelete = !archived && auth.can('document:delete');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!archived && auth.can('document:upload')) ...[
          _UploadPanel(
            shipmentId: shipment.id,
            settings: auth.settings.upload,
            onUploaded: () => _listChanged(page: 1),
          ),
          const Divider(),
        ],
        PagedTable<ShipmentDocument>(
          key: _table,
          load: (page) => api.documents(shipment.id, page: page),
          emptyIcon: Icons.description_outlined,
          emptyTitle: 'هنوز سندی برای این محموله بارگذاری نشده است.',
          columns: [
            TableColumn<ShipmentDocument>(
              'نام فایل',
              (context, document) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // One line: the size goes below it, and a row of the table has room for two lines.
                  FileNameText(document.originalName, maxLines: 1),
                  Text(formatFileSize(document.fileSize), style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                ],
              ),
            ),
            TableColumn<ShipmentDocument>(
              'بارگذاری‌کننده',
              (context, document) => Text(orDash(document.uploadedBy?.fullName)),
            ),
            TableColumn<ShipmentDocument>('تاریخ', (context, document) => Text(formatDateTime(document.createdAt))),
            TableColumn<ShipmentDocument>(
              'نمایش به مشتری',
              (context, document) => canToggle
                  ? _VisibilityToggle(document: document)
                  : (document.isCustomerVisible
                        ? const StatusBadge('قابل مشاهده', tone: Tone.success)
                        : const StatusBadge('پنهان')),
            ),
          ],
          actions: canDownload || canDelete
              ? (context, document) => [
                  if (canDownload)
                    ActionButton(
                      label: 'دریافت',
                      icon: Icons.download_outlined,
                      kind: ButtonKind.text,
                      onPressed: () => _download(document),
                    ),
                  if (canDelete)
                    ActionButton(
                      label: 'حذف',
                      icon: Icons.delete_outline,
                      kind: ButtonKind.text,
                      danger: true,
                      confirm: () => confirmAction(
                        context,
                        title: 'حذف سند',
                        message: 'سند «${document.originalName}» برای همیشه حذف می‌شود. ادامه می‌دهید؟',
                        confirmLabel: 'حذف شود',
                        danger: true,
                      ),
                      onPressed: () => _delete(document),
                    ),
                ]
              : null,
        ),
      ],
    );
  }
}

/// Decides whether the customer sees a document. The change is sent at once.
class _VisibilityToggle extends ConsumerStatefulWidget {
  const _VisibilityToggle({required this.document});

  final ShipmentDocument document;

  @override
  ConsumerState<_VisibilityToggle> createState() => _VisibilityToggleState();
}

class _VisibilityToggleState extends ConsumerState<_VisibilityToggle> {
  late bool _visible = widget.document.isCustomerVisible;
  bool _busy = false;

  @override
  void didUpdateWidget(_VisibilityToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The list was loaded again, or this row now shows another document.
    final document = widget.document;
    if (document.id != oldWidget.document.id || document.isCustomerVisible != oldWidget.document.isCustomerVisible) {
      _visible = document.isCustomerVisible;
    }
  }

  Future<void> _set(bool visible) async {
    if (_busy) return;
    final api = ref.read(apiProvider);
    setState(() {
      _busy = true;
      _visible = visible;
    });
    try {
      final done = await api.setDocumentVisibility(widget.document.id, customerVisible: visible);
      if (!mounted) return;
      setState(() => _busy = false);
      showMessage(context, done.message);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _visible = !visible;
      });
      showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: _visible,
          semanticLabel: 'نمایش ${widget.document.originalName} به مشتری',
          onChanged: _busy ? null : (value) => _set(value ?? false),
        ),
        const Text('قابل مشاهده', style: TextStyle(fontSize: 13)),
      ],
    );
  }
}

/// A file chosen for upload, and what is wrong with it.
class _Selected {
  _Selected(this.file, this.error);

  final PickedFile file;
  String? error;
}

/// Choosing files and sending them. Either all of them are stored or none.
class _UploadPanel extends ConsumerStatefulWidget {
  const _UploadPanel({required this.shipmentId, required this.settings, required this.onUploaded});

  final String shipmentId;
  final UploadSettings settings;
  final VoidCallback onUploaded;

  @override
  ConsumerState<_UploadPanel> createState() => _UploadPanelState();
}

class _UploadPanelState extends ConsumerState<_UploadPanel> {
  final List<_Selected> _selected = <_Selected>[];
  late bool _customerVisible = widget.settings.customerVisibleDefault;
  bool _busy = false;
  String? _message;

  /// The part of the upload that has been sent, between 0 and 1; `null` while the files are being read.
  double? _progress;

  int get _maxFiles => widget.settings.maxFilesPerUpload;
  int get _maxSize => widget.settings.maxFileSizeBytes;
  List<String> get _allowed => widget.settings.allowedExtensions;

  /// What can be said against a file before it is sent. [size] is `null` when the device has not told it yet.
  String? _problemOf(String name, int? size) {
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    if (_allowed.isNotEmpty && !_allowed.contains(extension)) return 'قالب این فایل مجاز نیست.';
    if (size == null) return null;
    if (size == 0) return 'فایل خالی است.';
    if (size > _maxSize) return 'حجم فایل بیشتر از ${formatFileSize(_maxSize)} است.';
    return null;
  }

  Future<void> _pick() async {
    final files = ref.read(fileGatewayProvider);
    final List<PickedFile> picked;
    try {
      picked = await files.pickFiles(allowedExtensions: _allowed, dialogTitle: 'انتخاب سند');
    } catch (_) {
      if (!mounted) return;
      showMessage(context, 'انتخاب فایل ممکن نشد. دوباره تلاش کنید.', error: true);
      return;
    }
    if (!mounted || picked.isEmpty) return;
    setState(() {
      _message = null;
      for (final file in picked) {
        final known = _selected.any((entry) => entry.file.name == file.name && entry.file.size == file.size);
        if (!known) _selected.add(_Selected(file, _problemOf(file.name, file.size)));
      }
    });
  }

  Future<void> _upload() async {
    if (_busy || _selected.isEmpty) return;
    final api = ref.read(apiProvider);
    final files = ref.read(fileGatewayProvider);
    setState(() {
      _busy = true;
      _message = null;
      _progress = null;
    });

    // Read the files. Only now is the size of every file certain.
    final parts = <UploadPart>[];
    var readable = true;
    for (final entry in _selected) {
      Uint8List bytes;
      try {
        bytes = await entry.file.readBytes();
      } catch (_) {
        entry.error = 'خواندن این فایل ممکن نشد.';
        readable = false;
        continue;
      }
      final problem = _problemOf(entry.file.name, bytes.length);
      if (problem != null) {
        entry.error = problem;
        readable = false;
        continue;
      }
      parts.add(UploadPart(filename: entry.file.name, bytes: bytes));
    }
    if (!mounted) return;
    if (!readable) {
      setState(() {
        _busy = false;
        _message = _fixFilesMessage;
      });
      return;
    }

    final String message;
    try {
      final done = await api.uploadDocuments(
        widget.shipmentId,
        files: parts,
        customerVisible: _customerVisible,
        onProgress: (sent, total) {
          if (mounted && total > 0) setState(() => _progress = sent / total);
        },
      );
      message = done.message;
    } catch (error) {
      if (!mounted) return;
      var matched = false;
      if (error is ApiError) {
        // The server names the files it refused by their position in the upload.
        error.fields.forEach((name, problem) {
          final index = name.startsWith('files.') ? int.tryParse(name.substring(6)) : null;
          if (index != null && index >= 0 && index < _selected.length) {
            _selected[index].error = problem;
            matched = true;
          }
        });
        final tooLarge = error.details['file_index'];
        if (tooLarge is int && tooLarge >= 0 && tooLarge < _selected.length) {
          _selected[tooLarge].error = error.message;
          matched = true;
        }
      }
      setState(() {
        _busy = false;
        _message = matched ? _fixFilesMessage : messageOf(error);
      });
      return;
    }
    try {
      await files.discardTemporaryFiles();
    } catch (_) {
      // The copies the file chooser made stay in the cache: no reason to worry the user.
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.clear();
    });
    showMessage(context, message);
    widget.onUploaded();
  }

  static const String _fixFilesMessage =
      'هیچ فایلی بارگذاری نشد. فایل‌های مشخص‌شده را اصلاح یا حذف کنید و دوباره تلاش کنید.';

  @override
  Widget build(BuildContext context) {
    final tooMany = _selected.length > _maxFiles;
    final message =
        _message ?? (tooMany ? 'در هر بار حداکثر ${formatNumber(_maxFiles)} فایل قابل بارگذاری است.' : null);
    final ready = _selected.isNotEmpty && !tooMany && !_selected.any((entry) => entry.error != null);
    final limits = [
      'حداکثر ${formatNumber(_maxFiles)} فایل، هر فایل تا ${formatFileSize(_maxSize)}',
      if (_allowed.isNotEmpty) 'قالب‌های مجاز: ${_allowed.join('، ')}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.attach_file, size: 18),
                label: const Text('انتخاب فایل‌ها'),
              ),
              Text(limits, style: const TextStyle(fontSize: 13, color: AppColors.muted, height: 1.6)),
            ],
          ),
          for (final (index, entry) in _selected.indexed) ...[
            const SizedBox(height: 8),
            _SelectedFile(
              entry: entry,
              onRemove: _busy
                  ? null
                  : () => setState(() {
                      _selected.removeAt(index);
                      _message = null;
                    }),
            ),
          ],
          if (message != null) ...[const SizedBox(height: 12), Notice(message, tone: Tone.danger)],
          if (_busy) ...[const SizedBox(height: 12), LinearProgressIndicator(value: _progress)],
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: _customerVisible,
                    onChanged: _busy ? null : (value) => setState(() => _customerVisible = value ?? false),
                  ),
                  const Flexible(child: Text('مشتری بتواند این سندها را با کد رهگیری ببیند')),
                ],
              ),
              BusyButton(
                label: _selected.isEmpty ? 'بارگذاری' : 'بارگذاری ${formatNumber(_selected.length)} فایل',
                icon: Icons.upload_outlined,
                busy: _busy,
                onPressed: ready ? _upload : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SelectedFile extends StatelessWidget {
  const _SelectedFile({required this.entry, required this.onRemove});

  final _Selected entry;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final error = entry.error;
    final size = entry.file.size;
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: error == null ? AppColors.surfaceAlt : AppColors.dangerSoft,
        borderRadius: BorderRadius.circular(radiusSmall),
        border: Border.all(color: error == null ? AppColors.border : AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.insert_drive_file_outlined, size: 20, color: AppColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(entry.file.name, textDirection: TextDirection.ltr, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (size != null)
                  Text(formatFileSize(size), style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                if (error != null) Text(error, style: const TextStyle(fontSize: 13, color: AppColors.danger)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'حذف ${entry.file.name} از فهرست',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
