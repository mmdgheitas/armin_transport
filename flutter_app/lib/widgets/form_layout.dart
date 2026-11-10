/// Laying out the fields of forms and filters: as many columns as fit.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// What a date filter says about a day that is half entered or does not exist.
const String invalidDateMessage = 'تاریخ واردشده کامل یا معتبر نیست.';

/// Marks a child of a [FormGrid] that takes a whole row.
class FullRow extends StatelessWidget {
  const FullRow({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Puts its children into equally wide columns: as many as fit with [minColumnWidth], at most [maxColumns].
class FormGrid extends StatelessWidget {
  const FormGrid({super.key, required this.children, this.minColumnWidth = 250, this.maxColumns = 4, this.gap = 16});

  final List<Widget> children;
  final double minColumnWidth;
  final int maxColumns;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Without a limit (inside something that scrolls sideways) one column of the smallest width is all there is.
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : minColumnWidth;
        final fitting = ((width + gap) / (minColumnWidth + gap)).floor();
        final columns = math.max(1, math.min(maxColumns, fitting));
        // Rounded down, so that rounding errors never push the last field of a row to the next one.
        final columnWidth = ((width - gap * (columns - 1)) / columns).floorToDouble();
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children) SizedBox(width: child is FullRow ? width : columnWidth, child: child),
          ],
        );
      },
    );
  }
}

/// The filters of a list in a panel that can be folded away. It starts open when there is room
/// or a filter is in effect, and folded on a phone, where it would push the list off the screen.
class FilterPanel extends StatefulWidget {
  const FilterPanel({
    super.key,
    required this.active,
    required this.fields,
    required this.onApply,
    required this.onClear,
  });

  /// True while a filter is in effect.
  final bool active;
  final List<Widget> fields;
  final VoidCallback onApply;
  final VoidCallback onClear;

  @override
  State<FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<FilterPanel> {
  bool? _open;

  @override
  Widget build(BuildContext context) {
    final open = _open ?? (widget.active || MediaQuery.sizeOf(context).width >= 720);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.filter_list, size: 18, color: AppColors.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.active ? 'فیلترها (فعال)' : 'فیلترها',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                Icon(open ? Icons.expand_less : Icons.expand_more, color: AppColors.muted),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Wide enough for a date field: day, month and year side by side.
                FormGrid(minColumnWidth: 280, children: widget.fields),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: widget.onApply,
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('اعمال فیلتر'),
                    ),
                    if (widget.active) TextButton(onPressed: widget.onClear, child: const Text('حذف فیلترها')),
                  ],
                ),
              ],
            ),
          ),
        const Divider(),
      ],
    );
  }
}
