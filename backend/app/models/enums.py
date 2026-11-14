"""Enumerations persisted as database ENUM columns."""

from __future__ import annotations

import enum


class UserRole(enum.StrEnum):
    SUPER_ADMIN = "SUPER_ADMIN"
    EMPLOYEE = "EMPLOYEE"
    CUSTOMER = "CUSTOMER"


class TrackingCodeType(enum.StrEnum):
    MANUAL = "MANUAL"
    AUTO = "AUTO"


class ShipmentStatus(enum.StrEnum):
    ACTIVE = "ACTIVE"
    ARCHIVED = "ARCHIVED"


class ProductFieldType(enum.StrEnum):
    TEXT = "TEXT"
    NUMBER = "NUMBER"
    DECIMAL = "DECIMAL"
    DATE = "DATE"
    DATETIME = "DATETIME"
    BOOLEAN = "BOOLEAN"
    SELECT = "SELECT"
    MULTI_SELECT = "MULTI_SELECT"
