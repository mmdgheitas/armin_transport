"""Data access for customer access sessions."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session, scoped_session

from app.core.db_utils import affected_rows
from app.models import CustomerAccessSession


class CustomerSessionRepository:
    def __init__(self, session: scoped_session[Session]) -> None:
        self._session = session

    def add(self, access_session: CustomerAccessSession) -> None:
        self._session.add(access_session)

    def get_by_token_hash(self, token_hash: str) -> CustomerAccessSession | None:
        return self._session.scalar(select(CustomerAccessSession).where(CustomerAccessSession.token_hash == token_hash))

    def revoke_for_shipment(self, shipment_id: uuid.UUID, now: datetime) -> int:
        """Revoke every still-usable session of a shipment; returns how many were revoked."""
        result = self._session.execute(
            update(CustomerAccessSession)
            .where(
                CustomerAccessSession.shipment_id == shipment_id,
                CustomerAccessSession.revoked_at.is_(None),
                CustomerAccessSession.expires_at > now,
            )
            .values(revoked_at=now)
        )
        return affected_rows(result)

    def purge_older_than(self, cutoff: datetime) -> int:
        result = self._session.execute(delete(CustomerAccessSession).where(CustomerAccessSession.expires_at < cutoff))
        return affected_rows(result)
