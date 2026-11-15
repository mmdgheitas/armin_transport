"""Add authenticated company customer accounts.

Revision ID: customer_accounts
Revises: f5c76d8d8617
"""

import sqlalchemy as sa
from alembic import op

revision = "customer_accounts"
down_revision = "f5c76d8d8617"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("users") as batch:
        batch.drop_constraint(op.f("ck_users_role_company_consistency"), type_="check")
        batch.alter_column(
            "role",
            existing_type=sa.Enum("SUPER_ADMIN", "EMPLOYEE", name="user_role"),
            type_=sa.Enum("SUPER_ADMIN", "EMPLOYEE", "CUSTOMER", name="user_role"),
            existing_nullable=False,
        )
        batch.create_check_constraint(
            "role_company_consistency",
            "(role = 'SUPER_ADMIN' AND company_id IS NULL) OR "
            "(role IN ('EMPLOYEE', 'CUSTOMER') AND company_id IS NOT NULL)",
        )


def downgrade():
    connection = op.get_bind()
    if connection.scalar(sa.text("SELECT COUNT(*) FROM users WHERE role = 'CUSTOMER'")):
        raise RuntimeError("Remove customer accounts before downgrading.")
    with op.batch_alter_table("users") as batch:
        batch.drop_constraint(op.f("ck_users_role_company_consistency"), type_="check")
        batch.alter_column(
            "role",
            existing_type=sa.Enum("SUPER_ADMIN", "EMPLOYEE", "CUSTOMER", name="user_role"),
            type_=sa.Enum("SUPER_ADMIN", "EMPLOYEE", name="user_role"),
            existing_nullable=False,
        )
        batch.create_check_constraint(
            "role_company_consistency",
            "(role = 'SUPER_ADMIN' AND company_id IS NULL) OR (role = 'EMPLOYEE' AND company_id IS NOT NULL)",
        )
