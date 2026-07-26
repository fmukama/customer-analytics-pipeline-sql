"""Database connection helper and .sql file runner.

Used by tests/conftest.py to bootstrap the schema before the test session,
and available for any other Python entry point that needs a connection or
needs to apply a .sql file. `make init-db` itself does NOT go through this
module - it calls `psql -f` directly inside the postgres container (see the
Makefile) - so this module's own logging only ever reflects what pytest (or
a script you write) actually invoked.
"""

import os
from collections.abc import Iterable, Sequence

import psycopg2
from dotenv import load_dotenv
from psycopg2.extensions import connection

from src.logger import get_logger

load_dotenv()
logger = get_logger("db_utils")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SQL_DIR = os.path.join(REPO_ROOT, "sql")

# Single source of truth for the bootstrap order. `make init-db` applies the
# same four files in the same sequence via psql inside the container; keep both
# in step. 05_reports_and_queries.sql and 06_demo.sql are read-only and are
# deliberately excluded - they are run on demand, not during bootstrap.
INIT_SCRIPTS: tuple[str, ...] = (
    "01_schema.sql",
    "02_triggers.sql",
    "03_procedures.sql",
    "04_views.sql",
)


def get_db_connection() -> connection:
    """Open a new connection to PostgreSQL using the POSTGRES_* env vars.

    autocommit is left False (the default) - callers own their own
    transaction boundaries via conn.commit() / conn.rollback().
    """
    try:
        conn = psycopg2.connect(
            host=os.getenv("POSTGRES_HOST", "localhost"),
            port=int(os.getenv("POSTGRES_PORT", "5432")),
            dbname=os.getenv("POSTGRES_DB", "ecom_inventory"),
            user=os.getenv("POSTGRES_USER", "postgres"),
            password=os.getenv("POSTGRES_PASSWORD", "postgres"),
        )
        conn.autocommit = False
        return conn
    except Exception as exc:
        logger.error(f"Failed to connect to PostgreSQL database: {exc}")
        raise


def resolve_sql_path(file_path: str) -> str:
    """Turn a bare script name ("01_schema.sql"), a repo-relative path
    ("sql/01_schema.sql"), or an absolute path into an absolute path.

    A bare filename with no directory component is assumed to live in sql/,
    which is what lets INIT_SCRIPTS above list plain filenames.
    """
    if os.path.isabs(file_path):
        return file_path
    if os.path.dirname(file_path):
        return os.path.join(REPO_ROOT, file_path)
    return os.path.join(SQL_DIR, file_path)


def execute_sql_file(file_path: str) -> None:
    """Reads and executes a raw .sql file within an atomic transaction.

    The whole file is sent as one statement batch, so the scripts must contain
    pure SQL only - psql meta-commands such as \\i or \\echo are not understood
    by this path and would abort the transaction.
    """
    resolved = resolve_sql_path(file_path)

    if not os.path.exists(resolved):
        logger.error(f"SQL file not found at path: {resolved}")
        raise FileNotFoundError(f"Missing SQL file: {resolved}")

    logger.info(f"Executing SQL file: {resolved}")
    conn = get_db_connection()

    try:
        with conn.cursor() as cursor:
            with open(resolved, encoding="utf-8") as handle:
                cursor.execute(handle.read())
        conn.commit()
        logger.info(f"Successfully executed: {resolved}")
    except Exception as exc:
        conn.rollback()
        logger.error(f"Error executing {resolved}. Transaction rolled back. Details: {exc}")
        raise
    finally:
        conn.close()


def execute_sql_files(file_paths: Iterable[str] = INIT_SCRIPTS) -> None:
    """Applies several .sql files in order, stopping at the first failure."""
    for file_path in file_paths:
        execute_sql_file(file_path)


def fetch_all(query: str, params: Sequence | None = None) -> list[tuple]:
    """Convenience read helper used by the seeder and the test suite."""
    conn = get_db_connection()
    try:
        with conn.cursor() as cursor:
            cursor.execute(query, params)
            return cursor.fetchall()
    finally:
        conn.close()
