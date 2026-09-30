from pathlib import Path

from notes_api.migrate import DEFAULT_DIR, discover


def test_discover_sorts_by_name_and_ignores_other_files(tmp_path):
    (tmp_path / "002_second.sql").write_text("SELECT 2;", encoding="utf-8")
    (tmp_path / "001_first.sql").write_text("SELECT 1;", encoding="utf-8")
    (tmp_path / "README.txt").write_text("not a migration", encoding="utf-8")
    assert [name for name, _ in discover(tmp_path)] == ["001_first.sql", "002_second.sql"]


def test_shipped_migrations_are_numbered_and_non_empty():
    found = discover(Path(DEFAULT_DIR))
    assert found, "no migrations shipped"
    names = [name for name, _ in found]
    assert all(name[:3].isdigit() and name[3] == "_" for name in names)
    assert all(sql.strip() for _, sql in found)
