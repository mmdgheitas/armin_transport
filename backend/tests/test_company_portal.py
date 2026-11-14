"""Company credentials, shared staff and tenant-safe work history."""

import uuid

from sqlalchemy import func, select

from app.extensions import db
from app.models import AuditLog, Company, User
from tests.support import DEFAULT_PASSWORD, Api, upload_file


def create_company(admin, code, username):
    response = admin.post(
        "/companies",
        json={
            "name": f"شرکت {code}",
            "company_code": code,
            "username": username,
            "password": DEFAULT_PASSWORD,
        },
    )
    assert response.status_code == 201, response.get_json()
    assert "password" not in str(response.get_json()).lower()
    return response.get_json()["data"]["id"]


def login(app, username):
    api = Api(app)
    response = api.login(username)
    assert response.status_code == 200, response.get_json()
    api.token = response.get_json()["data"]["access_token"]
    return api


def test_company_is_created_with_working_private_account(factory, app):
    admin = factory.login(factory.admin())
    company_id = create_company(admin, "PORTAL", "portal-user")
    customer = login(app, "portal-user")
    summary = customer.get("/dashboard/summary")
    assert summary.status_code == 200
    assert summary.get_json()["data"]["company"]["id"] == company_id
    other = create_company(admin, "OTHER", "other-portal")
    own_shipment = admin.post("/shipments", json={"company_id": company_id, "description": "our searchable cargo"})
    foreign_shipment = admin.post("/shipments", json={"company_id": other})
    own_id = own_shipment.get_json()["data"]["id"]
    foreign_id = foreign_shipment.get_json()["data"]["id"]
    items = customer.get("/shipments?q=searchable").get_json()["data"]["items"]
    assert [item["id"] for item in items] == [own_id]
    assert customer.get(f"/shipments/{foreign_id}").status_code == 404
    assert customer.get(f"/shipments?company_id={other}").status_code == 403
    assert customer.post("/companies", json={"name": "bad"}).status_code == 403
    assert customer.get("/audit-logs").status_code == 403


def test_credentials_required_and_duplicate_account_leaves_no_company(factory, app):
    admin = factory.login(factory.admin())
    assert admin.post("/companies", json={"name": "شرکت", "company_code": "MISSING"}).status_code == 422
    create_company(admin, "FIRST", "unique-company")
    response = admin.post(
        "/companies",
        json={
            "name": "نام دوم",
            "company_code": "SECOND",
            "username": "unique-company",
            "password": DEFAULT_PASSWORD,
        },
    )
    assert response.status_code == 409
    assert admin.get("/companies?q=SECOND").get_json()["data"]["items"] == []
    with app.app_context():
        assert db.session.scalar(select(func.count()).select_from(User).where(User.username == "unique-company")) == 1
        assert db.session.scalar(select(func.count()).select_from(Company)) == 1
        assert not any("password" in str(entry.meta).lower() for entry in db.session.scalars(select(AuditLog)))


def test_shared_staff_and_history_keep_employee_files_private(factory, app):
    admin_user = factory.admin()
    admin = factory.login(admin_user)
    first_company = create_company(admin, "FIRST", "company-first")
    second_company = create_company(admin, "SECOND", "company-second")
    staff = []
    for index in range(2):
        response = admin.post(
            "/users",
            json={
                "username": f"shared-staff-{index}",
                "full_name": f"کارمند {index}",
                "password": DEFAULT_PASSWORD,
            },
        )
        assert response.status_code == 201, response.get_json()
        assert response.get_json()["data"]["company_id"] is None
        staff.append((response.get_json()["data"]["id"], login(app, f"shared-staff-{index}")))
    first_id, first = staff[0]
    second_id, second = staff[1]
    shipment = first.post("/shipments", json={"company_id": first_company, "description": "first staff"})
    assert shipment.status_code == 201, shipment.get_json()
    shipment_id = shipment.get_json()["data"]["id"]
    assert first.post("/shipments", json={"company_id": second_company}).status_code == 201
    assert second.patch(f"/shipments/{shipment_id}", json={"description": "second staff updated"}).status_code == 200
    response = first.upload(shipment_id, [upload_file("first.bin", b"arbitrary")])
    assert response.status_code == 201, response.get_json()
    first_doc = response.get_json()["data"][0]["id"]
    assert second.upload(shipment_id, [upload_file("second.any", b"arbitrary")]).status_code == 201
    assert len(second.get(f"/shipments/{shipment_id}/documents").get_json()["data"]["items"]) == 1
    assert second.get(f"/documents/{first_doc}/download").status_code == 404
    customer = login(app, "company-first")
    assert len(customer.get(f"/shipments/{shipment_id}/documents").get_json()["data"]["items"]) == 2
    assert customer.get(f"/documents/{first_doc}/download").status_code == 200
    history = customer.get(f"/companies/{first_company}/activity")
    assert history.status_code == 200, history.get_json()
    entries = history.get_json()["data"]["items"]
    assert {entry["company_id"] for entry in entries} == {first_company}
    assert {entry["user"]["id"] for entry in entries} >= {first_id, second_id, str(admin_user.id)}
    assert {"SHIPMENT_CREATED", "SHIPMENT_UPDATED", "DOCUMENT_UPLOADED"} <= {entry["action"] for entry in entries}
    for entry in entries:
        assert not {"metadata", "ip_address", "request_id"} & entry.keys()
        assert "username" not in entry["user"]
    assert customer.get(f"/companies/{second_company}/activity").status_code == 403
    assert customer.get(f"/companies/{uuid.uuid4()}/activity").status_code == 403
    assert second.get(f"/companies/{first_company}/activity").status_code == 403
    latest = admin.get(f"/companies/{first_company}").get_json()["data"]["last_activity"]
    assert latest["user"]["id"] == second_id
    assert latest["action"] == "DOCUMENT_UPLOADED"
    assert customer.get("/dashboard/summary").get_json()["data"]["company"]["last_activity"]["id"] == latest["id"]
    assert admin.get(f"/companies/{first_company}/activity").status_code == 200
    filtered_audit = admin.get(f"/audit-logs?company_id={first_company}").get_json()["data"]["items"]
    assert all(entry["entity_id"] != second_company for entry in filtered_audit)


def test_inactive_company_blocks_company_account_not_shared_staff(factory, app):
    admin = factory.login(factory.admin())
    company = create_company(admin, "PAUSED", "paused-company")
    admin.post("/users", json={"username": "independent-staff", "full_name": "کارمند", "password": DEFAULT_PASSWORD})
    customer = login(app, "paused-company")
    assert admin.patch(f"/companies/{company}", json={"is_active": False}).status_code == 200
    assert customer.get("/shipments").status_code == 401
    assert Api(app).login("paused-company").status_code == 403
    assert login(app, "independent-staff").get("/companies").status_code == 200
