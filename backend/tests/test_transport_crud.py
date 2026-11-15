"""Transport CRUD authorization, non-destructive deletion, and edit invariants."""

from sqlalchemy import select

from app.extensions import db
from app.models import Document, User
from tests.support import DEFAULT_PASSWORD, Api, upload_file


def workspace(factory, app):
    admin = factory.login(factory.admin())
    company = admin.post("/transport/companies", json={"name": "Company"}).get_json()["data"]["id"]
    staff = []
    for index in range(2):
        user = admin.post(
            "/transport/employees",
            json={
                "full_name": f"Employee {index}",
                "username": f"crud-staff-{index}",
                "password": DEFAULT_PASSWORD,
                "country": "CI",
            },
        ).get_json()["data"]
        api = Api(app)
        api.token = api.login(user["username"]).get_json()["data"]["access_token"]
        staff.append((user, api))
    payload = {
        "company_id": company,
        "tracking_code": "CRUD exact ",
        "countries": ["CI", "KZ"],
        "upload_limit": 2,
        "truck_count": 1,
        "border_count": 0,
        "employee_ids": [user["id"] for user, _ in staff],
    }
    shipment = admin.post("/transport/shipments", json=payload).get_json()["data"]["id"]
    response = staff[0][1].post(
        f"/transport/shipments/{shipment}/files", data={"files": upload_file("before.bin", b"before")}
    )
    assert response.status_code == 201, response.get_json()
    document = response.get_json()["data"][0]["id"]
    return admin, company, staff, payload, shipment, document


def test_file_crud_and_employee_isolation(factory, app):
    admin, _, staff, _, shipment, document = workspace(factory, app)
    owner, coworker = staff[0][1], staff[1][1]
    for method, path, kwargs in [
        ("patch", f"/transport/files/{document}", {"json": {"original_name": "bad"}}),
        ("delete", f"/transport/files/{document}", {}),
        ("post", f"/transport/files/{document}/replace", {"data": {"files": upload_file("bad.bin", b"bad")}}),
    ]:
        assert getattr(coworker, method)(path, **kwargs).status_code == 404
    response = owner.patch(f"/transport/files/{document}", json={"original_name": "renamed.bin"})
    assert response.status_code == 200, response.get_json()
    assert response.get_json()["data"]["original_name"] == "renamed.bin"
    response = owner.post(
        f"/transport/files/{document}/replace", data={"files": upload_file("replacement.exe", b"after")}
    )
    assert response.status_code == 200, response.get_json()
    assert response.get_json()["data"]["id"] == document
    assert owner.get(f"/documents/{document}/download").data == b"after"
    assert len(owner.get(f"/transport/shipments/{shipment}").get_json()["data"]["groups"][0]["files"]) == 1
    assert owner.delete(f"/transport/files/{document}").status_code == 200
    assert owner.get(f"/documents/{document}/download").status_code == 404
    assert owner.post(f"/transport/files/{document}/restore").status_code == 403
    response = admin.get(f"/transport/shipments/{shipment}")
    assert len(response.get_json()["data"]["deleted_files"]) == 1
    assert admin.post(f"/transport/files/{document}/restore").status_code == 200
    assert owner.get(f"/documents/{document}/download").data == b"after"


def test_load_edits_reject_inconsistency_and_deletions_are_recoverable(factory, app):
    admin, company, staff, payload, shipment, document = workspace(factory, app)
    owner = staff[0][1]
    for changes in [{"countries": ["KZ"], "employee_ids": []}, {"employee_ids": []}]:
        response = admin.patch(f"/transport/shipments/{shipment}", json={**payload, **changes})
        assert response.status_code == 409, response.get_json()
    assert owner.patch(f"/transport/shipments/{shipment}", json=payload).status_code == 403
    response = admin.patch(f"/transport/shipments/{shipment}", json={**payload, "truck_count": 5})
    assert response.status_code == 200, response.get_json()
    assert response.get_json()["data"]["truck_count"] == 5
    assert admin.patch(f"/transport/employees/{staff[0][0]['id']}", json={"country": "KZ"}).status_code == 409
    assert admin.delete(f"/transport/shipments/{shipment}").status_code == 200
    assert owner.get(f"/transport/shipments/{shipment}").status_code == 404
    assert owner.get(f"/documents/{document}/download").status_code == 404
    assert len(admin.get("/transport/shipments?deleted=true").get_json()["data"]["items"]) == 1
    assert admin.post(f"/transport/shipments/{shipment}/restore").status_code == 200
    assert owner.get(f"/documents/{document}/download").status_code == 200
    assert admin.patch(f"/transport/companies/{company}", json={"name": "Renamed"}).status_code == 200
    assert admin.delete(f"/transport/companies/{company}").status_code == 200
    assert admin.get("/transport/shipments").get_json()["data"]["items"] == []
    assert owner.get(f"/documents/{document}/download").status_code == 404
    assert len(admin.get("/transport/companies?deleted=true").get_json()["data"]["items"]) == 1
    assert admin.post(f"/transport/companies/{company}/restore").status_code == 200
    assert owner.get(f"/documents/{document}/download").status_code == 200


def test_employee_account_crud_and_atomic_credentials(factory, app):
    admin, company, staff, _, _, _ = workspace(factory, app)
    employee = staff[0][0]
    response = admin.patch(f"/transport/employees/{employee['id']}", json={"full_name": "Updated", "password": "x"})
    assert response.status_code == 422, response.get_json()
    with app.app_context():
        assert (
            db.session.scalar(select(User).where(User.username == employee["username"])).full_name
            == employee["full_name"]
        )
    response = admin.patch(
        f"/transport/employees/{employee['id']}", json={"full_name": "Updated", "password": DEFAULT_PASSWORD + "2"}
    )
    assert response.status_code == 200, response.get_json()
    assert response.get_json()["data"]["full_name"] == "Updated"
    assert admin.delete(f"/transport/employees/{employee['id']}").status_code == 200
    assert staff[0][1].get("/transport/shipments").status_code == 401
    assert Api(app).login(employee["username"], DEFAULT_PASSWORD + "2").status_code == 403
    assert admin.post(f"/transport/employees/{employee['id']}/restore").status_code == 200
    assert Api(app).login(employee["username"], DEFAULT_PASSWORD + "2").status_code == 200
    path = f"/transport/companies/{company}/account"
    assert admin.post(path, json={"username": "crud-customer", "password": DEFAULT_PASSWORD}).status_code == 201
    assert (
        admin.patch(path, json={"username": "crud-customer-new", "password": DEFAULT_PASSWORD + "2"}).status_code == 200
    )
    assert admin.delete(path).status_code == 200
    assert Api(app).login("crud-customer-new", DEFAULT_PASSWORD + "2").status_code == 403
    assert admin.post(path + "/restore").status_code == 200
    assert Api(app).login("crud-customer-new", DEFAULT_PASSWORD + "2").status_code == 200
    with app.app_context():
        assert db.session.scalar(select(Document)) is not None


def test_quota_edits_restore_conflicts_and_replacement_at_capacity(factory, app):
    admin, _, staff, payload, shipment, document = workspace(factory, app)
    owner = staff[0][1]
    extra = owner.post(f"/transport/shipments/{shipment}/files", data={"files": upload_file("second", b"2")})
    assert extra.status_code == 201
    response = admin.patch(f"/transport/shipments/{shipment}", json={**payload, "upload_limit": 1})
    assert response.status_code == 409
    assert (
        owner.post(
            f"/transport/files/{document}/replace", data={"files": upload_file("replacement", b"new")}
        ).status_code
        == 200
    )
    assert owner.delete(f"/transport/files/{document}").status_code == 200
    assert (
        owner.post(f"/transport/shipments/{shipment}/files", data={"files": upload_file("third", b"3")}).status_code
        == 201
    )
    assert admin.post(f"/transport/files/{document}/restore").status_code == 409
    assert owner.get(f"/documents/{document}/download").status_code == 404
    assert admin.patch(f"/transport/shipments/{shipment}", json={**payload, "upload_limit": 3}).status_code == 200
    assert admin.post(f"/transport/files/{document}/restore").status_code == 200
    # Retained legacy endpoints cannot bypass the new admin-only load editing policy.
    assert owner.patch(f"/shipments/{shipment}", json={"description": "no"}).status_code == 403
    assert owner.put(f"/shipments/{shipment}/product-values", json={"values": {}}).status_code == 403
