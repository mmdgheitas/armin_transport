/// The controls of the forms. Every control carries its label above it, as in the web client,
/// and shows its problem or its hint below.
library;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../core/jalali.dart';
import '../theme.dart';

/// Label above, control in the middle, problem or hint below.
class FieldShell extends StatelessWidget {
  const FieldShell({super.key, required this.label, required this.child, this.isRequired = false, this.error, this.hint});

  final String label;
  final Widget child;
  final bool isRequired;

  /// Shown below the control. Controls that show their own messages leave both `null`.
  final String? error;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final error = this.error;
    final hint = this.hint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            text: label,
            children: [if (isRequired) const TextSpan(text: ' *', style: TextStyle(color: AppColors.danger))],
          ),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.text),
        ),
        const SizedBox(height: 6),
        child,
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(error, style: const TextStyle(fontSize: 12, color: AppColors.danger, height: 1.5)),
          )
        else if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(hint, style: const TextStyle(fontSize: 12, color: AppColors.muted, height: 1.5)),
          ),
      ],
    );
  }
}

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.label,
    required this.controller,
    this.error,
    this.hint,
    this.placeholder,
    this.isRequired = false,
    this.ltr = false,
    this.maxLength,
    this.multiline = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.enabled = true,
    this.autofocus = false,
    this.autofillHints,
    this.focusNode,
  });

  final String label;
  final TextEditingController controller;
  final String? error;
  final String? hint;
  final String? placeholder;
  final bool isRequired;

  /// For values that are written left to right whatever the language: codes, user names, numbers, addresses.
  final bool ltr;

  final int? maxLength;
  final bool multiline;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final bool autofocus;
  final Iterable<String>? autofillHints;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return FieldShell(
      label: label,
      isRequired: isRequired,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        autofocus: autofocus,
        textDirection: ltr ? TextDirection.ltr : null,
        keyboardType: multiline ? TextInputType.multiline : keyboardType,
        textInputAction: multiline ? TextInputAction.newline : textInputAction,
        minLines: multiline ? 3 : 1,
        maxLines: multiline ? 6 : 1,
        maxLength: maxLength,
        autofillHints: autofillHints,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          errorText: error,
          helperText: hint,
          hintText: placeholder,
          hintTextDirection: ltr ? TextDirection.ltr : null,
          // The length is limited silently; a counter under every field would be noise.
          counterText: '',
        ),
      ),
    );
  }
}

/// A password is hidden while it is typed; the eye button shows it.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.label,
    required this.controller,
    this.error,
    this.hint,
    this.isNew = false,
    this.textInputAction,
    this.onSubmitted,
    this.enabled = true,
  });

  final String label;
  final TextEditingController controller;
  final String? error;
  final String? hint;

  /// A password that is being chosen, not the one the user already has (for password managers).
  final bool isNew;

  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    return FieldShell(
      label: widget.label,
      isRequired: true,
      child: TextField(
        controller: widget.controller,
        enabled: widget.enabled,
        obscureText: !_visible,
        enableSuggestions: false,
        autocorrect: false,
        textDirection: TextDirection.ltr,
        keyboardType: TextInputType.visiblePassword,
        textInputAction: widget.textInputAction,
        maxLength: 128,
        autofillHints: [widget.isNew ? AutofillHints.newPassword : AutofillHints.password],
        onSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          errorText: widget.error,
          helperText: widget.hint,
          counterText: '',
          suffixIcon: IconButton(
            tooltip: _visible ? 'پنهان کردن رمز' : 'نمایش رمز',
            icon: Icon(_visible ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
            onPressed: () => setState(() => _visible = !_visible),
          ),
        ),
      ),
    );
  }
}

/// One of a list of choices. The first entry may stand for "nothing chosen" with the value `null`.
class ChoiceField<T> extends StatelessWidget {
  const ChoiceField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.error,
    this.hint,
    this.isRequired = false,
    this.enabled = true,
  });

  final String label;
  final T? value;
  final List<(T? value, String label)> options;
  final ValueChanged<T?> onChanged;
  final String? error;
  final String? hint;
  final bool isRequired;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // A value that is not among the options (any more) cannot be shown; treat it as "nothing chosen".
    final known = options.any((option) => option.$1 == value);
    return FieldShell(
      label: label,
      isRequired: isRequired,
      child: DropdownButtonFormField<T>(
        initialValue: known ? value : null,
        isExpanded: true,
        items: [
          for (final option in options)
            DropdownMenuItem<T>(value: option.$1, child: Text(option.$2, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: enabled ? onChanged : null,
        decoration: InputDecoration(errorText: error, helperText: hint),
      ),
    );
  }
}

/// Any number of a list of choices.
class MultiChoiceField extends StatelessWidget {
  const MultiChoiceField({
    super.key,
    required this.label,
    required this.values,
    required this.options,
    required this.onChanged,
    this.error,
    this.hint,
    this.isRequired = false,
  });

  final String label;
  final Set<String> values;
  final List<(String value, String label)> options;
  final ValueChanged<Set<String>> onChanged;
  final String? error;
  final String? hint;
  final bool isRequired;

  @override
  Widget build(BuildContext context) {
    return FieldShell(
      label: label,
      isRequired: isRequired,
      error: error,
      hint: hint,
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final option in options)
            FilterChip(
              label: Text(option.$2),
              selected: values.contains(option.$1),
              onSelected: (selected) {
                final next = {...values};
                if (selected) {
                  next.add(option.$1);
                } else {
                  next.remove(option.$1);
                }
                onChanged(next);
              },
            ),
        ],
      ),
    );
  }
}

/// What a [JalaliDateField] holds.
class JalaliDateValue {
  const JalaliDateValue({this.date, this.incomplete = false, this.time = ''});

  /// The day as a Gregorian ISO date ("YYYY-MM-DD"), or `null` when no day is set.
  final String? date;

  /// True while the day is partly entered or does not exist in the calendar.
  final bool incomplete;

  /// The time of day as typed, e.g. "14:30". Always empty for a field without time.
  final String time;

  bool get isEmpty => date == null && !incomplete && time.trim().isEmpty;
}

final RegExp _digitsOnly = RegExp(r'^\d+$');
final TextInputFormatter _digitFilter = FilteringTextInputFormatter.allow(RegExp('[0-9۰-۹٠-٩]'));
final TextInputFormatter _timeFilter = FilteringTextInputFormatter.allow(RegExp('[0-9۰-۹٠-٩:]'));

/// A date of the Persian calendar, typed as day, month and year, optionally with a time of day.
///
/// The field starts with [initial] and then keeps its own state; give it another [key] to start over.
class JalaliDateField extends StatefulWidget {
  const JalaliDateField({
    super.key,
    required this.label,
    required this.onChanged,
    this.initial = const JalaliDateValue(),
    this.withTime = false,
    this.isRequired = false,
    this.error,
    this.hint,
  });

  final String label;
  final JalaliDateValue initial;
  final ValueChanged<JalaliDateValue> onChanged;
  final bool withTime;
  final bool isRequired;
  final String? error;
  final String? hint;

  @override
  State<JalaliDateField> createState() => _JalaliDateFieldState();
}

class _JalaliDateFieldState extends State<JalaliDateField> {
  late final TextEditingController _day;
  late final TextEditingController _year;
  late final TextEditingController _time;
  int? _month;

  @override
  void initState() {
    super.initState();
    final jalali = isoDateToJalali(widget.initial.date);
    _day = TextEditingController(text: jalali == null ? '' : toPersianDigits(jalali.day));
    _year = TextEditingController(text: jalali == null ? '' : toPersianDigits(jalali.year));
    _time = TextEditingController(text: widget.initial.time);
    _month = jalali?.month;
  }

  @override
  void dispose() {
    _day.dispose();
    _year.dispose();
    _time.dispose();
    super.dispose();
  }

  JalaliDateValue _read() {
    final day = toLatinDigits(_day.text).trim();
    final year = toLatinDigits(_year.text).trim();
    final month = _month;
    final time = widget.withTime ? _time.text.trim() : '';
    if (day.isEmpty && year.isEmpty && month == null) return JalaliDateValue(time: time);
    if (month == null || !_digitsOnly.hasMatch(day) || !_digitsOnly.hasMatch(year)) {
      return JalaliDateValue(incomplete: true, time: time);
    }
    final date = jalaliToIsoDate(int.parse(year), month, int.parse(day));
    return date == null ? JalaliDateValue(incomplete: true, time: time) : JalaliDateValue(date: date, time: time);
  }

  void _changed() => widget.onChanged(_read());

  Future<void> _pickTime() async {
    final parts = toLatinDigits(_time.text).trim().split(':');
    final hour = parts.length == 2 ? int.tryParse(parts[0]) : null;
    final minute = parts.length == 2 ? int.tryParse(parts[1]) : null;
    var initialTime = const TimeOfDay(hour: 12, minute: 0);
    if (hour != null && minute != null && hour >= 0 && hour < 24 && minute >= 0 && minute < 60) {
      initialTime = TimeOfDay(hour: hour, minute: minute);
    }
    final picked = await showTimePicker(context: context, initialTime: initialTime);
    if (picked == null || !mounted) return;
    _time.text = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    _changed();
  }

  Widget _number(TextEditingController controller, String placeholder, int maxLength) => TextField(
    controller: controller,
    keyboardType: TextInputType.number,
    textAlign: TextAlign.center,
    maxLength: maxLength,
    inputFormatters: [_digitFilter],
    onChanged: (_) => _changed(),
    decoration: InputDecoration(hintText: placeholder, counterText: ''),
  );

  @override
  Widget build(BuildContext context) {
    final date = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 64, child: _number(_day, 'روز', 2)),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonFormField<int>(
            initialValue: _month,
            isExpanded: true,
            items: [
              const DropdownMenuItem<int>(child: Text('ماه', style: TextStyle(color: AppColors.muted))),
              for (final (index, name) in jalaliMonthNames.indexed)
                DropdownMenuItem<int>(value: index + 1, child: Text(name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (month) {
              setState(() => _month = month);
              _changed();
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(width: 84, child: _number(_year, 'سال', 4)),
      ],
    );
    final time = widget.withTime
        ? TextField(
            controller: _time,
            keyboardType: TextInputType.datetime,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
            maxLength: 5,
            inputFormatters: [_timeFilter],
            onChanged: (_) => _changed(),
            decoration: InputDecoration(
              hintText: '14:30',
              hintTextDirection: TextDirection.ltr,
              counterText: '',
              suffixIcon: IconButton(
                tooltip: 'انتخاب ساعت',
                icon: const Icon(Icons.schedule, size: 20),
                onPressed: _pickTime,
              ),
            ),
          )
        : null;
    return FieldShell(
      label: widget.label,
      isRequired: widget.isRequired,
      error: widget.error,
      hint: widget.hint,
      child: time == null
          ? date
          : LayoutBuilder(
              // On a phone the time gets a line of its own; a single line would squeeze the month away.
              builder: (context, constraints) => constraints.maxWidth >= 440
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [Expanded(child: date), const SizedBox(width: 8), SizedBox(width: 132, child: time)],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [date, const SizedBox(height: 8), time],
                    ),
            ),
    );
  }
}
