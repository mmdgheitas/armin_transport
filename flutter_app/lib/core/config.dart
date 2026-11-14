/// Build-time settings and the rules for the address of the server.
library;

/// The API address compiled into the app: `--dart-define=API_BASE_URL=https://example.com/api/v1`.
/// When it is empty the user is asked for the address on first start and can change it later.
const String compiledApiBaseUrl = String.fromEnvironment('API_BASE_URL');

/// `--dart-define=REQUIRE_HTTPS=true` refuses every plain-HTTP address, local networks included.
const bool requireHttps = bool.fromEnvironment('REQUIRE_HTTPS');

const String _apiPath = '/api/v1';

/// The outcome of checking an address typed by the user (or compiled in).
class ServerAddress {
  const ServerAddress._({this.baseUrl, this.problem});

  /// The normalized API base URL, e.g. `https://example.com/api/v1`; `null` when [problem] is set.
  final String? baseUrl;

  /// A Persian message for the user; `null` when the address is acceptable.
  final String? problem;

  bool get isValid => baseUrl != null;

  /// True when the connection is not encrypted (plain HTTP inside a local network).
  bool get isInsecure => baseUrl != null && baseUrl!.startsWith('http://');

  /// Host and port for display, e.g. `example.com`, `192.168.1.10:5000` or `[::1]:5000`.
  String get displayHost {
    final uri = Uri.tryParse(baseUrl ?? '');
    if (uri == null || uri.host.isEmpty) return '';
    final host = _hostForUrl(uri.host);
    return uri.hasPort ? '$host:${uri.port}' : host;
  }

  /// Accepts `example.com`, `https://example.com`, `https://example.com/api/v1`, `http://192.168.1.10:5000` …
  ///
  /// An address without a scheme is taken as HTTPS, and `/api/v1` is added unless the address already names the API.
  /// Plain HTTP is accepted only for hosts of the local network, and not at all with [httpsOnly].
  static ServerAddress parse(String input, {bool httpsOnly = requireHttps}) {
    var text = input.trim();
    if (text.isEmpty) return const ServerAddress._(problem: 'نشانی سرور را وارد کنید.');
    if (text.contains(RegExp(r'\s'))) return const ServerAddress._(problem: 'نشانی سرور نباید فاصله داشته باشد.');
    if (!text.contains('://')) text = 'https://$text';

    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return const ServerAddress._(problem: 'نشانی سرور معتبر نیست. نمونه: https://example.com');
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return const ServerAddress._(problem: 'نشانی سرور نباید نام کاربری، رمز یا پارامتر داشته باشد.');
    }
    if (uri.scheme == 'http') {
      if (httpsOnly) {
        return const ServerAddress._(problem: 'این نسخه فقط به نشانی‌های امن (https) وصل می‌شود.');
      }
      if (!isLocalNetworkHost(uri.host)) {
        return const ServerAddress._(
          problem:
              'برای سرورهای اینترنتی فقط نشانی امن (https) پذیرفته می‌شود. اتصال http تنها در شبکهٔ داخلی مجاز است.',
        );
      }
    }

    // The address of the site is enough: the API lives under it.
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (!RegExp(r'/api/v\d+$').hasMatch(path)) path = '$path$_apiPath';
    final authority = uri.hasPort ? '${_hostForUrl(uri.host)}:${uri.port}' : _hostForUrl(uri.host);
    return ServerAddress._(baseUrl: '${uri.scheme}://$authority$path');
  }
}

String _hostForUrl(String host) => host.contains(':') ? '[$host]' : host;

const List<String> _localSuffixes = ['.local', '.lan', '.internal', '.home.arpa', '.localhost'];

/// Loopback and private-network hosts: the only ones a plain-HTTP connection is accepted for.
bool isLocalNetworkHost(String rawHost) {
  final host = rawHost.toLowerCase();
  if (host == 'localhost' || _localSuffixes.any(host.endsWith)) return true;

  final parts = host.split('.');
  if (parts.length == 4 && parts.every((part) => RegExp(r'^\d{1,3}$').hasMatch(part))) {
    final numbers = parts.map(int.parse).toList();
    if (numbers.any((number) => number > 255)) return false;
    final a = numbers[0];
    final b = numbers[1];
    return a == 10 || a == 127 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254);
  }
  if (host.contains(':')) {
    // IPv6: loopback, unique local (fc00::/7) and link-local (fe80::/10) addresses.
    return host == '::1' || host.startsWith('fc') || host.startsWith('fd') || RegExp(r'^fe[89ab]').hasMatch(host);
  }
  // A name without dots ("server", "armin-pc") can only be resolved inside a local network.
  return !host.contains('.') && RegExp(r'^[a-z0-9-]+$').hasMatch(host);
}
