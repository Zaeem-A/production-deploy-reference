import pytest

from notes_api.config import Settings


@pytest.fixture
def settings() -> Settings:
    return Settings(
        env="test",
        version="test",
        log_level="WARNING",
        db_host="unused",
        db_port=5432,
        db_name="unused",
        db_user="unused",
        db_password="unused",
        db_pool_max=1,
    )
