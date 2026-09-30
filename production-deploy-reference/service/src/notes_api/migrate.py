"""Apply the SQL files in migrations/ in filename order. Run: python -m notes_api.migrate

Applied files are recorded in schema_migrations, so re-running is a no-op. An advisory lock
makes concurrent runners (two deploys at once) take turns instead of colliding.
"""

import logging
import os
import sys
from pathlib import Path

from .config import Settings
from .logging_setup import configure_logging

log = logging.getLogger("notes_api.migrate")

DEFAULT_DIR = Path(
    os.environ.get("MIGRATIONS_DIR", Path(__file__).resolve().parents[2] / "migrations")
)
LOCK_ID = 727274


def discover(directory: Path) -> list[tuple[str, str]]:
    files = sorted(directory.glob("*.sql"))
    return [(path.name, path.read_text(encoding="utf-8")) for path in files]


def apply(conninfo: str, directory: Path = DEFAULT_DIR) -> list[str]:
    import psycopg

    applied_now: list[str] = []
    with psycopg.connect(conninfo) as conn:
        # Lock first: two runners must not race on CREATE TABLE IF NOT EXISTS either.
        conn.execute("SELECT pg_advisory_xact_lock(%s)", (LOCK_ID,))
        conn.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations ("
            "name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
        )
        done = {row[0] for row in conn.execute("SELECT name FROM schema_migrations")}
        for name, sql in discover(directory):
            if name in done:
                continue
            conn.execute(sql)
            conn.execute("INSERT INTO schema_migrations (name) VALUES (%s)", (name,))
            applied_now.append(name)
    return applied_now


def main() -> int:
    settings = Settings.from_env()
    configure_logging(settings.log_level)
    applied = apply(settings.db_conninfo)
    log.info("migrations applied", extra={"fields": {"applied": applied}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
