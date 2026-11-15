# Armin Transport backend — SQLite3

SQLite is the default database in development and production. Python includes
its `sqlite3` driver; no MySQL service or credentials are needed. Existing MySQL
support is optional (`pip install -r requirements-mysql.txt`).

## Local setup

From the repository root:

```sh
python -m venv .venv
. .venv/bin/activate
pip install -r backend/requirements.txt
cp backend/.env.example backend/.env
cd backend
flask --app wsgi db upgrade
flask --app wsgi create-admin --help
flask --app wsgi run --host 0.0.0.0 --port 8000
```

Use the `create-admin` command to create your first administrator; the command
prompts for credentials (see its help). There are no default production passwords.

If `DATABASE_URL` is unset the file is
`backend/instance/armin_transport.sqlite3`, independent of the shell's working
directory. The sample `sqlite:///armin_transport.sqlite3` is also resolved under
Flask's private `backend/instance` directory. That directory is excluded from Git.
Schema changes are applied with Alembic, not by deleting/recreating the database.

## Production

Use a persistent **local** disk, not an NFS/network share or an ephemeral
container filesystem. Set these environment variables (or edit `backend/.env`):

```dotenv
APP_ENV=production
DATABASE_URL=sqlite:////var/lib/armin-transport/armin_transport.sqlite3
STORAGE_ROOT=/var/lib/armin-transport/storage
# Set JWT_SECRET_KEY to your own random secret of at least 32 characters.
```

Generate a secret with `python -c "import secrets; print(secrets.token_urlsafe(48))"`.
Create `/var/lib/armin-transport` and grant the application user write access
before running migrations. The parent directory must be writable too: SQLite
creates `-wal` and `-shm` files next to the database. The application only creates
its default instance directory, not arbitrary configured database directories.
Production rejects in-memory and relative-path SQLite URLs.

Run `flask --app wsgi db upgrade`, create the administrator, and serve using
`gunicorn -c gunicorn.conf.py wsgi:app` behind HTTPS/reverse proxy. Gunicorn now
defaults to one worker and four threads. SQLite supports concurrent readers but
only one writer; monitor write contention before increasing concurrency.

Every connection enables foreign keys, WAL mode, a 30-second busy timeout, full
synchronous durability and explicit transactions/SAVEPOINT support. On SQLite,
uncommitted API requests with transient lock/snapshot conflicts are retried from
a fresh transaction, including authentication and quota validation. Uploaded
streams are rewound and failed file writes compensated. Requests that have
already committed are **not** replayed. Retries are bounded; persistent failures
return 503 rather than bypassing limits or integrity checks.

## Existing databases and backups

Changing `DATABASE_URL` selects another database. It does **not** move existing
MySQL records to SQLite. Back up the old database and document storage before
switching. If you need to retain MySQL data, do a separate, validated data import
before pointing live traffic at SQLite; do not assume the empty SQLite schema
contains the old data. Uploaded documents still live under `STORAGE_ROOT`.

For a consistent live SQLite backup use its backup API:

```python
import sqlite3

with sqlite3.connect("/var/lib/armin-transport/armin_transport.sqlite3") as source:
    with sqlite3.connect("/backups/armin_transport.sqlite3") as destination:
        source.backup(destination)
```

Back up private document storage too, coordinated with database backups. Never
copy just the `.sqlite3` file while the application is writing in WAL mode, and
never delete its `-wal` or `-shm` files while running. Alternatively stop all app
processes before making a filesystem backup.

## Tests

```sh
pip install -r requirements-dev.txt
pytest tests/test_sqlite_deployment.py tests/test_config.py \
  tests/test_company_portal.py tests/test_new_access_policy.py \
  tests/test_migrations.py tests/test_audit_logs.py tests/test_rate_limiter.py
ruff check .
mypy
```

Tests use a separate temporary SQLite database, never `DATABASE_URL`.
`TEST_DATABASE_URL` overrides the **test** database only; never set it to live data.
The web browser-test harness also defaults to a disposable SQLite database and
runs migrations and Gunicorn against it. CI no longer requires a MySQL service.
Some older business-policy tests still expect the superseded anonymous tracking,
file-type restrictions and company-dedicated staff behavior and need updating.
