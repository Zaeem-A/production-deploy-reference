import json
import logging
import sys

from notes_api.logging_setup import JsonFormatter


def _record(message="hello %s", args=("world",), exc_info=None):
    return logging.LogRecord("test", logging.INFO, __file__, 1, message, args, exc_info)


def test_json_line_with_extra_fields():
    record = _record()
    record.fields = {"request_id": "abc", "status": 200}
    line = JsonFormatter().format(record)
    payload = json.loads(line)
    assert "\n" not in line
    assert payload["msg"] == "hello world"
    assert payload["level"] == "info"
    assert payload["request_id"] == "abc"
    assert payload["ts"].endswith("Z")


def test_exception_is_included():
    try:
        raise ValueError("boom")
    except ValueError:
        record = _record("failed", (), sys.exc_info())
    payload = json.loads(JsonFormatter().format(record))
    assert "ValueError: boom" in payload["exc"]
