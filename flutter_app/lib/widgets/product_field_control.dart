/// The form control for one goods field, whatever its type.
library;

import 'package:material_ui/material_ui.dart';

import '../core/api/models.dart';
import '../core/product_fields.dart';
import 'fields.dart';

/// Edits [input], the raw state of the value of [field]. [onChanged] is called after every edit.
///
/// Read the result with `inputToApiValue` or `collectFieldValues`.
class ProductFieldControl extends StatefulWidget {
  const ProductFieldControl({super.key, required this.field, required this.input, this.error, this.onChanged});

  final ProductField field;
  final FieldInput input;
  final String? error;
  final VoidCallback? onChanged;

  @override
  State<ProductFieldControl> createState() => _ProductFieldControlState();
}

class _ProductFieldControlState extends State<ProductFieldControl> {
  late final TextEditingController _text = TextEditingController(text: widget.input.text);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _edit(VoidCallback change) {
    setState(change);
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final input = widget.input;
    final hint = describeRules(field);
    switch (field.dataType) {
      case 'NUMBER':
      case 'DECIMAL':
        final isInteger = field.dataType == 'NUMBER';
        return AppTextField(
          label: field.label,
          controller: _text,
          isRequired: field.isRequired,
          error: widget.error,
          hint: hint,
          ltr: true,
          maxLength: isInteger ? 20 : 40,
          keyboardType: TextInputType.numberWithOptions(signed: true, decimal: !isInteger),
          onChanged: (text) => _edit(() => input.text = text),
        );
      case 'DATE':
      case 'DATETIME':
        return JalaliDateField(
          label: field.label,
          isRequired: field.isRequired,
          error: widget.error,
          hint: hint,
          withTime: field.dataType == 'DATETIME',
          initial: JalaliDateValue(date: input.date, incomplete: input.dateIncomplete, time: input.time),
          onChanged: (value) => _edit(() {
            input.date = value.date;
            input.dateIncomplete = value.incomplete;
            input.time = value.time;
          }),
        );
      case 'BOOLEAN':
        return ChoiceField<bool>(
          label: field.label,
          isRequired: field.isRequired,
          error: widget.error,
          value: input.flag,
          options: const [(null, 'انتخاب نشده'), (true, 'بله'), (false, 'خیر')],
          onChanged: (value) => _edit(() => input.flag = value),
        );
      case 'SELECT':
        return ChoiceField<String>(
          label: field.label,
          isRequired: field.isRequired,
          error: widget.error,
          value: input.choice,
          options: [(null, 'انتخاب نشده'), for (final option in field.options) (option.value, option.label)],
          onChanged: (value) => _edit(() => input.choice = value),
        );
      case 'MULTI_SELECT':
        return MultiChoiceField(
          label: field.label,
          isRequired: field.isRequired,
          error: widget.error,
          hint: hint,
          values: input.choices,
          options: [for (final option in field.options) (option.value, option.label)],
          onChanged: (values) => _edit(() => input.choices = values),
        );
      default:
        final maxLength = field.validationRules['max_length'];
        return AppTextField(
          label: field.label,
          controller: _text,
          isRequired: field.isRequired,
          error: widget.error,
          hint: hint,
          maxLength: 2000,
          multiline: maxLength is num && maxLength > 300,
          onChanged: (text) => _edit(() => input.text = text),
        );
    }
  }
}
