"""Persistence: a small interface, an in-memory version for tests, and the Postgres one."""

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol


@dataclass(frozen=True)
class Note:
    id: int
    text: str
    created_at: datetime


class NoteStore(Protocol):
    def ping(self) -> bool: ...

    def add(self, text: str) -> Note: ...

    def get(self, note_id: int) -> Note | None: ...

    def latest(self, limit: int = 50) -> list[Note]: ...

    def close(self) -> None: ...


class InMemoryNoteStore:
    """Used by the unit tests so the API can be tested without a database."""

    def __init__(self, healthy: bool = True) -> None:
        self.healthy = healthy
        self._notes: list[Note] = []

    def ping(self) -> bool:
        return self.healthy

    def add(self, text: str) -> Note:
        note = Note(id=len(self._notes) + 1, text=text, created_at=datetime.now(UTC))
        self._notes.append(note)
        return note

    def get(self, note_id: int) -> Note | None:
        return next((n for n in self._notes if n.id == note_id), None)

    def latest(self, limit: int = 50) -> list[Note]:
        return list(reversed(self._notes))[:limit]

    def close(self) -> None:
        return None


class PostgresNoteStore:
    """Postgres via psycopg 3 with a connection pool."""

    def __init__(self, conninfo: str, max_size: int = 5) -> None:
        # Imported here so the modules above stay importable without the driver.
        from psycopg_pool import ConnectionPool

        self._pool = ConnectionPool(conninfo, min_size=1, max_size=max_size, open=False)

    def open(self) -> None:
        # wait=False: start even if the database is not up yet. /readyz reports 503
        # until the pool can connect, which is what a load balancer should see.
        self._pool.open(wait=False)

    def ping(self) -> bool:
        try:
            with self._pool.connection(timeout=2) as conn:
                conn.execute("SELECT 1")
        except Exception:
            return False
        return True

    def add(self, text: str) -> Note:
        with self._pool.connection() as conn:
            row = conn.execute(
                "INSERT INTO notes (text) VALUES (%s) RETURNING id, text, created_at",
                (text,),
            ).fetchone()
        return Note(*row)

    def get(self, note_id: int) -> Note | None:
        with self._pool.connection() as conn:
            row = conn.execute(
                "SELECT id, text, created_at FROM notes WHERE id = %s", (note_id,)
            ).fetchone()
        return Note(*row) if row else None

    def latest(self, limit: int = 50) -> list[Note]:
        with self._pool.connection() as conn:
            rows = conn.execute(
                "SELECT id, text, created_at FROM notes ORDER BY id DESC LIMIT %s", (limit,)
            ).fetchall()
        return [Note(*row) for row in rows]

    def close(self) -> None:
        self._pool.close()
