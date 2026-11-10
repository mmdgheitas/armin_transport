"""Dynamic product fields: definitions (admin) and per-shipment values."""

from __future__ import annotations

import time
import uuid
from typing import Any

import pytest
from flask import Flask
from sqlalchemy.exc import IntegrityError

from app.extensions import db
from app.models import AuditLog, ProductFieldDefinition, ShipmentProductValue
from app.models.enums import ProductFieldType
from app.modules.product_fields.validation import (
    FieldValidationError,
    is_safe_pattern,
    normalize_options,
    normalize_rules,
)
from tests.support import Api, Factory

OPTIONS = [
    {"value": "pallet", "label": "پالت"},
    {"value": "carton", "label": "کارتن"},
    {"value": "bulk", "label": "فله"},
]


@pytest.fixture
def admin_api(factory: Factory) -> Api:
    return factory.login(factory.admin())


class Workspace:
    def __init__(self, factory: Factory) -> None:
        self.company = factory.company()
        self.employee = factory.employee(self.company)
        self.shipment = factory.shipment(self.company, self.employee)
        self.api = factory.login(self.employee)
        self.values_url = f"/shipments/{self.shipment.id}/product-values"

    def put(self, values: dict[str, Any]) -> Any:
        return self.api.put(self.values_url, json={"values": values})

    def read(self) -> dict[str, dict[str, Any]]:
        response = self.api.get(self.values_url)
        assert response.status_code == 200, response.get_json()
        return {item["field"]["field_key"]: item for item in response.get_json()["data"]["items"]}


@pytest.fixture
def workspace(factory: Factory) -> Workspace:
    return Workspace(factory)


def _code(response: Any) -> str:
    result: str = response.get_json()["errors"]["code"]
    return result


# --------------------------------------------------------------------------- definitions
@pytest.mark.parametrize(
    ("data_type", "extra"),
    [
        ("TEXT", {"validation_rules": {"min_length": 2, "max_length": 50, "pattern": "[A-Z]{2}-\\d{4}"}}),
        ("NUMBER", {"validation_rules": {"min": 0, "max": 1000}}),
        ("DECIMAL", {"validation_rules": {"min": "0.5", "max": 99.75, "max_decimal_places": 3}}),
        ("DATE", {"validation_rules": {"min": "2020-01-01", "max": "2030-12-31"}}),
        ("DATETIME", {"validation_rules": {"min": "2020-01-01T00:00:00+03:30"}}),
        ("BOOLEAN", {}),
        ("SELECT", {"options": OPTIONS}),
        ("MULTI_SELECT", {"options": OPTIONS, "validation_rules": {"min_items": 1, "max_items": 2}}),
    ],
)
def test_admin_can_define_every_field_type(
    admin_api: Api, factory: Factory, data_type: str, extra: dict[str, Any]
) -> None:
    payload = {"field_key": f"f_{data_type.lower()}", "label": f"فیلد {data_type}", "data_type": data_type, **extra}
    response = admin_api.post("/product-fields", json=payload)
    assert response.status_code == 201, response.get_json()
    data = response.get_json()["data"]
    assert data["field_key"] == payload["field_key"]
    assert data["data_type"] == data_type
    assert data["version"] == 1
    assert data["is_active"] is True
    assert data["is_required"] is False
    assert data["is_customer_visible"] is False
    assert (data["options"] is not None) == (data_type in {"SELECT", "MULTI_SELECT"})
    assert factory.audit_actions()[-1] == "PRODUCT_FIELD_CREATED"


def test_rules_are_stored_in_canonical_form(admin_api: Api) -> None:
    decimal = admin_api.post(
        "/product-fields",
        json={
            "field_key": "price",
            "label": "قیمت",
            "data_type": "DECIMAL",
            "validation_rules": {"min": "0.50", "max": 99.750},
        },
    ).get_json()["data"]
    assert decimal["validation_rules"] == {"min": "0.5", "max": "99.75"}
    moment = admin_api.post(
        "/product-fields",
        json={
            "field_key": "eta",
            "label": "زمان",
            "data_type": "DATETIME",
            "validation_rules": {"min": "2026-01-01T03:30:00+03:30"},
        },
    ).get_json()["data"]
    assert moment["validation_rules"] == {"min": "2026-01-01T00:00:00Z"}
    empty = admin_api.post(
        "/product-fields", json={"field_key": "note", "label": "یادداشت", "data_type": "TEXT", "validation_rules": {}}
    ).get_json()["data"]
    assert empty["validation_rules"] is None


@pytest.mark.parametrize(
    ("payload", "field"),
    [
        ({"field_key": "Weight"}, "field_key"),
        ({"field_key": "1weight"}, "field_key"),
        ({"field_key": "w"}, "field_key"),
        ({"field_key": "weight-kg"}, "field_key"),
        ({"field_key": "وزن"}, "field_key"),
        ({"label": ""}, "label"),
        ({"label": "x" * 201}, "label"),
        ({"data_type": "JSON"}, "data_type"),
        ({"data_type": "text"}, "data_type"),
        ({"display_order": -1}, "display_order"),
        ({"is_required": "yes please"}, "is_required"),
        ({"version": 7}, "version"),
        ({"validation_rules": "min=1"}, "validation_rules"),
        ({"validation_rules": {"min": 1}}, "validation_rules"),  # not a TEXT rule
        ({"validation_rules": {"min_length": 10, "max_length": 5}}, "validation_rules"),
        ({"validation_rules": {"max_length": 5000}}, "validation_rules"),
        ({"validation_rules": {"min_length": "3"}}, "validation_rules"),
        ({"validation_rules": {"pattern": "([a-z]+"}}, "validation_rules"),  # does not compile
        ({"validation_rules": {"pattern": "(a+)+$"}}, "validation_rules"),  # catastrophic backtracking
        ({"validation_rules": {"pattern": "x" * 201}}, "validation_rules"),
        ({"options": OPTIONS}, "options"),  # options on a TEXT field
        ({"data_type": "SELECT"}, "options"),  # SELECT without options
        ({"data_type": "SELECT", "options": []}, "options"),
        ({"data_type": "SELECT", "options": [{"value": "a"}]}, "options"),
        ({"data_type": "SELECT", "options": [{"value": "a", "label": "A", "color": "red"}]}, "options"),
        ({"data_type": "SELECT", "options": [{"value": "a", "label": "A"}, {"value": "a", "label": "B"}]}, "options"),
        ({"data_type": "SELECT", "options": [{"value": "", "label": "A"}]}, "options"),
        ({"data_type": "SELECT", "options": ["a", "b"]}, "options"),
        ({"data_type": "NUMBER", "validation_rules": {"min": 5, "max": 1}}, "validation_rules"),
        ({"data_type": "NUMBER", "validation_rules": {"min": 1.5}}, "validation_rules"),
        ({"data_type": "NUMBER", "validation_rules": {"min": True}}, "validation_rules"),
        ({"data_type": "DECIMAL", "validation_rules": {"max_decimal_places": 13}}, "validation_rules"),
        ({"data_type": "DECIMAL", "validation_rules": {"min": "abc"}}, "validation_rules"),
        ({"data_type": "DATE", "validation_rules": {"min": "2026-13-01"}}, "validation_rules"),
        ({"data_type": "DATE", "validation_rules": {"min": "2026-02-01", "max": "2026-01-01"}}, "validation_rules"),
        ({"data_type": "DATETIME", "validation_rules": {"min": "2026-01-01T00:00:00"}}, "validation_rules"),
        ({"data_type": "BOOLEAN", "validation_rules": {"min": 0}}, "validation_rules"),
        (
            {"data_type": "MULTI_SELECT", "options": OPTIONS, "validation_rules": {"min_items": 3, "max_items": 1}},
            "validation_rules",
        ),
    ],
)
def test_invalid_definitions_are_rejected(
    admin_api: Api, factory: Factory, payload: dict[str, Any], field: str
) -> None:
    body = {"field_key": "sample_field", "label": "نمونه", "data_type": "TEXT", **payload}
    response = admin_api.post("/product-fields", json=body)
    assert response.status_code == 422, response.get_json()
    reported = response.get_json()["errors"]["fields"]
    assert any(key == field or key.startswith(f"{field}.") for key in reported), reported
    assert factory.count(ProductFieldDefinition) == 0


def test_only_one_active_definition_per_key(admin_api: Api, factory: Factory) -> None:
    first = admin_api.post("/product-fields", json={"field_key": "weight", "label": "وزن", "data_type": "NUMBER"})
    assert first.status_code == 201
    duplicate = admin_api.post(
        "/product-fields", json={"field_key": "weight", "label": "وزن ۲", "data_type": "DECIMAL"}
    )
    assert duplicate.status_code == 409
    assert _code(duplicate) == "field_key_taken"
    assert "field_key" in duplicate.get_json()["errors"]["fields"]

    # Retiring the old definition frees the key for a replacement with a different type.
    first_id = first.get_json()["data"]["id"]
    assert admin_api.patch(f"/product-fields/{first_id}", json={"is_active": False}).status_code == 200
    replacement = admin_api.post(
        "/product-fields", json={"field_key": "weight", "label": "وزن", "data_type": "DECIMAL"}
    )
    assert replacement.status_code == 201, replacement.get_json()

    # ...and the retired one cannot come back while the replacement is active.
    revived = admin_api.patch(f"/product-fields/{first_id}", json={"is_active": True})
    assert revived.status_code == 409
    assert factory.get(ProductFieldDefinition, first_id).is_active is False


def test_inactive_definitions_with_the_same_key_may_coexist(admin_api: Api, factory: Factory) -> None:
    for _ in range(3):
        response = admin_api.post(
            "/product-fields", json={"field_key": "draft", "label": "پیش‌نویس", "data_type": "TEXT", "is_active": False}
        )
        assert response.status_code == 201, response.get_json()
    assert factory.count(ProductFieldDefinition) == 3


@pytest.mark.mysql
def test_database_enforces_one_active_definition_per_key(factory: Factory, app: Flask) -> None:
    """The rule holds even if application-level checks are bypassed (generated column + unique index)."""

    factory.field(field_key="weight")
    with app.app_context():
        db.session.add(
            ProductFieldDefinition(
                field_key="weight", label="تکراری", data_type=ProductFieldType.TEXT, is_active=True, version=1
            )
        )
        with pytest.raises(IntegrityError):
            db.session.commit()
        db.session.rollback()
        db.session.remove()


def test_update_bumps_the_version_only_for_semantic_changes(admin_api: Api, factory: Factory) -> None:
    field = factory.field(field_key="packaging", data_type="SELECT", options=OPTIONS[:2])
    url = f"/product-fields/{field.id}"

    cosmetic = admin_api.patch(url, json={"display_order": 99, "is_customer_visible": True})
    assert cosmetic.status_code == 200, cosmetic.get_json()
    assert cosmetic.get_json()["data"]["version"] == 1
    assert cosmetic.get_json()["data"]["is_customer_visible"] is True

    unchanged = admin_api.patch(url, json={"label": field.label, "options": OPTIONS[:2]})
    assert unchanged.get_json()["data"]["version"] == 1

    relabelled = admin_api.patch(url, json={"label": "نوع بسته‌بندی"})
    assert relabelled.get_json()["data"]["version"] == 2
    required = admin_api.patch(url, json={"is_required": True})
    assert required.get_json()["data"]["version"] == 3
    extended = admin_api.patch(url, json={"options": OPTIONS})
    assert extended.get_json()["data"]["version"] == 4
    assert [option["value"] for option in extended.get_json()["data"]["options"]] == ["pallet", "carton", "bulk"]
    assert factory.audit_actions().count("PRODUCT_FIELD_UPDATED") == 4


def test_key_and_type_are_immutable(admin_api: Api, factory: Factory) -> None:
    field = factory.field(field_key="weight", data_type="NUMBER")
    url = f"/product-fields/{field.id}"
    for payload, name in (({"field_key": "mass"}, "field_key"), ({"data_type": "TEXT"}, "data_type")):
        response = admin_api.patch(url, json=payload)
        assert response.status_code == 422
        assert _code(response) == "immutable_field"
        assert name in response.get_json()["errors"]["fields"]
    # Re-sending the current values (as an edit form would) is harmless.
    same = admin_api.patch(url, json={"field_key": "weight", "data_type": "NUMBER", "label": "وزن خالص"})
    assert same.status_code == 200
    stored = factory.get(ProductFieldDefinition, field.id)
    assert (stored.field_key, stored.data_type.value) == ("weight", "NUMBER")


def test_update_validates_rules_against_the_existing_type(admin_api: Api, factory: Factory) -> None:
    number = factory.field(data_type="NUMBER")
    assert (
        admin_api.patch(f"/product-fields/{number.id}", json={"validation_rules": {"max_length": 5}}).status_code == 422
    )
    assert admin_api.patch(f"/product-fields/{number.id}", json={"options": OPTIONS}).status_code == 422
    ok = admin_api.patch(f"/product-fields/{number.id}", json={"validation_rules": {"min": 1, "max": 9}})
    assert ok.status_code == 200
    assert ok.get_json()["data"]["validation_rules"] == {"min": 1, "max": 9}
    cleared = admin_api.patch(f"/product-fields/{number.id}", json={"validation_rules": None})
    assert cleared.get_json()["data"]["validation_rules"] is None

    select = factory.field(data_type="SELECT", options=OPTIONS)
    assert admin_api.patch(f"/product-fields/{select.id}", json={"options": []}).status_code == 422
    assert admin_api.patch(f"/product-fields/{select.id}", json={"options": None}).status_code == 422


def test_definitions_cannot_be_deleted(admin_api: Api, factory: Factory) -> None:
    field = factory.field()
    assert admin_api.delete(f"/product-fields/{field.id}").status_code == 405
    assert admin_api.get(f"/product-fields/{uuid.uuid4()}").status_code == 404
    assert admin_api.patch(f"/product-fields/{uuid.uuid4()}", json={"label": "x"}).status_code == 404


def test_listing_order_search_and_inactive_visibility(admin_api: Api, factory: Factory) -> None:
    factory.field(field_key="zeta", label="آخر", display_order=30)
    factory.field(field_key="alpha", label="اول", display_order=10)
    factory.field(field_key="retired", label="بازنشسته", display_order=20, is_active=False)
    employee_api = factory.login(factory.employee())

    def keys(client: Api, query: str = "") -> list[str]:
        response = client.get(f"/product-fields{query}")
        assert response.status_code == 200, response.get_json()
        return [item["field_key"] for item in response.get_json()["data"]["items"]]

    assert keys(admin_api) == ["alpha", "zeta"]
    assert keys(admin_api, "?include_inactive=true") == ["alpha", "retired", "zeta"]
    assert keys(admin_api, "?q=alp") == ["alpha"]
    assert keys(admin_api, "?q=اول") == ["alpha"]
    # Employees always get the active set, whatever they ask for.
    assert keys(employee_api) == ["alpha", "zeta"]
    assert keys(employee_api, "?include_inactive=true") == ["alpha", "zeta"]


def test_employees_can_read_but_not_manage_definitions(factory: Factory) -> None:
    active = factory.field()
    retired = factory.field(is_active=False)
    client = factory.login(factory.employee())
    assert client.get(f"/product-fields/{active.id}").status_code == 200
    assert client.get(f"/product-fields/{retired.id}").status_code == 404
    created = client.post("/product-fields", json={"field_key": "mine", "label": "من", "data_type": "TEXT"})
    assert created.status_code == 403
    assert created.get_json()["errors"]["required_permissions"] == ["product_field:manage"]
    assert client.patch(f"/product-fields/{active.id}", json={"label": "هک"}).status_code == 403
    assert factory.get(ProductFieldDefinition, active.id).label == active.label


# --------------------------------------------------------------------------- pure validation helpers
@pytest.mark.parametrize(
    "pattern",
    [
        r"[A-Z]{2}-\d{4}",
        r"\d{10}",
        r"[A-Za-z0-9 ]+",
        r"(AB|CD)-\d+",
        r"\d{3}(-\d{4})?",
        r"^09\d{9}$",
        r"[\u0600-\u06FF\s]+",
        r"(a|b)*",
    ],
)
def test_safe_patterns_are_accepted(pattern: str) -> None:
    assert is_safe_pattern(pattern)


@pytest.mark.parametrize(
    "pattern",
    [
        r"(a+)+",
        r"(a*)*",
        r"(a|aa)+",
        r"(\d+,)*\d+",
        r"(a{1,5}){1,5}",
        r"(a)\1",
        r"(.*a){20}",
        r"(?:a+)+b",
        r"(?=(a+)+)b",
        r"(ab|cd)+",
        "(",
    ],
)
def test_patterns_with_unpredictable_cost_are_refused(pattern: str) -> None:
    assert not is_safe_pattern(pattern)


def test_rule_and_option_normalizers_reject_wrong_shapes() -> None:
    assert normalize_rules(ProductFieldType.TEXT, None) is None
    assert normalize_options(ProductFieldType.TEXT, None) is None
    assert normalize_options(ProductFieldType.TEXT, []) is None
    with pytest.raises(FieldValidationError):
        normalize_rules(ProductFieldType.TEXT, ["min_length", 3])
    with pytest.raises(FieldValidationError):
        normalize_options(ProductFieldType.SELECT, "pallet,carton")
    with pytest.raises(FieldValidationError):
        normalize_options(ProductFieldType.SELECT, [{"value": str(i), "label": str(i)} for i in range(201)])


# --------------------------------------------------------------------------- values: happy paths
def test_values_of_every_type_are_validated_and_canonicalized(workspace: Workspace, factory: Factory) -> None:
    factory.field(field_key="name", data_type="TEXT")
    factory.field(field_key="count", data_type="NUMBER")
    factory.field(field_key="weight", data_type="DECIMAL")
    factory.field(field_key="due", data_type="DATE")
    factory.field(field_key="eta", data_type="DATETIME")
    factory.field(field_key="fragile", data_type="BOOLEAN")
    factory.field(field_key="packaging", data_type="SELECT", options=OPTIONS)
    factory.field(field_key="services", data_type="MULTI_SELECT", options=OPTIONS)

    response = workspace.put(
        {
            "name": "  لوازم خانگی  ",
            "count": 24,
            "weight": "0012.5000",
            "due": "2026-12-01",
            "eta": "2026-12-01T10:30:00+03:30",
            "fragile": False,
            "packaging": "pallet",
            "services": ["bulk", "carton"],
        }
    )
    assert response.status_code == 200, response.get_json()
    items = {item["field"]["field_key"]: item for item in response.get_json()["data"]["items"]}
    assert {key: item["value"] for key, item in items.items()} == {
        "name": "لوازم خانگی",
        "count": 24,
        "weight": "12.5",
        "due": "2026-12-01",
        "eta": "2026-12-01T07:00:00Z",
        "fragile": False,
        "packaging": "pallet",
        "services": ["bulk", "carton"],
    }
    assert items["packaging"]["display_value"] == "پالت"
    assert items["services"]["display_value"] == ["فله", "کارتن"]
    assert items["fragile"]["display_value"] is False
    assert all(item["field_version"] == 1 and item["is_outdated"] is False for item in items.values())
    assert workspace.read().keys() == items.keys()
    assert factory.audit_actions()[-1] == "PRODUCT_VALUES_UPDATED"


def test_numbers_accept_integral_json_floats_and_decimals_accept_numbers(
    workspace: Workspace, factory: Factory
) -> None:
    factory.field(field_key="count", data_type="NUMBER")
    factory.field(field_key="weight", data_type="DECIMAL")
    assert workspace.put({"count": 5.0, "weight": 2.5}).status_code == 200
    stored = workspace.read()
    assert stored["count"]["value"] == 5
    assert stored["weight"]["value"] == "2.5"


def test_audit_entry_lists_changed_keys_but_not_values(workspace: Workspace, factory: Factory, app: Flask) -> None:
    factory.field(field_key="name", data_type="TEXT")
    factory.field(field_key="secret_note", data_type="TEXT")
    workspace.put({"name": "الف", "secret_note": "confidential-content"})
    workspace.put({"name": "ب", "secret_note": "confidential-content"})
    with app.app_context():
        entries = db.session.scalars(
            db.select(AuditLog).where(AuditLog.action == "PRODUCT_VALUES_UPDATED").order_by(AuditLog.created_at)
        ).all()
        assert [entry.meta for entry in entries] == [
            {"changed": ["name", "secret_note"], "removed": []},
            {"changed": ["name"], "removed": []},
        ]
        assert "confidential-content" not in str([entry.meta for entry in entries])
        db.session.remove()
    before = len(factory.audit_actions())
    workspace.put({"name": "ب", "secret_note": "confidential-content"})  # identical: nothing to record
    assert len(factory.audit_actions()) == before


def test_optional_values_can_be_cleared(workspace: Workspace, factory: Factory) -> None:
    factory.field(field_key="name", data_type="TEXT")
    factory.field(field_key="services", data_type="MULTI_SELECT", options=OPTIONS)
    factory.field(field_key="count", data_type="NUMBER")
    workspace.put({"name": "الف", "services": ["bulk"], "count": 3})
    assert factory.count(ShipmentProductValue) == 3

    response = workspace.put({"name": "   ", "services": [], "count": None})
    assert response.status_code == 200, response.get_json()
    assert factory.count(ShipmentProductValue) == 0
    assert all(item["value"] is None for item in workspace.read().values())

    workspace.put({"name": "الف"})
    assert workspace.put({}).status_code == 200  # an omitted optional field is cleared as well
    assert factory.count(ShipmentProductValue) == 0


def test_text_is_stored_verbatim_and_returned_as_json_data(workspace: Workspace, factory: Factory) -> None:
    """Markup is data, not HTML: the API never interprets it; clients must render it as text."""
    factory.field(field_key="name", data_type="TEXT")
    payload = "<script>alert('xss')</script><img src=x onerror=alert(1)>"
    response = workspace.put({"name": payload})
    assert response.status_code == 200
    assert response.headers["Content-Type"] == "application/json"
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert workspace.read()["name"]["value"] == payload


# --------------------------------------------------------------------------- values: validation
@pytest.mark.parametrize(
    ("definition", "value"),
    [
        # TEXT
        ({"data_type": "TEXT"}, 123),
        ({"data_type": "TEXT"}, ["a"]),
        ({"data_type": "TEXT"}, {"a": 1}),
        ({"data_type": "TEXT"}, "x" * 2001),
        ({"data_type": "TEXT", "validation_rules": {"max_length": 5}}, "abcdef"),
        ({"data_type": "TEXT", "validation_rules": {"min_length": 3}}, "ab"),
        ({"data_type": "TEXT", "validation_rules": {"pattern": "[A-Z]{2}-\\d{4}"}}, "ab-1234"),
        ({"data_type": "TEXT", "validation_rules": {"pattern": "[A-Z]{2}-\\d{4}"}}, "AB-1234-extra"),
        # NUMBER
        ({"data_type": "NUMBER"}, "12"),
        ({"data_type": "NUMBER"}, 12.5),
        ({"data_type": "NUMBER"}, True),
        ({"data_type": "NUMBER"}, 2**53),
        ({"data_type": "NUMBER"}, -(2**53)),
        ({"data_type": "NUMBER", "validation_rules": {"min": 1}}, 0),
        ({"data_type": "NUMBER", "validation_rules": {"max": 10}}, 11),
        # DECIMAL
        ({"data_type": "DECIMAL"}, "abc"),
        ({"data_type": "DECIMAL"}, "1,5"),
        ({"data_type": "DECIMAL"}, "NaN"),
        ({"data_type": "DECIMAL"}, "Infinity"),
        ({"data_type": "DECIMAL"}, True),
        ({"data_type": "DECIMAL"}, [1.5]),
        ({"data_type": "DECIMAL"}, "1e999999999"),
        ({"data_type": "DECIMAL"}, "1e-999999999"),
        ({"data_type": "DECIMAL"}, "9" * 31),
        ({"data_type": "DECIMAL"}, "1.1234567"),  # more than the default 6 places
        ({"data_type": "DECIMAL", "validation_rules": {"max_decimal_places": 2}}, "1.234"),
        ({"data_type": "DECIMAL", "validation_rules": {"min": "0"}}, "-0.01"),
        ({"data_type": "DECIMAL", "validation_rules": {"max": "100"}}, "100.01"),
        # DATE
        ({"data_type": "DATE"}, "2026-02-30"),
        ({"data_type": "DATE"}, "01/02/2026"),
        ({"data_type": "DATE"}, "2026-1-5"),
        ({"data_type": "DATE"}, 20260101),
        ({"data_type": "DATE"}, "2026-01-01T00:00:00Z"),
        ({"data_type": "DATE", "validation_rules": {"min": "2026-01-01"}}, "2025-12-31"),
        ({"data_type": "DATE", "validation_rules": {"max": "2026-01-01"}}, "2026-01-02"),
        # DATETIME
        ({"data_type": "DATETIME"}, "2026-01-01"),
        ({"data_type": "DATETIME"}, "2026-01-01T10:00:00"),  # no time zone
        ({"data_type": "DATETIME"}, "yesterday"),
        ({"data_type": "DATETIME"}, 1767225600),
        ({"data_type": "DATETIME", "validation_rules": {"min": "2026-01-01T00:00:00Z"}}, "2025-12-31T23:59:59Z"),
        # BOOLEAN
        ({"data_type": "BOOLEAN"}, "true"),
        ({"data_type": "BOOLEAN"}, 1),
        ({"data_type": "BOOLEAN"}, 0),
        # SELECT
        ({"data_type": "SELECT", "options": OPTIONS}, "box"),
        ({"data_type": "SELECT", "options": OPTIONS}, "Pallet"),
        ({"data_type": "SELECT", "options": OPTIONS}, "پالت"),  # the label is not the value
        ({"data_type": "SELECT", "options": OPTIONS}, ["pallet"]),
        ({"data_type": "SELECT", "options": OPTIONS}, 1),
        # MULTI_SELECT
        ({"data_type": "MULTI_SELECT", "options": OPTIONS}, "pallet"),
        ({"data_type": "MULTI_SELECT", "options": OPTIONS}, ["pallet", "box"]),
        ({"data_type": "MULTI_SELECT", "options": OPTIONS}, ["pallet", "pallet"]),
        ({"data_type": "MULTI_SELECT", "options": OPTIONS}, [1, 2]),
        ({"data_type": "MULTI_SELECT", "options": OPTIONS, "validation_rules": {"min_items": 2}}, ["pallet"]),
        ({"data_type": "MULTI_SELECT", "options": OPTIONS, "validation_rules": {"max_items": 1}}, ["pallet", "bulk"]),
    ],
)
def test_invalid_values_are_rejected(
    workspace: Workspace, factory: Factory, definition: dict[str, Any], value: Any
) -> None:
    factory.field(field_key="target", **definition)
    started = time.monotonic()
    response = workspace.put({"target": value})
    assert time.monotonic() - started < 2  # no pathological input may stall the request
    assert response.status_code == 422, response.get_json()
    errors = response.get_json()["errors"]
    assert errors["code"] == "validation_error"
    assert list(errors["fields"]) == ["values.target"]
    assert factory.count(ShipmentProductValue) == 0


def test_required_fields_must_be_supplied(workspace: Workspace, factory: Factory) -> None:
    factory.field(field_key="name", data_type="TEXT", is_required=True)
    factory.field(field_key="services", data_type="MULTI_SELECT", options=OPTIONS, is_required=True)
    factory.field(field_key="note", data_type="TEXT")
    for values in ({}, {"name": None, "services": []}, {"name": "  ", "services": None}):
        response = workspace.put(values)
        assert response.status_code == 422
        assert set(response.get_json()["errors"]["fields"]) == {"values.name", "values.services"}
    assert workspace.put({"name": "الف", "services": ["bulk"]}).status_code == 200


def test_false_and_zero_satisfy_required_fields(workspace: Workspace, factory: Factory) -> None:
    factory.field(field_key="fragile", data_type="BOOLEAN", is_required=True)
    factory.field(field_key="count", data_type="NUMBER", is_required=True)
    assert workspace.put({"fragile": False, "count": 0}).status_code == 200
    stored = workspace.read()
    assert stored["fragile"]["value"] is False
    assert stored["count"]["value"] == 0


def test_unknown_and_retired_keys_are_rejected(workspace: Workspace, factory: Factory) -> None:
    factory.field(field_key="name", data_type="TEXT")
    factory.field(field_key="old_field", data_type="TEXT", is_active=False)
    response = workspace.put({"name": "الف", "old_field": "x", "does_not_exist": 1, "__proto__": {}})
    assert response.status_code == 422
    assert set(response.get_json()["errors"]["fields"]) == {
        "values.old_field",
        "values.does_not_exist",
        "values.__proto__",
    }
    assert factory.count(ShipmentProductValue) == 0


def test_all_errors_are_reported_together_and_nothing_is_saved(workspace: Workspace, factory: Factory) -> None:
    factory.field(field_key="name", data_type="TEXT")
    factory.field(field_key="count", data_type="NUMBER")
    factory.field(field_key="due", data_type="DATE")
    workspace.put({"name": "قبلی", "count": 1})
    response = workspace.put({"name": "جدید", "count": "many", "due": "soon"})
    assert response.status_code == 422
    assert set(response.get_json()["errors"]["fields"]) == {"values.count", "values.due"}
    stored = workspace.read()
    assert stored["name"]["value"] == "قبلی"  # the valid part of a rejected request is not applied
    assert stored["count"]["value"] == 1


@pytest.mark.parametrize(
    "body", [{}, {"values": None}, {"values": []}, {"values": "x"}, {"values": {}, "extra": 1}, {"name": "x"}]
)
def test_values_envelope_validation(workspace: Workspace, body: dict[str, Any]) -> None:
    assert workspace.api.put(workspace.values_url, json=body).status_code == 422


# --------------------------------------------------------------------------- definition changes over time
def test_retired_fields_keep_their_values_and_are_not_editable(
    workspace: Workspace, factory: Factory, admin_api: Api
) -> None:
    legacy = factory.field(field_key="legacy", label="قدیمی", data_type="TEXT", display_order=1)
    factory.field(field_key="current", data_type="TEXT", display_order=2)
    untouched = factory.field(field_key="never_used", data_type="TEXT", display_order=3)
    workspace.put({"legacy": "مقدار تاریخی", "current": "الف"})
    for field in (legacy, untouched):
        assert admin_api.patch(f"/product-fields/{field.id}", json={"is_active": False}).status_code == 200

    stored = workspace.read()
    assert list(stored) == ["current", "legacy"]  # active first; retired fields only when they hold a value
    assert stored["legacy"]["value"] == "مقدار تاریخی"
    assert stored["legacy"]["field"]["is_active"] is False

    assert workspace.put({"current": "ب"}).status_code == 200  # the retired value survives a full update
    assert workspace.read()["legacy"]["value"] == "مقدار تاریخی"
    assert workspace.put({"current": "ب", "legacy": "تغییر"}).status_code == 422


def test_values_saved_under_an_older_definition_are_flagged(
    workspace: Workspace, factory: Factory, admin_api: Api
) -> None:
    field = factory.field(field_key="packaging", data_type="SELECT", options=OPTIONS)
    workspace.put({"packaging": "bulk"})
    # The administrator removes the option that this shipment uses.
    admin_api.patch(f"/product-fields/{field.id}", json={"options": OPTIONS[:2]})

    item = workspace.read()["packaging"]
    assert item["value"] == "bulk"  # history is preserved, never rewritten
    assert item["display_value"] == "bulk"  # no label any more: the raw value is shown
    assert item["field_version"] == 1 and item["field"]["version"] == 2
    assert item["is_outdated"] is True

    # Re-saving must satisfy the current definition.
    assert workspace.put({"packaging": "bulk"}).status_code == 422
    assert workspace.put({"packaging": "carton"}).status_code == 200
    refreshed = workspace.read()["packaging"]
    assert refreshed["is_outdated"] is False and refreshed["field_version"] == 2


def test_new_required_field_does_not_invalidate_existing_shipments(workspace: Workspace, factory: Factory) -> None:
    factory.field(field_key="name", data_type="TEXT")
    workspace.put({"name": "الف"})
    factory.field(field_key="hs_code", data_type="TEXT", is_required=True)
    # Reading and unrelated edits still work...
    assert workspace.read()["hs_code"]["value"] is None
    assert workspace.api.patch(f"/shipments/{workspace.shipment.id}", json={"description": "x"}).status_code == 200
    # ...but the next edit of the values has to supply the new required field.
    assert workspace.put({"name": "ب"}).status_code == 422
    assert workspace.put({"name": "ب", "hs_code": "8418"}).status_code == 200


# --------------------------------------------------------------------------- access control on values
def test_values_are_tenant_scoped(workspace: Workspace, factory: Factory) -> None:
    factory.field(field_key="name", data_type="TEXT")
    workspace.put({"name": "محرمانه"})
    outsider = factory.login(factory.employee())
    assert outsider.get(workspace.values_url).status_code == 404
    assert outsider.put(workspace.values_url, json={"values": {"name": "هک"}}).status_code == 404
    assert (
        outsider.patch(f"/shipments/{workspace.shipment.id}", json={"product_values": {"name": "هک"}}).status_code
        == 404
    )
    assert workspace.read()["name"]["value"] == "محرمانه"


def test_values_of_archived_shipments_are_read_only(workspace: Workspace, factory: Factory) -> None:
    factory.field(field_key="name", data_type="TEXT")
    workspace.put({"name": "الف"})
    workspace.api.post(f"/shipments/{workspace.shipment.id}/archive")
    response = workspace.put({"name": "ب"})
    assert response.status_code == 409
    assert _code(response) == "shipment_archived"
    assert workspace.read()["name"]["value"] == "الف"


def test_values_can_be_set_through_shipment_create_and_update(factory: Factory) -> None:
    factory.field(field_key="name", data_type="TEXT", is_required=True)
    factory.field(field_key="count", data_type="NUMBER")
    client = factory.login(factory.employee())

    created = client.post("/shipments", json={"product_values": {"name": "الف", "count": 2}})
    assert created.status_code == 201, created.get_json()
    shipment_id = created.get_json()["data"]["id"]
    # Without product_values the shipment is created first and completed later.
    assert client.post("/shipments", json={"description": "بدون مشخصات"}).status_code == 201

    updated = client.patch(f"/shipments/{shipment_id}", json={"product_values": {"name": "ب"}})
    assert updated.status_code == 200, updated.get_json()
    items = {
        item["field"]["field_key"]: item["value"]
        for item in client.get(f"/shipments/{shipment_id}/product-values").get_json()["data"]["items"]
    }
    assert items == {"name": "ب", "count": None}

    invalid = client.patch(f"/shipments/{shipment_id}", json={"description": "نباید ذخیره شود", "product_values": {}})
    assert invalid.status_code == 422
    assert client.get(f"/shipments/{shipment_id}").get_json()["data"]["description"] is None
