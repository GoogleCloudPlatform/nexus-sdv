import sys
import structlog
from trip_analyzer.config.config import settings


def setup_logging():
    processors = [
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
    ]

    if settings.env == "dev":
        # Development: Pretty, colorful logs for the terminal
        processors.append(structlog.dev.ConsoleRenderer())
    else:
        # Production: JSON for Google Cloud Logging
        processors.append(structlog.processors.JSONRenderer())

    structlog.configure(
        processors=processors,
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


logger = structlog.get_logger()
