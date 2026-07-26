"""Shared pytest fixtures.

Isolation strategy: the schema is applied once per session, then every test runs
inside a transaction that is rolled back on teardown. This keeps tests order
independent and leaves any seeded demo data untouched.

Consequence for sql/03_procedures.sql: the procedures must NOT issue their own
COMMIT or ROLLBACK. Transaction control belongs to the caller - that is what
makes sp_place_order atomic from the client's point of view and what allows
these fixtures to undo it.
"""

import psycopg2
import pytest

from src.utils import INIT_SCRIPTS, execute_sql_files, get_db_connection


@pytest.fixture(scope="session", autouse=True)
def initialised_database():
    """Apply schema, triggers, procedures and views once for the whole session."""
    try:
        execute_sql_files(INIT_SCRIPTS)
    except psycopg2.OperationalError as exc:
        pytest.exit(
            f"Cannot reach PostgreSQL - run `make up` first.\n{exc}",
            returncode=1,
        )


@pytest.fixture
def conn(initialised_database):
    """A connection whose work is always rolled back after the test."""
    connection = get_db_connection()
    try:
        yield connection
    finally:
        connection.rollback()
        connection.close()


@pytest.fixture
def db_connection(conn):
    """Alias for `conn` matching the parameter name used in test_triggers.py
    and test_procedures.py."""
    return conn


@pytest.fixture
def cur(conn):
    """A cursor on the rolled-back connection."""
    with conn.cursor() as cursor:
        yield cursor


# ---------------------------------------------------------------------------
# Factories - keep these column lists in step with sql/01_schema.sql
# ---------------------------------------------------------------------------


@pytest.fixture
def make_customer(cur):
    """Insert a customer and return its customer_id."""
    counter = {"n": 0}

    def _make(full_name="Test Customer", email=None, phone_number="+250700000000"):
        counter["n"] += 1
        cur.execute(
            """
            INSERT INTO customers (full_name, email, phone_number)
            VALUES (%s, %s, %s)
            RETURNING customer_id
            """,
            (full_name, email or f"test.customer.{counter['n']}@example.com", phone_number),
        )
        return cur.fetchone()[0]

    return _make


@pytest.fixture
def make_product(cur):
    """Insert a product and return its product_id."""

    def _make(
        product_name="Test Product",
        category="Testing",
        unit_price=100.00,
        stock_quantity=500,
        reorder_level=10,
        reorder_quantity=50,
    ):
        cur.execute(
            """
            INSERT INTO products (
                product_name, category, unit_price,
                stock_quantity, reorder_level, reorder_quantity
            )
            VALUES (%s, %s, %s, %s, %s, %s)
            RETURNING product_id
            """,
            (
                product_name,
                category,
                unit_price,
                stock_quantity,
                reorder_level,
                reorder_quantity,
            ),
        )
        return cur.fetchone()[0]

    return _make
