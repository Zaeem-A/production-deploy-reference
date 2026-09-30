"""Runs against a real Postgres. CI provides one.

Locally: TEST_DATABASE_URL=postgresql://user:pw@localhost/notes_test pytest
The database name must end in _test because the fixture drops the tables.
"""

import os

import pytest

from notes_api.migrate import DEFAULT_DIR, apply
from notes_api.store import PostgresNoteStore

URL = os.environ.get("TEST_DATABASE_URL")

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not URL, reason="TEST_DATABASE_URL is not set"),
]


@pytest.fixture
def conninfo() -> str:
    import psycopg
    from psycopg.conninfo import conninfo_to_dict

    assert conninfo_to_dict(URL)["dbname"].endswith("_test"), "refusing to reset a non-test DB"
    with psycopg.connect(URL, autocommit=True) as conn:
        conn.execute("DROP TABLE IF EXISTS notes, schema_migrations")
    return URL


def test_migrations_apply_once(conninfo):
    assert apply(conninfo, DEFAULT_DIR) == ["001_create_notes.sql"]
    assert apply(conninfo, DEFAULT_DIR) == []


def test_store_roundtrip(conninfo):
    apply(conninfo, DEFAULT_DIR)
    store = PostgresNoteStore(conninfo, max_size=2)
    store.open()
    try:
        assert store.ping() is True
        first = store.add("first")
        second = store.add("second")
        assert store.get(first.id) == first
        assert store.get(999_999) is None
        assert [n.text for n in store.latest()] == ["second", "first"]
        assert store.latest(limit=1) == [second]
    finally:
        store.close()


def test_ping_is_false_when_database_is_unreachable():
    store = PostgresNoteStore("host=127.0.0.1 port=1 dbname=x user=x connect_timeout=1")
    store.open()
    try:
        assert store.ping() is False
    finally:
        store.close()
