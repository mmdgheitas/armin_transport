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
