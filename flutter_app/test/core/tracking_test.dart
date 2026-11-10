import 'package:armin_transport/core/tracking.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes codes like the backend', () {
    const cases = <(String?, String)>[
      ('abcd-1234', 'ABCD-1234'),
      ('  ab cd\t12 34\n', 'ABCD1234'),
      ('۱۲۳۴-۵۶۷۸', '1234-5678'),
      ('٠١٢٣٤٥', '012345'),
      ('AB\u2013CD\u2014EF\u2212GH\u2010IJ', 'AB-CD-EF-GH-IJ'),
      ('AB\u200cCD\u200bEF\ufeff', 'ABCDEF'),
      ('ＡＢＣ１２３', 'ABC123'), // full-width forms
      ('ａｂ－ｃｄ', 'AB-CD'), // full-width small letters and hyphen
      ('', ''),
      (null, ''),
    ];
    for (final (input, expected) in cases) {
      expect(normalizeTrackingCode(input), expected, reason: '$input');
    }
  });

  test('reports problems in Persian and accepts valid codes', () {
    expect(trackingCodeProblem('ABCD-1234-EFGH-5678'), isNull);
    expect(trackingCodeProblem('ABC123'), isNull);
    expect(trackingCodeProblem(''), contains('وارد کنید'));
    expect(trackingCodeProblem('ABC'), contains('دست‌کم ۶ نویسه'));
    expect(trackingCodeProblem('A' * 65), contains('بیشتر از ۶۴ نویسه'));
    expect(trackingCodeProblem('-ABCDEF'), contains('خط تیره'));
    expect(trackingCodeProblem('ABCDEF-'), contains('خط تیره'));
    expect(trackingCodeProblem('ABC_DEF'), contains('حروف انگلیسی'));
    expect(trackingCodeProblem('کدفارسی'), contains('حروف انگلیسی'));
  });

  test('honours the limits announced by the server', () {
    const rules = TrackingCodeRules(minLength: 8, maxLength: 10, pattern: r'^[A-Z0-9]+$');
    expect(trackingCodeProblem('ABCDEFG', rules), contains('دست‌کم ۸ نویسه'));
    expect(trackingCodeProblem('ABCDEFGHIJK', rules), contains('بیشتر از ۱۰ نویسه'));
    expect(trackingCodeProblem('ABCD-EFGH', rules), contains('حروف انگلیسی'));
    expect(trackingCodeProblem('ABCDEFGH', rules), isNull);
  });

  test('leaves the decision to the server when it cannot read the announced pattern', () {
    const rules = TrackingCodeRules(pattern: '([A-Z');
    expect(trackingCodeProblem('ABC_DEF', rules), isNull);
  });
}
