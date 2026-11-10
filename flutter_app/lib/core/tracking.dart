/// Tracking-code normalization, mirroring the backend rules so users get instant feedback.
/// The server remains the authority: it normalizes and validates every code again.
library;

import 'format.dart';

final RegExp _dashVariants = RegExp('[\u2010-\u2015\u2212]');
final RegExp _invisible = RegExp('[\\s\u200b-\u200f\u2060\ufeff]');
final RegExp _fullWidth = RegExp('[\uff01-\uff5e]');

/// The rules the server announces in `app_settings.tracking_code`.
class TrackingCodeRules {
  const TrackingCodeRules({
    this.minLength = 6,
    this.maxLength = 64,
    this.pattern = r'^[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?$',
  });

  final int minLength;
  final int maxLength;
  final String pattern;
}

/// Upper case, Latin digits, plain hyphens and no spaces: the shape in which codes are stored.
String normalizeTrackingCode(String? raw) {
  final text = (raw ?? '')
      // Full-width letters and digits (typed with an East Asian keyboard) → their ASCII forms.
      .replaceAllMapped(_fullWidth, (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xfee0));
  return toLatinDigits(text).replaceAll(_dashVariants, '-').replaceAll(_invisible, '').toUpperCase();
}

/// Returns a Persian error message, or `null` when the (already normalized) code is acceptable.
String? trackingCodeProblem(String code, [TrackingCodeRules rules = const TrackingCodeRules()]) {
  if (code.isEmpty) return 'کد رهگیری را وارد کنید.';
  if (code.length < rules.minLength) return 'کد رهگیری باید دست‌کم ${toPersianDigits(rules.minLength)} نویسه باشد.';
  if (code.length > rules.maxLength) return 'کد رهگیری نباید بیشتر از ${toPersianDigits(rules.maxLength)} نویسه باشد.';
  final RegExp pattern;
  try {
    pattern = RegExp(rules.pattern);
  } on FormatException {
    return null; // a pattern this client cannot read: leave the decision to the server
  }
  if (!pattern.hasMatch(code)) {
    return 'کد رهگیری فقط می‌تواند شامل حروف انگلیسی، رقم و خط تیره باشد و نباید با خط تیره شروع یا تمام شود.';
  }
  return null;
}
