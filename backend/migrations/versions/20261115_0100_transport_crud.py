"""Recoverable transport entities.

Revision ID: transport_crud
Revises: transport_workspace
"""

import sqlalchemy as sa
from alembic import op

revision = "transport_crud"
down_revision = "transport_workspace"
branch_labels = None
depends_on = None


def upgrade():
    for table in ("companies", "users", "shipments"):
        with op.batch_alter_table(table) as batch:
            batch.add_column(sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True))


def downgrade():
    for table in ("shipments", "users", "companies"):
        with op.batch_alter_table(table) as batch:
            batch.drop_column("deleted_at")
