"""Operational command-line interface (``flask <command>``)."""

from __future__ import annotations

import json
import os
import secrets
from pathlib import Path

import click
from flask import Flask

from app.container import Services
from app.core.errors import AppError
from app.core.openapi import build_openapi_document
from app.extensions import scoped_db_session
from app.modules.users.repository import UserRepository
from app.seeds import seed_demo_data

ADMIN_PASSWORD_ENV = "ADMIN_PASSWORD"  # noqa: S105 - name of an environment variable
DEMO_PASSWORD_ENV = "DEMO_PASSWORD"  # noqa: S105 - name of an environment variable


def _services(app: Flask) -> Services:
    services: Services = app.extensions["services"]
    return services


def _fail(error: AppError) -> click.ClickException:
    details = error.details.get("fields")
    suffix = f" {json.dumps(details, ensure_ascii=False)}" if details else ""
    return click.ClickException(f"{error.message}{suffix}")


def register_cli(app: Flask) -> None:
    @app.cli.command("create-admin")
    @click.option("--username", required=True, help="Login name of the new central administrator.")
    @click.option("--full-name", required=True, help="Display name.")
    @click.option(
        "--password",
        default=None,
        help=f"Password. Prefer the {ADMIN_PASSWORD_ENV} environment variable or the interactive prompt.",
    )
    def create_admin(username: str, full_name: str, password: str | None) -> None:
        """Create a SUPER_ADMIN account."""
        password = password or os.environ.get(ADMIN_PASSWORD_ENV)
        if not password:
            password = click.prompt("Password", hide_input=True, confirmation_prompt=True)
        try:
            user = _services(app).users.create_super_admin(username, full_name, password)
        except AppError as error:
            raise _fail(error) from error
        click.echo(f"Created SUPER_ADMIN '{user.username}' ({user.id}).")

    @app.cli.command("seed-demo")
    @click.option(
        "--password",
        default=None,
        help=f"Password for all demo accounts (or {DEMO_PASSWORD_ENV}); generated randomly when omitted.",
    )
    def seed_demo(password: str | None) -> None:
        """Insert demo companies, employees, product fields and shipments (non-production only)."""
        services = _services(app)
        if services.settings.is_production:
            raise click.ClickException("Demo data must not be seeded in production.")
        password = password or os.environ.get(DEMO_PASSWORD_ENV)
        generated = password is None
        if password is None:
            password = secrets.token_urlsafe(12)
        try:
            report = seed_demo_data(services, UserRepository(scoped_db_session()), password)
        except AppError as error:
            raise _fail(error) from error
        click.echo(
            f"Seeded {report.companies} companies, {report.product_fields} product fields, "
            f"{report.shipments} shipments."
        )
        click.echo(f"Administrator: {report.admin_username}")
        if report.employee_usernames:
            click.echo("Employees: " + ", ".join(report.employee_usernames))
        if report.tracking_codes:
            click.echo("Sample tracking codes: " + ", ".join(report.tracking_codes[:3]))
        if generated:
            click.echo(f"Generated password for new demo accounts: {password}")

    @app.cli.command("purge-expired")
    def purge_expired() -> None:
        """Delete expired refresh tokens, customer sessions, rate-limit counters and stale temp files."""
        services = _services(app)
        refresh_tokens = services.auth.purge_expired()
        customer_sessions = services.customer_access.purge_expired()
        counters = services.rate_limiter.purge_expired()
        temp_files = services.storage.purge_stale_temp_files()
        click.echo(
            f"Removed {refresh_tokens} refresh tokens, {customer_sessions} customer sessions, "
            f"{counters} rate-limit counters, {temp_files} temporary files."
        )

    @app.cli.command("export-openapi")
    @click.option("--output", type=click.Path(dir_okay=False, path_type=Path), default=None)
    def export_openapi(output: Path | None) -> None:
        """Write the OpenAPI document to a file (or standard output)."""
        document = json.dumps(build_openapi_document(app), ensure_ascii=False, indent=2) + "\n"
        if output is None:
            click.echo(document, nl=False)
            return
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(document, encoding="utf-8")
        click.echo(f"Wrote {output}")
