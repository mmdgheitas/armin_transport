# Transport workspace

The new web and Flutter navigation uses `/dashboard`, `/transport`, `/companies`,
`/companies/:companyId`, `/employees`, and `/loads/:id`. The admin home contains
exactly five launch tiles: Transport Control and four intentionally blank,
inactive tiles. Employees and customers open directly into their accessible loads.
The previous sidebar/navigation implementations are commented out; the previous
screens and backend APIs remain available in source.

## Setup

Run the normal migration command before deploying the new clients:

```sh
cd backend
flask --app wsgi db upgrade
```

Migration `transport_workspace` adds country metadata, assignments, load configuration,
and a binary-compared TEXT shipment code. It does not delete or convert existing
business records. New transport endpoints list only newly configured transport loads;
legacy records retain their legacy backend workflows. Use a fresh database for the
new deployment, as agreed; never delete an existing database automatically.

This migration targets the project's default SQLite deployment. Optional MySQL
migration compatibility has not been validated (in particular TEXT unique indexing
and binary collation); do not apply it to MySQL without an engine-specific review.

## Workflow and access

* Admin creates a company using just its name, then defines credentials separately.
* Admin creates employees with full name, username, password and one country.
* Inside a company, admin enters the unique manual code verbatim, selects countries,
  truck/border counts, per-person upload capacity and matching employees.
* Code comparison includes case and whitespace; the transport workflow does not
  generate, uppercase, trim or length-limit codes. Admin can edit the current code.
* Employees see assigned loads and only their own files. Their country determines
  the upload tab, even if a caller submits a different country.
* Each employee has the configured capacity. Each admin has a separate row with
  that capacity in each enabled country. Counts are unrelated to trucks/borders.
* Customers see only their company's loads, grouped files and download controls.
* Files use the existing unrestricted-format storage pipeline. No file-size limit
  is introduced by this workspace. Deployment proxy limits must be configured
  consistently if large uploads are needed.
* `/transport/...` provides the new workspace API. Protected downloads continue
  through `/documents/:id/download`; assignment checks apply to transport documents
  even through retained legacy document endpoints.

## Verification

Backend workflow tests cover company/account creation, assignment validation, exact
codes (including long Unicode/multiline values), country routing, per-user and
per-country capacity, employee privacy and customer tenant isolation. Migration
round-trip tests include the new table. Web checks run lint, unit tests and build.
Flutter SDK is not installed in the coding environment: Flutter source changes
require `flutter analyze`, `flutter test` and device/browser smoke testing before
release. Existing legacy navigation tests may need their expectations updated to
the new transport-only route table.

## Default server and form limits

Flutter now starts with `http://back.reservira.ir/api/v1` when there is no saved
address. Changing the server from the login screen saves the override for later
launches. This default does **not** lock server selection. An explicitly supplied
`API_BASE_URL` build override retains its existing fixed-server behavior.
Both HTTP and HTTPS are accepted for public and private hosts; the former
`REQUIRE_HTTPS` flag no longer rejects HTTP URLs. Invalid/non-HTTP URL syntax is
still rejected. HTTP transmits credentials and files without transport encryption.

Web defaults to the same API URL in `web/src/js/config.js`; edit this config or
build with `API_BASE_URL` to change it. The built config remains editable without
rebuilding. When changing to another origin, update the hosting CSP and backend
CORS configuration as appropriate. Browsers can block HTTP APIs from HTTPS pages
(mixed content); this cannot be disabled in application JavaScript.

Transport forms display the existing field limits: company/full name 1–200
characters, username 3–100 using English letters/digits/dot/hyphen/underscore,
and new passwords from the server-configured minimum (default 10) to 128,
without containing the username. Login accepts existing passwords of 1–128.
Manual shipment codes remain nonempty with no maximum length, preserving exact
case and whitespace. No new file type or size restrictions were added.

## Recoverable CRUD

Run `flask --app wsgi db upgrade` to apply the additive `transport_crud`
migration before starting this version. Company, user and shipment rows receive
nullable deletion timestamps; no existing rows or uploaded files are removed.

Both web and Flutter now expose:

| Resource | Edit | Soft deletion / recovery |
| --- | --- | --- |
| Company | Name | Admin; deleted-company list with Restore |
| Company login | Username and optional new password | Admin; restore from company page |
| Employee | Full name, username, optional password, country | Admin; deleted-employee list with Restore |
| Shipment | Exact manual code, countries, truck/border counts, per-person quota, assignments | Admin; deleted-load list within the company |
| File | Rename or replace content in the same slot | Owner employee or admin may delete; admin may restore |

The file uploader, country and file ID do not change when replacing content,
so replacement works even when the uploader's quota is full. Old content stays
private on disk; there is no user-facing version-history feature. Renaming is
limited to 1–255 characters and uses the existing filename sanitizer.

New routes use GET/PATCH/DELETE on `/transport/companies/:id`,
`/transport/employees/:id`, `/transport/companies/:id/account`,
`/transport/shipments/:id`, and `/transport/files/:id`. POST `.../restore`
recovers deleted records; POST `/transport/files/:id/replace` accepts exactly
one multipart `files` part. List queries use `deleted=true` for admin trash views.
Shipment editing submits the complete load configuration; company ownership is
immutable. Blank password fields in clients mean "leave password unchanged".

Deleting a company hides its loads and blocks their downloads without deleting
its children. Restoring it reveals only children that were not independently
deleted. Deleted user accounts cannot authenticate and their tokens are revoked.
Deleted shipment codes and usernames stay reserved so restoration cannot collide
with newly created records. Deleted-file recovery checks the current countries,
assignment and per-uploader/country capacity. Parent company/load must be restored
before child files are available. File content is not purged for transport soft
deletes, regardless of the legacy purge-on-delete setting.

Edits are rejected rather than silently removing/moving files when removing a
country or assignee that has active files, lowering a quota below the active file
count, or changing an employee country inconsistently with existing files or
assignments. Password and profile changes commit atomically. Retained legacy
load mutation endpoints enforce admin-only editing for transport loads too.

Verification includes backend CRUD/privacy/quota/recovery tests, migration
round trips and a real Chromium + Gunicorn + SQLite UI journey. Flutter CRUD
widget tests were added but cannot be executed here without the Flutter SDK.
The existing legacy Flutter navigation/UI test suite still describes the old
screens and needs adaptation when running the complete suite.
