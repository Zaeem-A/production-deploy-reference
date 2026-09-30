"""Runtime configuration, read from environment variables.

Secrets follow the Docker convention: NAME_FILE points at a file (a Docker secret),
NAME holds the value directly. The file wins when both are set.
"""

import os
from dataclasses import dataclass
from pathlib import Path


def read_secret(name: str, environ: dict[str, str] | None = None) -> str | None:
    env = os.environ if environ is None else environ
    file_path = env.get(f"{name}_FILE")
    if file_path:
        return Path(file_path).read_text(encoding="utf-8").strip()
    return env.get(name)


def _quote(value: str) -> str:
    """Quote a value for a libpq key/value connection string."""
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


@dataclass(frozen=True)
class Settings:
    env: str
    version: str
    log_level: str
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str
    db_pool_max: int

    @property
    def db_conninfo(self) -> str:
        parts = {
            "host": self.db_host,
            "port": str(self.db_port),
            "dbname": self.db_name,
            "user": self.db_user,
            "password": self.db_password,
        }
        return " ".join(f"{key}={_quote(value)}" for key, value in parts.items())

    @classmethod
    def from_env(cls, environ: dict[str, str] | None = None) -> "Settings":
        env = os.environ if environ is None else environ
        password = read_secret("DB_PASSWORD", env)
        if not password:
            raise RuntimeError("DB_PASSWORD or DB_PASSWORD_FILE must be set")
        return cls(
            env=env.get("APP_ENV", "development"),
            version=env.get("APP_VERSION", "dev"),
            log_level=env.get("LOG_LEVEL", "INFO").upper(),
            db_host=env.get("DB_HOST", "localhost"),
            db_port=int(env.get("DB_PORT", "5432")),
            db_name=env.get("DB_NAME", "notes"),
            db_user=env.get("DB_USER", "notes"),
            db_password=password,
            db_pool_max=int(env.get("DB_POOL_MAX", "5")),
        )
