"""Transport workflow, exact codes and private country quotas."""

from tests.support import DEFAULT_PASSWORD, Api, upload_file


def test_transport_workflow(factory, app):
    admin = factory.login(factory.admin())
    response = admin.post("/transport/companies", json={"name": "شرکت فقط نام"})
    assert response.status_code == 201, response.get_json()
    company = response.get_json()["data"]["id"]
    assert response.get_json()["data"]["account_username"] is None
    response = admin.post(
        f"/transport/companies/{company}/account", json={"username": "transport-customer", "password": DEFAULT_PASSWORD}
    )
    assert response.status_code == 201, response.get_json()
    employees = []
    for index, country in enumerate(["CI", "CI", "UZ"]):
        response = admin.post(
            "/transport/employees",
            json={
                "full_name": f"کارمند {index}",
                "username": f"transport-{index}",
                "password": DEFAULT_PASSWORD,
                "country": country,
            },
        )
        assert response.status_code == 201, response.get_json()
        employees.append(response.get_json()["data"]["id"])
    payload = {
        "company_id": company,
        "tracking_code": " Any / متن 😃 ",
        "countries": ["CI", "KZ"],
        "upload_limit": 1,
        "truck_count": 2,
        "border_count": 0,
        "employee_ids": employees[:2],
    }
    invalid = admin.post("/transport/shipments", json={**payload, "employee_ids": [employees[2]]})
    assert invalid.status_code == 422, invalid.get_json()
    response = admin.post("/transport/shipments", json=payload)
    assert response.status_code == 201, response.get_json()
    shipment = response.get_json()["data"]["id"]
    assert response.get_json()["data"]["tracking_code"] == payload["tracking_code"]
    assert admin.post("/transport/shipments", json=payload).status_code == 409
    assert (
        admin.post(
            "/transport/shipments", json={**payload, "tracking_code": payload["tracking_code"].strip()}
        ).status_code
        == 201
    )
    assert (
        admin.post(
            "/transport/shipments", json={**payload, "tracking_code": payload["tracking_code"].upper()}
        ).status_code
        == 201
    )
    detail = admin.get(f"/transport/shipments/{shipment}")
    assert detail.status_code == 200, detail.get_json()
    assert len(detail.get_json()["data"]["groups"]) == 4
    clients = []
    for index in range(3):
        client = Api(app)
        response = client.login(f"transport-{index}")
        client.token = response.get_json()["data"]["access_token"]
        clients.append(client)
    first, second, outsider = clients
    assert outsider.get(f"/transport/shipments/{shipment}").status_code == 404
    assert outsider.get("/transport/shipments").get_json()["data"]["items"] == []
    for client, filename in [(first, "one.any"), (second, "two.exe")]:
        response = client.post(
            f"/transport/shipments/{shipment}/files",
            data={"country": "KZ", "files": upload_file(filename, b"whatever")},
        )
        assert response.status_code == 201, response.get_json()
    data = first.get(f"/transport/shipments/{shipment}").get_json()["data"]
    assert len(data["groups"]) == 1
    assert data["groups"][0]["country"] == "CI"
    assert len(data["groups"][0]["files"]) == 1
    first_file = data["groups"][0]["files"][0]["id"]
    assert second.get(f"/documents/{first_file}/download").status_code == 404
    assert outsider.get(f"/documents/{first_file}/download").status_code == 404
    assert (
        first.post(f"/transport/shipments/{shipment}/files", data={"files": upload_file("extra", b"x")}).status_code
        == 422
    )
    for country in ["CI", "KZ"]:
        response = admin.post(
            f"/transport/shipments/{shipment}/files",
            data={"country": country, "files": upload_file("admin.bin", b"admin")},
        )
        assert response.status_code == 201, response.get_json()
    customer = Api(app)
    response = customer.login("transport-customer")
    customer.token = response.get_json()["data"]["access_token"]
    response = customer.get(f"/transport/shipments/{shipment}")
    assert response.status_code == 200, response.get_json()
    assert sum(len(group["files"]) for group in response.get_json()["data"]["groups"]) == 4
    assert customer.get(f"/documents/{first_file}/download").status_code == 200
    assert (
        customer.post(f"/transport/shipments/{shipment}/files", data={"files": upload_file("no", b"x")}).status_code
        == 403
    )
    response = admin.patch(f"/transport/shipments/{shipment}/code", json={"tracking_code": " X\nY "})
    assert response.status_code == 200, response.get_json()
    assert response.get_json()["data"]["tracking_code"] == " X\nY "


def test_transport_tenant_scope_and_unbounded_exact_codes(factory, app):
    admin = factory.login(factory.admin())
    companies = []
    customers = []
    for index in range(2):
        company = admin.post("/transport/companies", json={"name": f"company {index}"}).get_json()["data"]["id"]
        companies.append(company)
        assert (
            admin.post(
                f"/transport/companies/{company}/account",
                json={"username": f"tenant-{index}", "password": DEFAULT_PASSWORD},
            ).status_code
            == 201
        )
        client = Api(app)
        response = client.login(f"tenant-{index}")
        client.token = response.get_json()["data"]["access_token"]
        customers.append(client)
    code = " \n" + "بار / Aa!?🙂" * 500 + " "
    response = admin.post(
        "/transport/shipments",
        json={
            "company_id": companies[0],
            "tracking_code": code,
            "countries": ["CI"],
            "upload_limit": 2,
            "truck_count": 1,
            "border_count": 0,
        },
    )
    assert response.status_code == 201, response.get_json()
    shipment = response.get_json()["data"]["id"]
    assert response.get_json()["data"]["tracking_code"] == code
    assert len(customers[0].get("/transport/shipments").get_json()["data"]["items"]) == 1
    assert customers[1].get("/transport/shipments").get_json()["data"]["items"] == []
    assert customers[1].get(f"/transport/shipments/{shipment}").status_code == 404
    assert customers[1].get(f"/transport/shipments?company_id={companies[0]}").get_json()["data"]["items"] == []
    assert customers[0].patch(f"/transport/shipments/{shipment}/code", json={"tracking_code": "no"}).status_code == 403
    assert customers[0].get("/transport/employees").status_code == 403
    assert customers[0].post("/transport/companies", json={"name": "no"}).status_code == 403
