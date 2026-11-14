"""Demo data for development and demonstrations (never run by migrations).

Run with ``flask seed-demo``. The command refuses to run in production.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from app.container import Services
from app.core.actor import Actor
from app.core.errors import ConflictError
from app.core.permissions import permissions_for_role
from app.models import ProductFieldType, User, UserRole
from app.modules.users.repository import UserRepository

DEMO_ADMIN_USERNAME = "admin"

_COMPANIES: list[dict[str, Any]] = [
    {
        "name": "حمل‌ونقل",
        "company_code": "ARMIN",
        "phone": "021-55550101",
        "address": "تهران، خیابان آزادی، پلاک ۱۲",
        "employees": [("armin.operator", "سارا محمدی"), ("armin.clerk", "رضا کریمی")],
        "shipments": ["پالت لوازم خانگی - مقصد شیراز", "قطعات یدکی خودرو - مقصد تبریز", "مواد غذایی بسته‌بندی‌شده"],
    },
    {
        "name": "باربری پارس",
        "company_code": "PARS",
        "phone": "031-55550202",
        "address": "اصفهان، بلوار کشاورز",
        "employees": [("pars.operator", "مریم احمدی")],
        "shipments": ["کاشی و سرامیک - مقصد مشهد", "تجهیزات پزشکی"],
    },
]

_PRODUCT_FIELDS: list[dict[str, Any]] = [
    {
        "field_key": "product_name",
        "label": "نام کالا",
        "data_type": ProductFieldType.TEXT,
        "is_required": True,
        "is_customer_visible": True,
        "display_order": 10,
        "validation_rules": {"max_length": 200},
    },
    {
        "field_key": "weight_kg",
        "label": "وزن (کیلوگرم)",
        "data_type": ProductFieldType.DECIMAL,
        "is_customer_visible": True,
        "display_order": 20,
        "validation_rules": {"min": "0", "max_decimal_places": 3},
    },
    {
        "field_key": "package_count",
        "label": "تعداد بسته",
        "data_type": ProductFieldType.NUMBER,
        "display_order": 30,
        "validation_rules": {"min": 1, "max": 100000},
    },
    {
        "field_key": "delivery_date",
        "label": "تاریخ تحویل برنامه‌ریزی‌شده",
        "data_type": ProductFieldType.DATE,
        "is_customer_visible": True,
        "display_order": 40,
    },
    {
        "field_key": "is_fragile",
        "label": "شکستنی",
        "data_type": ProductFieldType.BOOLEAN,
        "display_order": 50,
    },
    {
        "field_key": "packaging_type",
        "label": "نوع بسته‌بندی",
        "data_type": ProductFieldType.SELECT,
        "display_order": 60,
        "options": [
            {"value": "pallet", "label": "پالت"},
            {"value": "carton", "label": "کارتن"},
            {"value": "bulk", "label": "فله"},
        ],
    },
    {
        "field_key": "services",
        "label": "خدمات جانبی",
        "data_type": ProductFieldType.MULTI_SELECT,
        "display_order": 70,
        "options": [
            {"value": "insurance", "label": "بیمه"},
            {"value": "loading", "label": "بارگیری"},
            {"value": "customs", "label": "ترخیص گمرکی"},
        ],
    },
]

_SAMPLE_VALUES: dict[str, Any] = {
    "weight_kg": "1250.5",
    "package_count": 24,
    "delivery_date": "2026-12-01",
    "is_fragile": False,
    "packaging_type": "pallet",
    "services": ["insurance", "loading"],
}


@dataclass
class SeedReport:
    admin_username: str = DEMO_ADMIN_USERNAME
    employee_usernames: list[str] = field(default_factory=list)
    companies: int = 0
    product_fields: int = 0
    shipments: int = 0
    tracking_codes: list[str] = field(default_factory=list)


def _actor_for(user: User, services: Services) -> Actor:
    return Actor(
        user_id=user.id,
        username=user.username,
        role=user.role,
        company_id=user.company_id,
        permissions=permissions_for_role(user.role, services.settings),
    )


def seed_demo_data(services: Services, users: UserRepository, password: str) -> SeedReport:
    """Create demo records through the regular services (all validation and auditing applies).

    The operation is idempotent per record: existing users, companies and field
    keys are left untouched.
    """
    report = SeedReport()
    admin = users.get_by_username(DEMO_ADMIN_USERNAME)
    if admin is None:
        admin = services.users.create_super_admin(DEMO_ADMIN_USERNAME, "مدیر سامانه", password)
    if admin.role is not UserRole.SUPER_ADMIN:
        raise ConflictError("The demo administrator username is taken by a non-admin account.")
    admin_actor = _actor_for(admin, services)

    for definition in _PRODUCT_FIELDS:
        try:
            services.product_fields.create(admin_actor, dict(definition))
            report.product_fields += 1
        except ConflictError:
            continue

    existing_codes = {
        company.company_code: company for company in services.companies.list_companies(page=1, per_page=100).items
    }
    for spec in _COMPANIES:
        company = existing_codes.get(spec["company_code"])
        if company is not None:
            continue
        company = services.companies.create(
            admin_actor,
            {key: spec[key] for key in ("name", "company_code", "phone", "address")},
        )
        report.companies += 1
        employee_actor: Actor | None = None
        for username, full_name in spec["employees"]:
            if users.get_by_username(username) is not None:
                continue
            employee = services.users.create_employee(
                admin_actor,
                {"username": username, "full_name": full_name, "password": password, "company_id": company.id},
            )
            report.employee_usernames.append(employee.username)
            employee_actor = employee_actor or _actor_for(employee, services)
        for description in spec["shipments"]:
            shipment = services.shipments.create(
                employee_actor or admin_actor,
                {
                    "company_id": company.id,
                    "description": description,
                    "product_values": {"product_name": description.split(" - ")[0], **_SAMPLE_VALUES},
                },
            )
            report.shipments += 1
            report.tracking_codes.append(shipment.tracking_code)
    return report
