"""Transport countries, assignments, per-employee slots and exact manual codes.

Revision ID: transport_workspace
Revises: company_portal
"""

import sqlalchemy as sa
from alembic import op

revision = "transport_workspace"
down_revision = "company_portal"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("users") as batch:
        batch.add_column(sa.Column("country", sa.String(2), nullable=True))
    with op.batch_alter_table("documents") as batch:
        batch.add_column(sa.Column("country", sa.String(2), nullable=True))
    with op.batch_alter_table("shipments") as batch:
        batch.alter_column(
            "tracking_code", existing_type=sa.String(64), type_=sa.Text(collation="BINARY"), existing_nullable=False
        )
        batch.add_column(sa.Column("transport_enabled", sa.Boolean(), nullable=False, server_default="0"))
        batch.add_column(sa.Column("countries", sa.JSON(), nullable=False, server_default="[]"))
        batch.add_column(sa.Column("upload_limit", sa.Integer(), nullable=False, server_default="12"))
        batch.add_column(sa.Column("truck_count", sa.Integer(), nullable=False, server_default="1"))
        batch.add_column(sa.Column("border_count", sa.Integer(), nullable=False, server_default="0"))
    op.create_table(
        "shipment_assignments",
        sa.Column("shipment_id", sa.Uuid(), sa.ForeignKey("shipments.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="RESTRICT"), primary_key=True),
    )


def downgrade():
    connection = op.get_bind()
    if connection.scalar(sa.text("SELECT COUNT(*) FROM shipments WHERE transport_enabled = 1")):
        raise RuntimeError("Export new transport data before downgrading.")
    op.drop_table("shipment_assignments")
    with op.batch_alter_table("shipments") as batch:
        for column in ("countries", "transport_enabled", "upload_limit", "truck_count", "border_count"):
            batch.drop_column(column)
        batch.alter_column("tracking_code", existing_type=sa.Text(), type_=sa.String(64), existing_nullable=False)
    with op.batch_alter_table("documents") as batch:
        batch.drop_column("country")
    with op.batch_alter_table("users") as batch:
        batch.drop_column("country")
