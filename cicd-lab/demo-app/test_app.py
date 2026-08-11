from app import app


def test_index_returns_200():
    client = app.test_client()
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"demo-app" in resp.data


def test_health_returns_ok():
    client = app.test_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"
