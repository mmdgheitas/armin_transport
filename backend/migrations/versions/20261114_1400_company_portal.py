"""Shared staff and company-scoped business activity.

Revision ID: company_portal
Revises: customer_accounts
"""

import uuid

import sqlalchemy as sa
from alembic import op

revision = "company_portal"
down_revision = "customer_accounts"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("users") as batch:
        batch.drop_constraint(op.f("ck_users_role_company_consistency"), type_="check")
        batch.create_check_constraint(
            "role_company_consistency",
            "(role = 'SUPER_ADMIN' AND company_id IS NULL) OR role = 'EMPLOYEE' OR "
            "(role = 'CUSTOMER' AND company_id IS NOT NULL)",
        )
    with op.batch_alter_table("audit_logs") as batch:
        batch.add_column(sa.Column("company_id", sa.Uuid(), nullable=True))
        batch.create_foreign_key(
            "fk_audit_logs_company_id_companies", "companies", ["company_id"], ["id"], ondelete="RESTRICT"
        )
        batch.create_index("ix_audit_logs_company_id", ["company_id"])
    # Backfill historical company, shipment and document actions from stable entities.
    connection = op.get_bind()
    metadata = sa.MetaData()
    logs = sa.Table("audit_logs", metadata, autoload_with=connection)
    companies = sa.Table("companies", metadata, autoload_with=connection)
    shipments = sa.Table("shipments", metadata, autoload_with=connection)
    documents = sa.Table("documents", metadata, autoload_with=connection)
    company_map = {str(row.id).replace("-", ""): row.id for row in connection.execute(sa.select(companies.c.id))}
    shipment_map = {
        str(row.id).replace("-", ""): row.company_id
        for row in connection.execute(sa.select(shipments.c.id, shipments.c.company_id))
    }
    document_map = {
        str(row.id).replace("-", ""): shipment_map.get(str(row.shipment_id).replace("-", ""))
        for row in connection.execute(sa.select(documents.c.id, documents.c.shipment_id))
    }
    mappings = {"company": company_map, "shipment": shipment_map, "document": document_map}
    for row in connection.execute(sa.select(logs.c.id, logs.c.entity_type, logs.c.entity_id)).all():
        try:
            key = uuid.UUID(str(row.entity_id)).hex
        except (ValueError, TypeError):
            continue
        company_id = mappings.get(row.entity_type, {}).get(key)
        if company_id:
            connection.execute(logs.update().where(logs.c.id == row.id).values(company_id=company_id))


def downgrade():
    connection = op.get_bind()
    if connection.scalar(sa.text("SELECT COUNT(*) FROM users WHERE role = 'EMPLOYEE' AND company_id IS NULL")):
        raise RuntimeError("Assign companies to staff before downgrading.")
    with op.batch_alter_table("audit_logs") as batch:
        batch.drop_index("ix_audit_logs_company_id")
        batch.drop_constraint("fk_audit_logs_company_id_companies", type_="foreignkey")
        batch.drop_column("company_id")
    with op.batch_alter_table("users") as batch:
        batch.drop_constraint(op.f("ck_users_role_company_consistency"), type_="check")
        batch.create_check_constraint(
            "role_company_consistency",
            "(role = 'SUPER_ADMIN' AND company_id IS NULL) OR "
            "(role IN ('EMPLOYEE', 'CUSTOMER') AND company_id IS NOT NULL)",
        )
