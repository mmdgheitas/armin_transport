import 'package:armin_transport/core/config.dart';
import 'package:flutter_test/flutter_test.dart';

String? urlOf(String input, {bool httpsOnly = false}) => ServerAddress.parse(input, httpsOnly: httpsOnly).baseUrl;

String? problemOf(String input, {bool httpsOnly = false}) => ServerAddress.parse(input, httpsOnly: httpsOnly).problem;

void main() {
  test('completes an address to the API base URL', () {
    const cases = {
      'example.com': 'https://example.com/api/v1',
      '  example.com  ': 'https://example.com/api/v1',
      'https://example.com': 'https://example.com/api/v1',
      'https://example.com/': 'https://example.com/api/v1',
      'https://example.com/api/v1': 'https://example.com/api/v1',
      'https://example.com/api/v1///': 'https://example.com/api/v1',
      'https://example.com/api/v2': 'https://example.com/api/v2',
      'https://example.com/armin': 'https://example.com/armin/api/v1',
      'https://example.com/armin/api/v1/': 'https://example.com/armin/api/v1',
      'HTTPS://Example.COM': 'https://example.com/api/v1',
      'example.com:8443': 'https://example.com:8443/api/v1',
      'https://example.com:443': 'https://example.com/api/v1',
      'https://192.0.2.10': 'https://192.0.2.10/api/v1',
    };
    cases.forEach((input, expected) {
      final address = ServerAddress.parse(input, httpsOnly: false);
      expect(address.baseUrl, expected, reason: input);
      expect(address.problem, isNull, reason: input);
      expect(address.isValid, isTrue);
      expect(address.isInsecure, isFalse);
    });
  });

  test('accepts plain HTTP only inside a local network', () {
    const local = {
      'http://localhost:5000': 'http://localhost:5000/api/v1',
      'http://127.0.0.1:5000/': 'http://127.0.0.1:5000/api/v1',
      'http://10.0.2.2:5000': 'http://10.0.2.2:5000/api/v1', // the host machine, seen from the Android emulator
      'http://192.168.1.10': 'http://192.168.1.10/api/v1',
      'http://172.16.0.1': 'http://172.16.0.1/api/v1',
      'http://172.31.255.254': 'http://172.31.255.254/api/v1',
      'http://169.254.10.10': 'http://169.254.10.10/api/v1',
      'http://server': 'http://server/api/v1',
      'http://armin-pc:8080/api/v1': 'http://armin-pc:8080/api/v1',
      'http://nas.local': 'http://nas.local/api/v1',
      'http://armin.lan': 'http://armin.lan/api/v1',
      'http://transport.internal': 'http://transport.internal/api/v1',
      'http://box.home.arpa': 'http://box.home.arpa/api/v1',
      'http://app.localhost:3000': 'http://app.localhost:3000/api/v1',
      'http://[::1]:5000': 'http://[::1]:5000/api/v1',
      'http://[fd12:3456::1]': 'http://[fd12:3456::1]/api/v1',
      'http://[fe80::1]': 'http://[fe80::1]/api/v1',
    };
    local.forEach((input, expected) {
      final address = ServerAddress.parse(input, httpsOnly: false);
      expect(address.baseUrl, expected, reason: input);
      expect(address.isInsecure, isTrue, reason: input);
    });

    for (final public in [
      'http://example.com',
      'http://www.example.ir/api/v1',
      'http://8.8.8.8',
      'http://172.32.0.1',
      'http://172.15.0.1',
      'http://192.169.1.1',
      'http://11.0.0.1',
      'http://256.1.1.1',
      'http://[2001:db8::1]',
      'http://localhost.example.com',
    ]) {
      expect(urlOf(public), isNull, reason: public);
      expect(problemOf(public), contains('https'), reason: public);
    }
  });

  test('a build that requires HTTPS refuses every plain address', () {
    expect(urlOf('http://192.168.1.10', httpsOnly: true), isNull);
    expect(problemOf('http://localhost:5000', httpsOnly: true), contains('https'));
    expect(urlOf('https://192.168.1.10', httpsOnly: true), 'https://192.168.1.10/api/v1');
    expect(urlOf('example.com', httpsOnly: true), 'https://example.com/api/v1');
  });

  test('explains what is wrong with an address', () {
    expect(problemOf(''), contains('وارد کنید'));
    expect(problemOf('   '), contains('وارد کنید'));
    expect(problemOf('exa mple.com'), contains('فاصله'));
    for (final invalid in ['ftp://example.com', 'https://', 'https:///path', 'https://example.com:port', '://x']) {
      expect(urlOf(invalid), isNull, reason: invalid);
      expect(problemOf(invalid), contains('معتبر نیست'), reason: invalid);
    }
    for (final extra in ['https://user:secret@example.com', 'https://example.com/?x=1', 'https://example.com/#top']) {
      expect(urlOf(extra), isNull, reason: extra);
      expect(problemOf(extra), contains('نباید'), reason: extra);
    }
  });

  test('shows the host of an address', () {
    String hostOf(String input) => ServerAddress.parse(input, httpsOnly: false).displayHost;
    expect(hostOf('https://example.com/api/v1'), 'example.com');
    expect(hostOf('http://192.168.1.10:5000'), '192.168.1.10:5000');
    expect(hostOf('http://[::1]:5000'), '[::1]:5000');
    expect(hostOf(''), '');
  });

  test('recognises hosts of a local network', () {
    for (final host in [
      'localhost',
      'LOCALHOST',
      '10.1.2.3',
      '192.168.0.1',
      '::1',
      'fd00::1',
      'printer',
      'local', // a single-label name like any other
      'a.local',
    ]) {
      expect(isLocalNetworkHost(host), isTrue, reason: host);
    }
    for (final host in ['example.com', '1.1.1.1', '2606:4700::1111', 'a_b', 'local.example.com', '']) {
      expect(isLocalNetworkHost(host), isFalse, reason: host);
    }
  });
}
