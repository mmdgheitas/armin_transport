/// The one error type of the API layer: every failure carries a Persian message that can be shown as it is.
library;

const String networkErrorMessage = 'ارتباط با سرور برقرار نشد. اتصال اینترنت خود را بررسی و دوباره تلاش کنید.';
const String unexpectedResponseMessage = 'پاسخ نامعتبری از سرور دریافت شد. لطفاً دوباره تلاش کنید.';
const String sessionEndedMessage = 'نشست شما به پایان رسیده است. لطفاً دوباره وارد شوید.';

class ApiError implements Exception {
  ApiError({
    this.status = 0,
    this.code = 'unknown_error',
    this.message = unexpectedResponseMessage,
    Map<String, dynamic>? details,
  }) : details = details ?? const <String, dynamic>{};

  factory ApiError.network() => ApiError(code: 'network_error', message: networkErrorMessage);

  /// HTTP status, or 0 when no response arrived.
  final int status;

  /// Machine-readable reason, e.g. `invalid_credentials`, `token_expired`, `network_error`.
  final String code;

  final String message;

  /// The `errors` object of the response envelope.
  final Map<String, dynamic> details;

  bool get isNetworkError => code == 'network_error';
  bool get isValidation => status == 422;
  bool get isNotFound => status == 404;
  bool get isForbidden => status == 403;

  String? get requestId => details['request_id'] is String ? details['request_id'] as String : null;

  int? get retryAfterSeconds => details['retry_after_seconds'] is int ? details['retry_after_seconds'] as int : null;

  /// Per-field validation messages: `{ field_name: "message message" }`.
  Map<String, String> get fields {
    final raw = details['fields'];
    if (raw is! Map) return const <String, String>{};
    final result = <String, String>{};
    raw.forEach((key, value) {
      result[key.toString()] = value is List ? value.map((item) => item.toString()).join(' ') : value.toString();
    });
    return result;
  }

  @override
  String toString() {
    final cause = details['cause'];
    return 'ApiError($status, $code): $message${cause == null ? '' : ' [$cause]'}';
  }
}
