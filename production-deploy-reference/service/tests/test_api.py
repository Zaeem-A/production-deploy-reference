import dataclasses

import pytest
from fastapi.testclient import TestClient

from notes_api.main import create_app
from notes_api.store import InMemoryNoteStore


@pytest.fixture
def store() -> InMemoryNoteStore:
    return InMemoryNoteStore()


@pytest.fixture
def client(settings, store):
    with TestClient(create_app(settings=settings, store=store)) as test_client:
        yield test_client


def test_index_reports_version_and_env(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"service": "notes-api", "version": "test", "env": "test"}


def test_healthz_is_independent_of_the_database(settings):
    app = create_app(settings=settings, store=InMemoryNoteStore(healthy=False))
    with TestClient(app) as test_client:
        assert test_client.get("/healthz").json() == {"status": "ok"}


def test_readyz_follows_database_health(settings):
    store = InMemoryNoteStore()
    with TestClient(create_app(settings=settings, store=store)) as test_client:
        assert test_client.get("/readyz").status_code == 200
        store.healthy = False
        response = test_client.get("/readyz")
        assert response.status_code == 503
        assert response.json() == {"status": "unavailable"}


def test_create_then_read_notes(client):
    created = client.post("/api/notes", json={"text": "first"})
    assert created.status_code == 201
    note_id = created.json()["id"]

    assert client.get(f"/api/notes/{note_id}").json()["text"] == "first"

    client.post("/api/notes", json={"text": "second"})
    listing = client.get("/api/notes").json()
    assert [n["text"] for n in listing] == ["second", "first"]
    assert len(client.get("/api/notes", params={"limit": 1}).json()) == 1


@pytest.mark.parametrize("payload", [{"text": ""}, {"text": "x" * 2001}, {}])
def test_invalid_note_is_rejected(client, payload):
    assert client.post("/api/notes", json=payload).status_code == 422


def test_limit_is_bounded(client):
    assert client.get("/api/notes", params={"limit": 0}).status_code == 422
    assert client.get("/api/notes", params={"limit": 201}).status_code == 422


def test_missing_note_is_404(client):
    assert client.get("/api/notes/999").status_code == 404


def test_request_id_is_echoed_or_generated(client):
    assert client.get("/healthz", headers={"X-Request-ID": "abc-123"}).headers["x-request-id"] == (
        "abc-123"
    )
    generated = client.get("/healthz").headers["x-request-id"]
    assert len(generated) == 32


def test_metrics_count_requests_by_route_template(client):
    client.post("/api/notes", json={"text": "hello"})
    client.get("/api/notes/1")
    client.get("/api/notes/424242")
    body = client.get("/metrics").text
    assert 'http_requests_total{method="GET",path="/api/notes/{note_id}",status="200"} 1.0' in body
    assert 'http_requests_total{method="GET",path="/api/notes/{note_id}",status="404"} 1.0' in body
    assert 'path="/api/notes/424242"' not in body
    assert "http_request_duration_seconds_bucket" in body


def test_unknown_paths_share_one_label(client):
    client.get("/does-not-exist")
    client.get("/also-missing")
    body = client.get("/metrics").text
    assert 'http_requests_total{method="GET",path="unmatched",status="404"} 2.0' in body


def test_metrics_endpoint_does_not_count_itself(client):
    client.get("/metrics")
    assert 'path="/metrics"' not in client.get("/metrics").text


def test_api_docs_are_disabled_in_production(settings):
    production = dataclasses.replace(settings, env="production")
    with TestClient(create_app(settings=production, store=InMemoryNoteStore())) as test_client:
        assert test_client.get("/docs").status_code == 404
        assert test_client.get("/openapi.json").status_code == 404
