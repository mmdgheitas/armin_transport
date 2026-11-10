"""Company management (SUPER_ADMIN only)."""

from __future__ import annotations

import uuid

import pytest

from app.models import Company
from tests.support import Api, Factory


@pytest.fixture
def admin_api(factory: Factory) -> Api:
    return factory.login(factory.admin())


def test_create_company_normalizes_the_code(admin_api: Api, factory: Factory) -> None:
    response = admin_api.post(
        "/companies",
        json={"name": "  باربری نمونه  ", "company_code": "nemone-01", "phone": "021-5555", "address": "تهران"},
    )
    assert response.status_code == 201, response.get_json()
    data = response.get_json()["data"]
    assert data["name"] == "باربری نمونه"
    assert data["company_code"] == "NEMONE-01"
    assert data["is_active"] is True
    assert uuid.UUID(data["id"])
    assert data["created_at"].endswith("Z")
    assert factory.audit_actions()[-1] == "COMPANY_CREATED"


def test_company_code_must_be_unique_case_insensitively(admin_api: Api, factory: Factory) -> None:
    factory.company(company_code="ACME")
    response = admin_api.post("/companies", json={"name": "دیگری", "company_code": "acme"})
    assert response.status_code == 409
    errors = response.get_json()["errors"]
    assert errors["code"] == "company_code_taken"
    assert "company_code" in errors["fields"]


@pytest.mark.parametrize(
    ("payload", "field"),
    [
        ({"company_code": "ABC"}, "name"),
        ({"name": "x", "company_code": "ABC"}, "name"),
        ({"name": "نام معتبر"}, "company_code"),
        ({"name": "نام معتبر", "company_code": "A"}, "company_code"),
        ({"name": "نام معتبر", "company_code": "has space"}, "company_code"),
        ({"name": "نام معتبر", "company_code": "کد-فارسی"}, "company_code"),
        ({"name": "نام معتبر", "company_code": "ABC", "phone": "call me"}, "phone"),
        ({"name": "نام معتبر", "company_code": "ABC", "is_active": "sometimes"}, "is_active"),
        ({"name": "نام معتبر", "company_code": "ABC", "id": str(uuid.uuid4())}, "id"),
        ({"name": "ن" * 201, "company_code": "ABC"}, "name"),
    ],
)
def test_create_company_validation(admin_api: Api, payload: dict[str, object], field: str) -> None:
    response = admin_api.post("/companies", json=payload)
    assert response.status_code == 422
    assert field in response.get_json()["errors"]["fields"]


def test_list_companies_is_paginated_and_searchable(admin_api: Api, factory: Factory) -> None:
    factory.company(name="حمل‌ونقل البرز", company_code="ALBORZ")
    factory.company(name="باربری دماوند", company_code="DAMAVAND", is_active=False)
    factory.company(name="ترابری زاگرس", company_code="ZAGROS")

    response = admin_api.get("/companies?per_page=2&page=1")
    assert response.status_code == 200
    data = response.get_json()["data"]
    assert len(data["items"]) == 2
    assert data["pagination"] == {
        "page": 1,
        "per_page": 2,
        "total": 3,
        "total_pages": 2,
        "has_next": True,
        "has_prev": False,
    }

    by_name = admin_api.get("/companies?q=دماوند").get_json()["data"]["items"]
    assert [item["company_code"] for item in by_name] == ["DAMAVAND"]
    by_code = admin_api.get("/companies?q=zag").get_json()["data"]["items"]
    assert [item["company_code"] for item in by_code] == ["ZAGROS"]
    inactive = admin_api.get("/companies?is_active=false").get_json()["data"]["items"]
    assert [item["company_code"] for item in inactive] == ["DAMAVAND"]


def test_search_treats_like_wildcards_literally(admin_api: Api, factory: Factory) -> None:
    factory.company(name="صد درصد", company_code="PERCENT")
    factory.company(name="نام 100% ویژه", company_code="SPECIAL")
    items = admin_api.get("/companies?q=%25").get_json()["data"]["items"]
    assert [item["company_code"] for item in items] == ["SPECIAL"]
    assert admin_api.get("/companies?q=_").get_json()["data"]["items"] == []


@pytest.mark.parametrize(
    ("query", "field"),
    [
        ("page=0", "page"),
        ("page=abc", "page"),
        ("page=99999999999", "page"),
        ("per_page=0", "per_page"),
        ("per_page=101", "per_page"),
        ("per_page=-5", "per_page"),
        ("is_active=perhaps", "is_active"),
        ("q=" + "x" * 101, "q"),
    ],
)
def test_invalid_list_parameters_are_rejected(admin_api: Api, query: str, field: str) -> None:
    response = admin_api.get(f"/companies?{query}")
    assert response.status_code == 422
    assert field in response.get_json()["errors"]["fields"]


def test_unknown_query_parameters_are_ignored(admin_api: Api) -> None:
    assert admin_api.get("/companies?utm_source=newsletter&_=1700000000").status_code == 200


def test_page_beyond_the_last_page_is_empty_not_an_error(admin_api: Api, factory: Factory) -> None:
    factory.company()
    data = admin_api.get("/companies?page=50").get_json()["data"]
    assert data["items"] == []
    assert data["pagination"]["total"] == 1
    assert data["pagination"]["has_next"] is False


def test_company_detail_includes_counters(admin_api: Api, factory: Factory) -> None:
    company = factory.company()
    employee = factory.employee(company)
    factory.employee(company)
    factory.shipment(company, employee)
    data = admin_api.get(f"/companies/{company.id}").get_json()["data"]
    assert data["employee_count"] == 2
    assert data["shipment_count"] == 1


def test_unknown_company_returns_404(admin_api: Api) -> None:
    response = admin_api.get(f"/companies/{uuid.uuid4()}")
    assert response.status_code == 404
    assert response.get_json()["errors"]["code"] == "not_found"
    assert admin_api.get("/companies/not-a-uuid").status_code == 404


def test_update_company(admin_api: Api, factory: Factory) -> None:
    company = factory.company(name="نام قدیمی", phone="021-1")
    response = admin_api.patch(f"/companies/{company.id}", json={"name": "نام جدید", "phone": None})
    assert response.status_code == 200, response.get_json()
    data = response.get_json()["data"]
    assert data["name"] == "نام جدید"
    assert data["phone"] is None
    assert data["company_code"] == company.company_code
    assert factory.audit_actions()[-1] == "COMPANY_UPDATED"


def test_update_without_changes_writes_no_audit_entry(admin_api: Api, factory: Factory) -> None:
    company = factory.company()
    before = len(factory.audit_actions())
    assert admin_api.patch(f"/companies/{company.id}", json={"name": company.name}).status_code == 200
    assert len(factory.audit_actions()) == before


def test_update_company_code_conflict(admin_api: Api, factory: Factory) -> None:
    factory.company(company_code="TAKEN")
    company = factory.company()
    response = admin_api.patch(f"/companies/{company.id}", json={"company_code": "taken"})
    assert response.status_code == 409


def test_deactivate_and_reactivate_company(admin_api: Api, factory: Factory) -> None:
    company = factory.company()
    response = admin_api.patch(f"/companies/{company.id}", json={"is_active": False})
    assert response.status_code == 200
    assert response.get_json()["data"]["is_active"] is False
    assert factory.get(Company, company.id).is_active is False
    assert factory.audit_actions()[-1] == "COMPANY_DEACTIVATED"

    admin_api.patch(f"/companies/{company.id}", json={"is_active": True})
    assert factory.audit_actions()[-1] == "COMPANY_ACTIVATED"


def test_companies_cannot_be_deleted(admin_api: Api, factory: Factory) -> None:
    company = factory.company()
    response = admin_api.delete(f"/companies/{company.id}")
    assert response.status_code == 405
    assert response.get_json()["errors"]["code"] == "method_not_allowed"
