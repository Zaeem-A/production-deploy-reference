import pytest

from notes_api.config import Settings, read_secret


def test_defaults_and_parsing():
    settings = Settings.from_env({"DB_PASSWORD": "pw", "DB_PORT": "6543", "LOG_LEVEL": "debug"})
    assert settings.db_port == 6543
    assert settings.log_level == "DEBUG"
    assert settings.db_host == "localhost"
    assert settings.env == "development"
    assert settings.db_pool_max == 5


def test_password_file_wins_over_env(tmp_path):
    secret = tmp_path / "db_password"
    secret.write_text("from-file\n", encoding="utf-8")
    env = {"DB_PASSWORD": "from-env", "DB_PASSWORD_FILE": str(secret)}
    assert read_secret("DB_PASSWORD", env) == "from-file"


def test_missing_password_is_an_error():
    with pytest.raises(RuntimeError, match="DB_PASSWORD"):
        Settings.from_env({})


def test_conninfo_quotes_special_characters():
    settings = Settings.from_env({"DB_PASSWORD": "pa'ss\\word", "DB_HOST": "db"})
    assert "password='pa\\'ss\\\\word'" in settings.db_conninfo
    assert "host='db'" in settings.db_conninfo
