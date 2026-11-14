# Company portal and staff document policy

## Accounts and ownership

- POST /api/v1/companies requires `username` and `password` in addition to the
  company fields. The company and its CUSTOMER account are created atomically.
  The password policy applies; only its hash is stored. Credentials never appear
  in company responses, activity feeds or audit metadata.
- Each company signs in through the normal login page. Its dashboard, searchable
  shipment list, documents and work history are restricted to its own company.
- Staff accounts (EMPLOYEE) are shared operators across companies, not dedicated
  company accounts. New staff do not need a company_id. Existing assignments are
  retained for compatibility but do not constrain staff scope or login.
- Only administrators can create/update companies or manage user accounts.
  SUPER_ADMIN creation remains CLI-only. Company passwords can be reset using
  the existing administrator user-management password reset action.
- Existing companies are not given generated or shared passwords. Administrators
  must create CUSTOMER accounts for them through /users with their company_id.

## Work history

- Business audit entries carry a stable company_id resolved from the affected
  company, shipment or document, not from the employee's old company assignment.
- GET /companies/{id}/activity returns successful company/shipment/document work,
  actor name and timestamp. Administrators can view every company's history;
  customers only their own. Staff cannot use this feed to inspect others' files.
- Customer history omits security logs, IP addresses, request identifiers, login
  names and private audit metadata. Administrators retain the full /audit-logs
  endpoint, including a company_id filter.
- Company list/detail and the company dashboard expose last_activity. Existing
  company/shipment/document events are backfilled by the migration.

## Tracking and files

- No tracking links are shown before login. The default guest page is login.
  All tracking endpoints require a bearer login, even legacy opaque-token routes.
  A code or customer token alone never grants access.
- Employees only list/download/update their own files. Counts are scoped too.
  The legacy customer portal cannot bypass employee document isolation.
- Each employee can store 12 non-deleted files per shipment across requests.
  MySQL uses a shipment row lock; SQLite rolls back and retries snapshot conflicts. Deletion frees a slot.
  Administrators see all files; customers see all files of their own shipments.
- Each request accepts up to 12 files. No application-level type or size limit
  applies. Streaming storage, checksums, safe filenames, optional malware scanning
  and attachment-only downloads remain enabled. Infrastructure may impose limits.
- The old customer visibility flag is compatibility-only, not an access rule.

## Deployment and verification

Back up the database, then run `flask --app wsgi db upgrade` from backend with
normal deployment environment variables. The new migrations add CUSTOMER,
relax staff/company coupling, add the audit company key and backfill history.
SQLite3 is the default production database (see README.md). SQLite batch migrations temporarily disable foreign-key enforcement outside the
transaction, validate the final foreign keys, then restore enforcement. Optional MySQL migration tests require a real MySQL server.

Verified on SQLite:
- test_company_portal.py, test_new_access_policy.py, test_migrations.py,
  test_audit_logs.py: 30 passed, including migration with pre-existing data.
- Ruff and strict mypy: passed.
- Web lint, 77 unit tests and production build: passed.

Other legacy tests still include superseded anonymous-tracking, file-type and
company-dedicated employee assumptions; the full suite has not been reconciled.
Flutter changes cover company credentials, shared staff, dashboard/history and
removal of public tracking. Flutter SDK/device tests were not available here.
