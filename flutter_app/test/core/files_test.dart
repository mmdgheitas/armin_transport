import 'dart:convert';

import 'package:armin_transport/core/files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps ordinary names as they are', () {
    for (final name in ['بارنامه ۱.pdf', 'report-2026_11.final.xlsx', 'photo (1).jpg', 'console.txt', 'a']) {
      expect(safeFileName(name), name);
    }
  });

  test('never lets a name point outside the chosen folder', () {
    expect(safeFileName('../../etc/passwd'), '.._.._etc_passwd');
    expect(safeFileName(r'..\..\Windows\system32\drivers\etc\hosts'), '.._.._Windows_system32_drivers_etc_hosts');
    expect(safeFileName('/absolute/path.pdf'), '_absolute_path.pdf');
    expect(safeFileName(r'C:\Users\me\x.pdf'), 'C__Users_me_x.pdf');
    expect(safeFileName('a/b\\c:d*e?f"g<h>i|j.pdf'), 'a_b_c_d_e_f_g_h_i_j.pdf');
    expect(safeFileName('a\nb\tc\u0000d\u007f.pdf'), 'a_b_c_d_.pdf');
  });

  test('removes what Windows does not accept at the end of a name', () {
    expect(safeFileName('report.pdf. '), 'report.pdf');
    expect(safeFileName('  report.pdf  '), 'report.pdf');
    expect(safeFileName('report...'), 'report');
  });

  test('falls back when nothing usable is left', () {
    for (final name in ['', '   ', '...', '.', '___', '/', r'\\', '\u202e']) {
      expect(safeFileName(name), 'download', reason: name);
    }
    expect(safeFileName('', fallback: 'سند'), 'سند');
  });

  test('avoids the device names of Windows', () {
    expect(safeFileName('CON'), '_CON');
    expect(safeFileName('nul.txt'), '_nul.txt');
    expect(safeFileName('COM1.pdf'), '_COM1.pdf');
    expect(safeFileName('lpt9'), '_lpt9');
    expect(safeFileName('COM10.pdf'), 'COM10.pdf');
    expect(safeFileName('contract.pdf'), 'contract.pdf');
  });

  test('removes direction marks, so that the real extension stays visible', () {
    // With a right-to-left override this name would be displayed as "invoiceexe.pdf".
    expect(safeFileName('invoice\u202efdp.exe'), 'invoicefdp.exe');
    expect(safeFileName('\u2066بارنامه.pdf\u2069'), 'بارنامه.pdf');
    expect(safeFileName('a\u200fb\u200e\u061c.pdf'), 'ab.pdf');
  });

  test('shortens very long names and keeps the extension', () {
    final latin = safeFileName('${'x' * 300}.pdf');
    expect(latin.length, 120);
    expect(latin, endsWith('.pdf'));
    expect(safeFileName('x' * 300).length, 120);
    // What follows the last dot is not an extension when it is this long.
    expect(safeFileName('${'a' * 100}.${'b' * 100}'), '${'a' * 100}.${'b' * 19}');
    // Shortening never leaves a name that ends in a dot or a space.
    expect(safeFileName('${'a' * 119}. ${'b' * 100}'), 'a' * 119);
  });

  test('keeps long names within the byte limit of Android file systems', () {
    // Persian letters take two bytes each in UTF-8, the zero-width non-joiner three.
    final persian = safeFileName('${'ب' * 300}.pdf');
    expect(persian, '${'ب' * 98}.pdf');
    expect(utf8.encode(persian).length, 200);

    final joined = safeFileName('${'می\u200cشود' * 60}.pdf');
    expect(utf8.encode(joined).length, lessThanOrEqualTo(200));
    expect(joined, endsWith('.pdf'));

    // A character outside the basic plane is two UTF-16 units; it is kept whole or left out.
    final emoji = safeFileName('${'\u{1F600}' * 100}.pdf');
    expect(emoji, '${'\u{1F600}' * 49}.pdf');
    expect(utf8.decode(utf8.encode(emoji)), emoji);
  });
}
