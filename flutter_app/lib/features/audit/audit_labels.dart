/// Persian names for what the audit log records. Pure data, no widgets.
library;

/// The names of the actions the server records. An action that is not listed is shown as the server names it.
const Map<String, String> auditActionLabels = {
  'LOGIN_SUCCESS': 'ورود موفق',
  'LOGIN_FAILED': 'ورود ناموفق',
  'LOGIN_BLOCKED': 'ورود مسدودشده',
  'LOGOUT': 'خروج',
  'PASSWORD_CHANGED': 'تغییر رمز عبور',
  'PASSWORD_CHANGE_FAILED': 'تلاش ناموفق برای تغییر رمز',
  'REFRESH_TOKEN_REUSE_DETECTED': 'استفادهٔ دوباره از توکن نوسازی',
  'ACCESS_DENIED': 'دسترسی غیرمجاز',
  'ADMIN_CREATED': 'ایجاد مدیر مرکزی',
  'COMPANY_CREATED': 'ایجاد شرکت',
  'COMPANY_UPDATED': 'ویرایش شرکت',
  'COMPANY_ACTIVATED': 'فعال‌سازی شرکت',
  'COMPANY_DEACTIVATED': 'غیرفعال‌سازی شرکت',
  'USER_CREATED': 'ایجاد کارمند',
  'USER_UPDATED': 'ویرایش کارمند',
  'USER_ACTIVATED': 'فعال‌سازی کارمند',
  'USER_DEACTIVATED': 'غیرفعال‌سازی کارمند',
  'USER_PASSWORD_RESET': 'بازنشانی رمز کارمند',
  'SHIPMENT_CREATED': 'ثبت محموله',
  'SHIPMENT_UPDATED': 'ویرایش محموله',
  'SHIPMENT_ARCHIVED': 'بایگانی محموله',
  'SHIPMENT_UNARCHIVED': 'خروج محموله از بایگانی',
  'TRACKING_CODE_CHANGED': 'تغییر کد رهگیری',
  'PRODUCT_VALUES_UPDATED': 'ویرایش مشخصات کالا',
  'PRODUCT_FIELD_CREATED': 'تعریف فیلد',
  'PRODUCT_FIELD_UPDATED': 'ویرایش فیلد',
  'DOCUMENT_UPLOADED': 'بارگذاری سند',
  'DOCUMENT_UPLOAD_REJECTED': 'رد شدن بارگذاری سند',
  'DOCUMENT_DOWNLOADED': 'دریافت سند',
  'DOCUMENT_VISIBILITY_CHANGED': 'تغییر نمایش سند به مشتری',
  'DOCUMENT_DELETED': 'حذف سند',
  'DOCUMENT_INTEGRITY_FAILURE': 'خطای یکپارچگی فایل سند',
  'CUSTOMER_LOOKUP_SUCCESS': 'رهگیری موفق مشتری',
  'CUSTOMER_LOOKUP_FAILED': 'رهگیری ناموفق مشتری',
  'CUSTOMER_DOCUMENT_DOWNLOADED': 'دریافت سند توسط مشتری',
  'CUSTOMER_SESSIONS_REVOKED': 'لغو دسترسی مشتریان',
};

/// The names of the kinds of things an action is about.
const Map<String, String> auditEntityLabels = {
  'user': 'کاربر',
  'company': 'شرکت',
  'shipment': 'محموله',
  'document': 'سند',
  'product_field_definition': 'فیلد محموله',
};

/// Actions that deserve a second look: refusals, failures and signs of misuse.
const Set<String> auditWarningActions = {
  'LOGIN_FAILED',
  'LOGIN_BLOCKED',
  'PASSWORD_CHANGE_FAILED',
  'REFRESH_TOKEN_REUSE_DETECTED',
  'ACCESS_DENIED',
  'DOCUMENT_UPLOAD_REJECTED',
  'DOCUMENT_INTEGRITY_FAILURE',
  'CUSTOMER_LOOKUP_FAILED',
};

String auditActionLabel(String action) => auditActionLabels[action] ?? action;

String auditEntityLabel(String type) => auditEntityLabels[type] ?? type;
