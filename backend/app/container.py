"""Composition root: wires repositories and services together."""

from __future__ import annotations

from dataclasses import dataclass

from app.config import Settings
from app.core.rate_limit import RateLimiter
from app.core.security import PasswordService, TokenService
from app.extensions import db, scoped_db_session
from app.modules.audit_logs.service import AuditService
from app.modules.auth.service import AuthService
from app.modules.companies.repository import CompanyRepository
from app.modules.companies.service import CompanyService
from app.modules.customer_access.repository import CustomerSessionRepository
from app.modules.customer_access.service import CustomerAccessService
from app.modules.dashboard.service import DashboardService
from app.modules.documents.repository import DocumentRepository
from app.modules.documents.scanner import MalwareScanner
from app.modules.documents.service import DocumentService
from app.modules.documents.storage import DocumentStorage
from app.modules.product_fields.repository import ProductFieldRepository
from app.modules.product_fields.service import ProductFieldService, ProductValueManager
from app.modules.shipments.repository import ShipmentRepository
from app.modules.shipments.service import ShipmentService
from app.modules.shipments.tracking_codes import TrackingCodeGenerator
from app.modules.users.repository import UserRepository
from app.modules.users.service import UserService


@dataclass(frozen=True)
class Services:
    """Application services available to the HTTP layer and the CLI."""

    settings: Settings
    passwords: PasswordService
    rate_limiter: RateLimiter
    storage: DocumentStorage
    code_generator: TrackingCodeGenerator
    audit: AuditService
    auth: AuthService
    companies: CompanyService
    users: UserService
    shipments: ShipmentService
    documents: DocumentService
    product_fields: ProductFieldService
    customer_access: CustomerAccessService
    dashboard: DashboardService


def build_services(settings: Settings) -> Services:
    session = scoped_db_session()
    passwords = PasswordService(settings)
    tokens = TokenService(settings)
    rate_limiter = RateLimiter(lambda: db.engine, enabled=settings.rate_limit_enabled)
    storage = DocumentStorage(settings.storage_root)
    code_generator = TrackingCodeGenerator(settings)
    scanner = (
        MalwareScanner(settings.malware_scan_command, settings.malware_scan_timeout_seconds)
        if settings.malware_scan_command
        else None
    )

    user_repository = UserRepository(session)
    company_repository = CompanyRepository(session)
    shipment_repository = ShipmentRepository(session)
    document_repository = DocumentRepository(session)
    field_repository = ProductFieldRepository(session)
    customer_session_repository = CustomerSessionRepository(session)

    audit = AuditService(session)
    auth = AuthService(session, settings, passwords, tokens, rate_limiter, audit, user_repository)
    product_values = ProductValueManager(session, field_repository)
    shipments = ShipmentService(
        session,
        settings,
        audit,
        shipment_repository,
        company_repository,
        product_values,
        customer_session_repository,
        code_generator,
    )
    documents = DocumentService(session, settings, audit, storage, shipments, document_repository, scanner)
    return Services(
        settings=settings,
        passwords=passwords,
        rate_limiter=rate_limiter,
        storage=storage,
        code_generator=code_generator,
        audit=audit,
        auth=auth,
        companies=CompanyService(session, audit, company_repository),
        users=UserService(session, settings, passwords, audit, auth, user_repository, company_repository),
        shipments=shipments,
        documents=documents,
        product_fields=ProductFieldService(session, audit, field_repository),
        customer_access=CustomerAccessService(
            session,
            settings,
            rate_limiter,
            audit,
            customer_session_repository,
            shipment_repository,
            document_repository,
            documents,
            product_values,
        ),
        dashboard=DashboardService(session, shipments),
    )
