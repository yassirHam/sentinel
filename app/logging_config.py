"""Structured (JSON) logging for the Sentinel sample service (S1.3).

Every log record is emitted as a single JSON line containing a timestamp,
level, logger name, message and any extra fields attached via ``extra={...}``.
Single-line JSON means a collector (Loki, CloudWatch, etc.) can ingest the
logs without a custom parser.
"""
from __future__ import annotations

import datetime as _dt
import json
import logging
import os
import sys

# Standard LogRecord attributes we do NOT want to duplicate into the JSON body;
# anything else passed via extra={...} is treated as a structured field.
_RESERVED = {
    "args", "asctime", "created", "exc_info", "exc_text", "filename",
    "funcName", "levelname", "levelno", "lineno", "module", "msecs",
    "message", "msg", "name", "pathname", "process", "processName",
    "relativeCreated", "stack_info", "thread", "threadName", "taskName",
}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": _dt.datetime.fromtimestamp(
                record.created, tz=_dt.timezone.utc
            ).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging() -> None:
    level = os.getenv("LOG_LEVEL", "INFO").upper()
    handler = logging.StreamHandler(stream=sys.stdout)
    handler.setFormatter(JsonFormatter())

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(level)

    # Quiet uvicorn's default access logger; our middleware logs requests.
    logging.getLogger("uvicorn.access").handlers.clear()
    logging.getLogger("uvicorn.access").propagate = False


def request_logger() -> logging.Logger:
    return logging.getLogger("sentinel.request")
