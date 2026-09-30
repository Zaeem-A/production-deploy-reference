"""FastAPI application factory: routes, request middleware, lifespan."""

import logging
import time
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field
from starlette.routing import Match

from .config import Settings
from .logging_setup import configure_logging
from .metrics import Metrics
from .store import Note, NoteStore, PostgresNoteStore

log = logging.getLogger("notes_api")


class NoteIn(BaseModel):
    text: str = Field(min_length=1, max_length=2000)


class NoteOut(BaseModel):
    id: int
    text: str
    created_at: datetime

    @classmethod
    def from_note(cls, note: Note) -> "NoteOut":
        return cls(id=note.id, text=note.text, created_at=note.created_at)


def get_store(request: Request) -> NoteStore:
    return request.app.state.store


StoreDep = Annotated[NoteStore, Depends(get_store)]


def route_template(request: Request) -> str:
    """The route pattern (/api/notes/{note_id}), not the raw path, to keep metric labels bounded."""
    route = request.scope.get("route")
    if route is not None:
        return route.path
    for candidate in request.app.routes:
        match, _ = candidate.matches(request.scope)
        if match == Match.FULL:
            return candidate.path
    return "unmatched"


def create_app(settings: Settings | None = None, store: NoteStore | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    configure_logging(settings.log_level)
    metrics = Metrics()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        owns_store = app.state.store is None
        if owns_store:
            pg_store = PostgresNoteStore(settings.db_conninfo, max_size=settings.db_pool_max)
            pg_store.open()
            app.state.store = pg_store
        log.info("started", extra={"fields": {"version": settings.version, "env": settings.env}})
        yield
        if owns_store:
            app.state.store.close()
        log.info("stopped")

    production = settings.env == "production"
    app = FastAPI(
        title="notes-api",
        version=settings.version,
        lifespan=lifespan,
        docs_url=None if production else "/docs",
        redoc_url=None,
        openapi_url=None if production else "/openapi.json",
    )
    app.state.store = store

    @app.middleware("http")
    async def observe(request: Request, call_next):
        started = time.perf_counter()
        request_id = (request.headers.get("x-request-id") or uuid.uuid4().hex)[:64]
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            response.headers["X-Request-ID"] = request_id
            return response
        finally:
            seconds = time.perf_counter() - started
            path = route_template(request)
            if path != "/metrics":
                metrics.observe(request.method, path, status, seconds)
                log.info(
                    "request",
                    extra={
                        "fields": {
                            "request_id": request_id,
                            "method": request.method,
                            "path": request.url.path,
                            "route": path,
                            "status": status,
                            "duration_ms": round(seconds * 1000, 2),
                        }
                    },
                )

    @app.get("/")
    def index() -> dict[str, str]:
        return {"service": "notes-api", "version": settings.version, "env": settings.env}

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        """Liveness: the process is up. Does not touch the database."""
        return {"status": "ok"}

    @app.get("/readyz")
    def readyz(response: Response, store: StoreDep) -> dict[str, str]:
        """Readiness: the app can serve traffic, i.e. the database answers."""
        if store.ping():
            return {"status": "ready"}
        response.status_code = 503
        return {"status": "unavailable"}

    @app.get("/metrics", include_in_schema=False)
    def metrics_endpoint() -> Response:
        body, content_type = metrics.render()
        return Response(content=body, media_type=content_type)

    @app.post("/api/notes", response_model=NoteOut, status_code=201)
    def create_note(payload: NoteIn, store: StoreDep) -> NoteOut:
        return NoteOut.from_note(store.add(payload.text))

    @app.get("/api/notes", response_model=list[NoteOut])
    def list_notes(store: StoreDep, limit: Annotated[int, Query(ge=1, le=200)] = 50):
        return [NoteOut.from_note(note) for note in store.latest(limit)]

    @app.get("/api/notes/{note_id}", response_model=NoteOut)
    def get_note(note_id: int, store: StoreDep) -> NoteOut:
        note = store.get(note_id)
        if note is None:
            raise HTTPException(status_code=404, detail="note not found")
        return NoteOut.from_note(note)

    return app
