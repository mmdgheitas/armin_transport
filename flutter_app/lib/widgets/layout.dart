/// The building blocks of a page: its heading, its cards and lists of labelled values.
library;

import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../theme.dart';

/// The scrolling body of a page: centred, not wider than [maxWidth], with room around it.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.maxWidth = 1180});

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = constraints.maxWidth < 600 ? 12.0 : 24.0;
        return SingleChildScrollView(
          padding: EdgeInsets.all(padding),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (index, child) in children.indexed) ...[if (index > 0) const SizedBox(height: 16), child],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The title of a page with an optional description and its main actions.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.description, this.actions = const <Widget>[], this.leading});

  final String title;
  final String? description;
  final List<Widget> actions;

  /// Shown before the title, e.g. a back button.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final description = this.description;
    final leading = this.leading;
    final heading = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (leading != null) ...[leading, const SizedBox(width: 4)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700, height: 1.5)),
              if (description != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(description, style: const TextStyle(color: AppColors.muted, height: 1.6)),
                ),
            ],
          ),
        ),
      ],
    );
    if (actions.isEmpty) return heading;
    return LayoutBuilder(
      builder: (context, constraints) {
        final buttons = Wrap(spacing: 8, runSpacing: 8, children: actions);
        // On a phone the buttons go below the title instead of squeezing it.
        return constraints.maxWidth < 640
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [heading, const SizedBox(height: 12), buttons],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Expanded(child: heading), const SizedBox(width: 16), buttons],
              );
      },
    );
  }
}

/// A card with an optional heading line. The content goes edge to edge unless [padded].
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.child, this.title, this.actions = const <Widget>[], this.padded = true});

  final String? title;
  final List<Widget> actions;
  final Widget child;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final title = this.title;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
            const Divider(),
          ],
          padded ? Padding(padding: const EdgeInsets.all(16), child: child) : child,
        ],
      ),
    );
  }
}

/// Labels with their values: side by side when there is room, otherwise the value below its label.
/// Entries without a value are left out.
class KeyValueList extends StatelessWidget {
  const KeyValueList(this.entries, {super.key});

  /// The value is a [Widget], or anything else to be shown as text; `null` hides the entry.
  final List<(String label, Object? value)> entries;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final entry in entries)
        if (entry.$2 != null) entry,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 420;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, entry) in shown.indexed) ...[
              if (index > 0) const Divider(height: 17),
              _entry(entry.$1, entry.$2!, wide),
            ],
          ],
        );
      },
    );
  }

  Widget _entry(String label, Object value, bool wide) {
    final labelText = Text(label, style: const TextStyle(fontSize: 13, color: AppColors.muted, height: 1.6));
    final content = value is Widget ? value : Text('$value', style: const TextStyle(height: 1.6));
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [labelText, const SizedBox(height: 2), content],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 150, child: labelText),
        const SizedBox(width: 12),
        Expanded(child: Align(alignment: AlignmentDirectional.centerStart, child: content)),
      ],
    );
  }
}

/// A tracking code: left to right, in a fixed-width look, easy to tell apart from the text around it.
class TrackingCodeText extends StatelessWidget {
  const TrackingCodeText(this.code, {super.key, this.fontSize = 14});

  final String code;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Text(
      code,
      textDirection: TextDirection.ltr,
      style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: AppColors.primaryDark),
    );
  }
}

/// The name of a file: left to right, and never wider than its column allows however long it is.
class FileNameText extends StatelessWidget {
  const FileNameText(this.name, {super.key, this.maxWidth = 320, this.maxLines = 2});

  final String name;
  final double maxWidth;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Text(name, textDirection: TextDirection.ltr, maxLines: maxLines, overflow: TextOverflow.ellipsis),
    );
  }
}

/// The text for a value that may be missing.
String orDash(String? text) => text == null || text.trim().isEmpty ? emptyPlaceholder : text;
