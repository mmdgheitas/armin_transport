"""End-to-end smoke test of the main business flow through the HTTP API."""

from __future__ import annotations

from tests.support import PDF_BYTES, Api, Factory, upload_file


def test_full_business_flow(api: Api, factory: Factory) -> None:
    admin = factory.admin()
    admin_api = factory.login(admin)

    # Company and employee management (SUPER_ADMIN)
    response = admin_api.post("/companies", json={"name": "حمل‌ونقل نمونه", "company_code": "sample-1"})
    assert response.status_code == 201, response.get_json()
    company = response.get_json()["data"]
    assert company["company_code"] == "SAMPLE-1"

    response = admin_api.post(
        "/users",
        json={
            "username": "Operator.One",
            "full_name": "کارمند نمونه",
            "password": "An0ther-Long-Passw0rd",
            "company_id": company["id"],
        },
    )
    assert response.status_code == 201, response.get_json()
    employee = response.get_json()["data"]
    assert employee["username"] == "operator.one"
    assert "password_hash" not in employee

    response = admin_api.post(
        "/product-fields",
        json={"field_key": "weight", "label": "وزن", "data_type": "DECIMAL", "is_customer_visible": True},
    )
    assert response.status_code == 201, response.get_json()

    # Employee flow
    login = api.login("operator.one", "An0ther-Long-Passw0rd")
    assert login.status_code == 200, login.get_json()
    employee_api = Api(api._app, login.get_json()["data"]["access_token"])

    response = employee_api.post("/shipments", json={"description": "بار نمونه", "product_values": {"weight": "12.50"}})
    assert response.status_code == 201, response.get_json()
    shipment = response.get_json()["data"]
    assert shipment["tracking_code_type"] == "AUTO"
    assert shipment["company"]["id"] == company["id"]

    response = employee_api.upload(shipment["id"], [upload_file("بارنامه.pdf", PDF_BYTES, "application/pdf")])
    assert response.status_code == 201, response.get_json()
    document = response.get_json()["data"][0]
    assert document["original_name"] == "بارنامه.pdf"
    assert "storage_path" not in document

    response = employee_api.get(f"/documents/{document['id']}/download")
    assert response.status_code == 200
    assert response.data == PDF_BYTES
    assert response.headers["Content-Disposition"].startswith("attachment")

    # Customer flow
    response = api.post("/customer/lookup", json={"tracking_code": shipment["tracking_code"].lower()})
    assert response.status_code == 200, response.get_json()
    token = response.get_json()["data"]["access_token"]

    response = api.get(f"/customer/access/{token}/shipment")
    assert response.status_code == 200, response.get_json()
    summary = response.get_json()["data"]
    assert summary["tracking_code"] == shipment["tracking_code"]
    assert summary["product_details"] == [{"label": "وزن", "data_type": "DECIMAL", "value": "12.5"}]
    assert "id" not in summary

    response = api.get(f"/customer/access/{token}/documents")
    assert response.status_code == 200
    items = response.get_json()["data"]["items"]
    assert [item["name"] for item in items] == ["بارنامه.pdf"]

    response = api.get(f"/customer/access/{token}/documents/{items[0]['id']}/download")
    assert response.status_code == 200
    assert response.data == PDF_BYTES
