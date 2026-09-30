from notes_api.store import InMemoryNoteStore


def test_add_get_latest_order():
    store = InMemoryNoteStore()
    first = store.add("one")
    second = store.add("two")
    assert store.get(first.id) == first
    assert store.get(999) is None
    assert [n.text for n in store.latest()] == ["two", "one"]
    assert store.latest(limit=1) == [second]


def test_ping_reflects_health():
    assert InMemoryNoteStore().ping() is True
    assert InMemoryNoteStore(healthy=False).ping() is False
