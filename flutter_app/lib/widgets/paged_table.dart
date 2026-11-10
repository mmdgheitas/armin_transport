/// A list from the server, one page at a time: a table on wide screens, cards on narrow ones.
library;

import 'package:material_ui/material_ui.dart';

import '../core/api/models.dart';
import '../core/format.dart';
import '../theme.dart';
import 'feedback.dart';

/// One column of a table: the heading and what to show for an item.
class TableColumn<T> {
  const TableColumn(this.label, this.cell);

  final String label;
  final Widget Function(BuildContext context, T item) cell;
}

/// Below this width a table would have to be scrolled sideways, so the rows are shown as cards.
const double tableBreakpoint = 760;

/// Rows of items: a table when there is room, otherwise one card per item with its values below each other.
class ResponsiveTable<T> extends StatelessWidget {
  const ResponsiveTable({super.key, required this.items, required this.columns, this.onOpen, this.actions});

  final List<T> items;
  final List<TableColumn<T>> columns;

  /// Opens an item: by tapping its row or card.
  final void Function(T item)? onOpen;

  /// Buttons for an item, shown in the last column or at the bottom of the card.
  final List<Widget> Function(BuildContext context, T item)? actions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth >= tableBreakpoint ? _table(context, constraints.maxWidth) : _cards(context),
    );
  }

  Widget _table(BuildContext context, double width) {
    final actions = this.actions;
    final onOpen = this.onOpen;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: width),
        child: DataTable(
          showCheckboxColumn: false,
          dataRowMinHeight: 52,
          dataRowMaxHeight: 64,
          columns: [
            for (final column in columns) DataColumn(label: Text(column.label)),
            if (actions != null) const DataColumn(label: Text('عملیات')),
          ],
          rows: [
            for (final item in items)
              DataRow(
                onSelectChanged: onOpen == null ? null : (_) => onOpen(item),
                cells: [
                  for (final column in columns) DataCell(column.cell(context, item)),
                  if (actions != null) DataCell(Row(mainAxisSize: MainAxisSize.min, children: actions(context, item))),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _cards(BuildContext context) {
    final actions = this.actions;
    final onOpen = this.onOpen;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (index, item) in items.indexed) ...[
          if (index > 0) const Divider(),
          InkWell(
            onTap: onOpen == null ? null : () => onOpen(item),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final column in columns)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 104,
                            child: Text(column.label, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Align(alignment: AlignmentDirectional.centerStart, child: column.cell(context, item)),
                          ),
                        ],
                      ),
                    ),
                  if (actions != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(spacing: 4, runSpacing: 4, children: actions(context, item)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Shows the pages of a list. A new first page is loaded whenever [filters] changes;
/// [PagedTableState.reload] loads the current page again after a change.
class PagedTable<T> extends StatefulWidget {
  const PagedTable({
    super.key,
    required this.load,
    required this.columns,
    required this.emptyTitle,
    this.filters,
    this.emptyText,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyAction,
    this.onOpen,
    this.actions,
  });

  final Future<PageOf<T>> Function(int page) load;
  final List<TableColumn<T>> columns;

  /// Anything that identifies the current filters; compared with `==`.
  final Object? filters;

  final String emptyTitle;
  final String? emptyText;
  final IconData emptyIcon;
  final Widget? emptyAction;

  /// Opens an item: by tapping its row or card.
  final void Function(T item)? onOpen;

  /// Buttons for an item, shown in the last column or at the bottom of the card.
  final List<Widget> Function(BuildContext context, T item)? actions;

  @override
  State<PagedTable<T>> createState() => PagedTableState<T>();
}

class PagedTableState<T> extends State<PagedTable<T>> {
  int _page = 1;
  PageOf<T>? _data;
  Object? _error;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load(1);
  }

  @override
  void didUpdateWidget(PagedTable<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filters != oldWidget.filters) {
      _loading = true;
      _error = null;
      _load(1);
    }
  }

  /// Loads the current page again (or [page]), keeping the rows on screen until the new ones have arrived.
  Future<void> reload({int? page}) {
    setState(() {
      _loading = true;
      _error = null;
    });
    return _load(page ?? _page);
  }

  Future<void> _load(int page) async {
    final generation = ++_generation;
    try {
      var data = await widget.load(page);
      var shown = page;
      // The list became shorter (for example after archiving the last row of the last page): show its new last page.
      final pagination = data.pagination;
      if (data.items.isEmpty && pagination.total > 0 && page > pagination.totalPages && pagination.totalPages >= 1) {
        shown = pagination.totalPages;
        data = await widget.load(shown);
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = data;
        _page = shown;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) return ErrorBlock(error: error, onRetry: reload);
    final data = _data;
    if (data == null) return const LoadingBlock();
    if (data.items.isEmpty) {
      return EmptyBlock(
        title: widget.emptyTitle,
        text: widget.emptyText,
        icon: widget.emptyIcon,
        action: widget.emptyAction,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Reserve the line, so that the rows do not jump when a page starts and stops loading.
        SizedBox(height: 3, child: _loading ? const LinearProgressIndicator(minHeight: 3) : null),
        ResponsiveTable<T>(items: data.items, columns: widget.columns, onOpen: widget.onOpen, actions: widget.actions),
        const Divider(),
        _Pager(
          pagination: data.pagination,
          page: _page,
          enabled: !_loading,
          onPage: (page) => reload(page: page),
        ),
      ],
    );
  }
}

class _Pager extends StatelessWidget {
  const _Pager({required this.pagination, required this.page, required this.enabled, required this.onPage});

  final Pagination pagination;
  final int page;
  final bool enabled;
  final void Function(int page) onPage;

  @override
  Widget build(BuildContext context) {
    final pages = pagination.totalPages;
    final summary = pages > 1
        ? '${formatNumber(pagination.total)} مورد · صفحهٔ ${toPersianDigits(page)} از ${toPersianDigits(pages)}'
        : '${formatNumber(pagination.total)} مورد';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(child: Text(summary, style: const TextStyle(fontSize: 13, color: AppColors.muted))),
          if (pages > 1) ...[
            // These icons are mirrored in right-to-left text: "left" points back, towards the previous page.
            TextButton.icon(
              onPressed: enabled && page > 1 ? () => onPage(page - 1) : null,
              icon: const Icon(Icons.chevron_left, size: 18),
              label: const Text('قبلی'),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: enabled && pagination.hasNext ? () => onPage(page + 1) : null,
              icon: const Icon(Icons.chevron_right, size: 18),
              iconAlignment: IconAlignment.end,
              label: const Text('بعدی'),
            ),
          ],
        ],
      ),
    );
  }
}
