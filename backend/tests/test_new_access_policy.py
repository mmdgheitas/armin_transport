"""Regression tests for account-only tracking and private employee file quotas."""

from app.extensions import db
from app.models import UserRole
from tests.support import Api, upload_file


def test_tracking_requires_login(app):
    response = Api(app).post("/customer/lookup", json={"tracking_code": "SOME-CODE"})
    assert response.status_code == 401


def test_employee_files_are_private_and_quota_is_cumulative(factory):
    company = factory.company()
    first = factory.employee(company)
    second = factory.employee(company)
    shipment = factory.shipment(company, first)
    a, b = factory.login(first), factory.login(second)
    response = a.upload(shipment.id, [upload_file(f"file{i}.exe", b"MZ anything") for i in range(12)])
    assert response.status_code == 201, response.get_json()
    doc = response.get_json()["data"][0]["id"]
    assert a.upload(shipment.id, [upload_file("extra.bin", b"x")]).status_code == 422
    assert b.get(f"/shipments/{shipment.id}/documents").get_json()["data"]["items"] == []
    assert b.get(f"/documents/{doc}/download").status_code == 404
    assert b.upload(shipment.id, [upload_file("second.zip", b"anything")]).status_code == 201
    admin = factory.login(factory.admin())
    assert len(admin.get(f"/shipments/{shipment.id}/documents").get_json()["data"]["items"]) == 13
    # The tracking-code portal cannot bypass employee file isolation.
    assert b.post("/customer/lookup", json={"tracking_code": shipment.tracking_code}).status_code == 404


def test_customer_can_read_company_files_but_not_other_company(factory, app):
    company = factory.company()
    employee = factory.employee(company)
    shipment = factory.shipment(company, employee)
    other_company = factory.company()
    other = factory.shipment(other_company, factory.employee(other_company))
    customer = factory.employee(company)
    with app.app_context():
        row = db.session.get(type(customer), customer.id)
        row.role = UserRole.CUSTOMER
        db.session.commit()
    api = factory.login(customer)
    assert api.get(f"/shipments/{shipment.id}").status_code == 200
    assert api.get(f"/shipments/{other.id}").status_code == 404
    assert api.upload(shipment.id, [upload_file("a.bin", b"x")]).status_code == 403
    assert api.post("/customer/lookup", json={"tracking_code": other.tracking_code}).status_code == 404
    grant = api.post("/customer/lookup", json={"tracking_code": shipment.tracking_code})
    assert grant.status_code == 200, grant.get_json()
    token = grant.get_json()["data"]["access_token"]
    assert Api(app).get(f"/customer/access/{token}/shipment").status_code == 401
    assert api.get(f"/customer/access/{token}/shipment").status_code == 200
    assert api.get(f"/customer/access/{token}/documents").status_code == 200
