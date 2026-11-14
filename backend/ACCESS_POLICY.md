# Account and document access policy

- Administrators create EMPLOYEE or CUSTOMER accounts through POST /api/v1/users.
  Both must belong to a company; SUPER_ADMIN creation remains CLI-only.
- Customer ownership is company-based: a customer can read shipments and all
  non-deleted files belonging to the company assigned to their account.
- All tracking endpoints require a bearer login, including the legacy opaque-token
  endpoints. A tracking code or old customer token alone no longer grants access.
- Employees only list/download/update their own files. Counts are scoped too.
  Customer tracking endpoints cannot be used by employees to bypass isolation.
- Each employee may store 12 non-deleted files per shipment in total, across
  requests. Deletion frees a slot. A shipment row lock serializes quota checks on
  MySQL. Administrators see all files, with no employee cumulative quota.
- A request accepts at most 12 files. No application-level file size or file-type
  restriction applies. Streaming storage, checksums, filename sanitization,
  optional malware scanning and attachment-only downloads remain enabled.
  Infrastructure (reverse proxy, disk space, timeouts) may impose practical limits.
- The previous customer visibility flag is retained for API compatibility but
  no longer hides files from the owning customer.
- The web administrator shipment list starts with companies, then active company
  shipments, then shipment details and document metadata.

## Deployment

Back up the database, then run `flask --app wsgi db upgrade` from backend with
normal deployment environment variables. The new migration adds CUSTOMER to the
user role and adjusts the company constraint. Create customer accounts in the web
user panel and assign their companies. Existing employees are not auto-converted.
Remove reverse-proxy body-size limits if unrestricted uploads are required.

## Verification

`pytest tests/test_new_access_policy.py tests/test_migrations.py`: 8 passed on SQLite.
`ruff check backend`: passed. `npm run check` in web: passed (75 unit tests).
The legacy full backend suite includes expectations for anonymous tracking and
file-type rejection that conflict with this policy and still needs updating.
Flutter's upload-size check accepts the server's zero/unlimited policy; Flutter
UI parity and device tests have not been verified in this environment.
