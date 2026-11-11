/// What every form does: show problems next to their fields, wait for the server, map its errors back.
library;

import 'package:material_ui/material_ui.dart';

import '../core/api/api_error.dart';
import 'feedback.dart';

/// Messages for the [labels] whose value in [values] is missing or blank.
Map<String, String> requiredProblems(Map<String, String?> values, Map<String, String> labels) => {
  for (final entry in labels.entries)
    if ((values[entry.key] ?? '').trim().isEmpty) entry.key: entry.value,
};

mixin FormSupport<W extends StatefulWidget> on State<W> {
  /// True while the server is working on the form; the buttons are disabled meanwhile.
  bool busy = false;

  /// Messages keyed by field name, shown next to the fields.
  Map<String, String> errors = const <String, String>{};

  /// A message that belongs to no field, shown above the buttons.
  String? formError;

  /// The fields this form shows. A server message for any other name goes to [formError].
  Set<String> get fieldNames;

  /// Field names of the server that this form shows under another name.
  Map<String, String> get errorAliases => const <String, String>{};

  /// The field of this form that shows what the server says about its field [name].
  String fieldFor(String name) => errorAliases[name] ?? name;

  /// Runs [action] unless local validation found [problems]. Completes with `true` when the action succeeded;
  /// after a failure the messages are on screen.
  Future<bool> runForm(Future<void> Function() action, {Map<String, String> problems = const <String, String>{}}) async {
    if (busy) return false;
    if (problems.isNotEmpty) {
      setState(() {
        errors = problems;
        formError = null;
      });
      return false;
    }
    setState(() {
      busy = true;
      errors = const <String, String>{};
      formError = null;
    });
    try {
      await action();
      if (mounted) setState(() => busy = false);
      return true;
    } catch (error) {
      if (mounted) {
        setState(() {
          busy = false;
          showFormFailure(error);
        });
      }
      return false;
    }
  }

  /// Puts the messages of [error] where they belong. Call it inside `setState`.
  void showFormFailure(Object error) {
    if (error is! ApiError || error.fields.isEmpty) {
      errors = const <String, String>{};
      formError = messageOf(error);
      return;
    }
    final shown = <String, String>{};
    final unmatched = <String>[];
    error.fields.forEach((name, message) {
      final field = fieldFor(name);
      if (fieldNames.contains(field)) {
        // Several fields of the server may be shown at one place, e.g. the rows of a list.
        final earlier = shown[field];
        shown[field] = earlier == null ? message : '$earlier $message';
      } else {
        unmatched.add(message);
      }
    });
    errors = shown;
    if (!error.isValidation) {
      formError = error.message;
    } else {
      formError = unmatched.isEmpty ? null : unmatched.join(' ');
    }
  }
}
