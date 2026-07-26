"""Shared logging setup for every Python entry point in this project.

logs/app.log accumulates across every run (FileHandler defaults to append
mode, and nothing here rotates or truncates it), so it reads as the full
history of every `make init-db` / `make seed` invocation, not just the most
recent one.
"""

import logging
import os
import sys

LOG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "logs")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "app.log")

_LOG_FORMAT = "[%(asctime)s] [%(levelname)s] [%(name)s]: %(message)s"
_DATE_FORMAT = "%Y-%m-%d %H:%M:%S"


class _ColorFormatter(logging.Formatter):
    """Wraps WARNING/ERROR lines in ANSI colour so they stand out while
    scrolling past a wall of INFO lines (e.g. 33 replenishment warnings
    during `make seed`). INFO/DEBUG are left uncoloured.

    Console-only: never applied to the file handler below, since raw ANSI
    escape codes would show up as garbled control characters when
    logs/app.log is opened in a plain text editor rather than a terminal.
    """

    _COLOR_BY_LEVEL = {
        logging.WARNING: "\033[33m",  # yellow
        logging.ERROR: "\033[31m",  # red
        logging.CRITICAL: "\033[1;31m",  # bold red
    }
    _RESET = "\033[0m"

    def format(self, record: logging.LogRecord) -> str:
        message = super().format(record)
        color = self._COLOR_BY_LEVEL.get(record.levelno)
        return f"{color}{message}{self._RESET}" if color else message


def get_logger(name: str = "inventory_system") -> logging.Logger:
    """Return a logger under `name` that writes to both stdout and logs/app.log.

    Safe to call repeatedly with the same name (e.g. once per module import):
    the `if not logger.handlers` guard stops duplicate handlers from piling up
    and double-printing every line, since `logging.getLogger(name)` always
    returns the same singleton instance for a given name.
    """
    logger = logging.getLogger(name)

    if not logger.handlers:
        logger.setLevel(logging.INFO)
        plain_formatter = logging.Formatter(_LOG_FORMAT, datefmt=_DATE_FORMAT)

        # 1. Console Handler (stdout) - what you see while a command runs.
        # Colour only kicks in for a real terminal (sys.stdout.isatty());
        # piping/redirecting output (e.g. `make seed > out.txt`, or a CI log
        # collector that doesn't render ANSI) falls back to the plain
        # formatter so escape codes never end up baked into captured text.
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(
            _ColorFormatter(_LOG_FORMAT, datefmt=_DATE_FORMAT)
            if sys.stdout.isatty()
            else plain_formatter
        )
        logger.addHandler(console_handler)

        # 2. File Handler (logs/app.log) - the same lines, persisted, always
        # plain text regardless of the console's colouring.
        file_handler = logging.FileHandler(LOG_FILE)
        file_handler.setFormatter(plain_formatter)
        logger.addHandler(file_handler)

    return logger
