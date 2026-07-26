"""Schema integrity tests (sql/01_schema.sql).

Every test here tries to break a constraint and asserts that PostgreSQL - not
application code - is what stops it: CHECK constraints, FOREIGN KEY
references, the UNIQUE (order_id, product_id) pair, the generated `subtotal`
column, and ON DELETE CASCADE/RESTRICT behaviour. If one of these starts
failing after a schema change, that change silently weakened a data
integrity guarantee the brief requires.
"""

import psycopg2
import pytest


def test_customers_defaults_and_tier_check(db_connection):
    """Verifies default values and the Bronze/Silver/Gold CHECK constraint."""
    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Schema User', 'schema@test.com') "
            "RETURNING total_spent, customer_tier;"
        )
        total_spent, tier = cursor.fetchone()
        assert total_spent == 0.00
        assert tier == "Bronze"

        with pytest.raises(psycopg2.errors.CheckViolation):
            cursor.execute(
                "INSERT INTO customers (full_name, email, customer_tier) "
                "VALUES ('Bad Tier', 'badtier@test.com', 'Platinum');"
            )
    db_connection.rollback()


def test_customers_email_unique(db_connection):
    """Verifies duplicate emails are rejected."""
    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) VALUES ('First', 'dupe@test.com');"
        )
        with pytest.raises(psycopg2.errors.UniqueViolation):
            cursor.execute(
                "INSERT INTO customers (full_name, email) VALUES ('Second', 'dupe@test.com');"
            )
    db_connection.rollback()


def test_products_check_constraints(db_connection):
    """Verifies unit_price > 0, stock_quantity >= 0, reorder_quantity > 0."""
    with db_connection.cursor() as cursor:
        with pytest.raises(psycopg2.errors.CheckViolation):
            cursor.execute(
                "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
                "VALUES ('Free Item', 'Tech', 0.00, 10);"
            )
    db_connection.rollback()

    with db_connection.cursor() as cursor:
        with pytest.raises(psycopg2.errors.CheckViolation):
            cursor.execute(
                "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
                "VALUES ('Negative Stock', 'Tech', 10.00, -1);"
            )
    db_connection.rollback()

    with db_connection.cursor() as cursor:
        with pytest.raises(psycopg2.errors.CheckViolation):
            cursor.execute(
                "INSERT INTO products "
                "(product_name, category, unit_price, stock_quantity, reorder_quantity) "
                "VALUES ('Zero Reorder', 'Tech', 10.00, 10, 0);"
            )
    db_connection.rollback()


def test_orders_requires_valid_customer(db_connection):
    """Verifies orders.customer_id must reference an existing customer."""
    with db_connection.cursor() as cursor:
        with pytest.raises(psycopg2.errors.ForeignKeyViolation):
            cursor.execute(
                "INSERT INTO orders (customer_id) "
                "VALUES ('00000000-0000-0000-0000-000000000000');"
            )
    db_connection.rollback()


def test_orders_status_and_total_amount_checks(db_connection):
    """Verifies order_status enum and total_amount >= 0."""
    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Order Check User', 'orderchk@test.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        with pytest.raises(psycopg2.errors.CheckViolation):
            cursor.execute(
                "INSERT INTO orders (customer_id, order_status) VALUES (%s, 'SHIPPED');",
                (cust_id,),
            )
    db_connection.rollback()

    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Order Check User 2', 'orderchk2@test.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        with pytest.raises(psycopg2.errors.CheckViolation):
            cursor.execute(
                "INSERT INTO orders (customer_id, total_amount) VALUES (%s, -50.00);",
                (cust_id,),
            )
    db_connection.rollback()


def test_order_details_referential_integrity_and_uniqueness(db_connection):
    """Verifies order_id/product_id FKs and the UNIQUE (order_id, product_id) pair."""
    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Item User', 'itemuser@test.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO orders (customer_id) VALUES (%s) RETURNING order_id;", (cust_id,)
        )
        order_id = cursor.fetchone()[0]

        # Reject a line item referencing a non-existent product
        with pytest.raises(psycopg2.errors.ForeignKeyViolation):
            cursor.execute(
                "INSERT INTO order_details (order_id, product_id, quantity, unit_price) "
                "VALUES (%s, '00000000-0000-0000-0000-000000000000', 1, 20.00);",
                (order_id,),
            )
    db_connection.rollback()

    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Item User 2', 'itemuser2@test.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
            "VALUES ('Item Product 2', 'Tech', 20.00, 100) "
            "RETURNING product_id;"
        )
        prod_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO orders (customer_id) VALUES (%s) RETURNING order_id;", (cust_id,)
        )
        order_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO order_details (order_id, product_id, quantity, unit_price) "
            "VALUES (%s, %s, 1, 20.00);",
            (order_id, prod_id),
        )

        # Reject a second line for the same (order_id, product_id) pair
        with pytest.raises(psycopg2.errors.UniqueViolation):
            cursor.execute(
                "INSERT INTO order_details (order_id, product_id, quantity, unit_price) "
                "VALUES (%s, %s, 2, 20.00);",
                (order_id, prod_id),
            )
    db_connection.rollback()


def test_order_details_subtotal_generated_column(db_connection):
    """Verifies subtotal = quantity * unit_price * (1 - discount_percent / 100), rounded."""
    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Subtotal User', 'subtotal@test.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
            "VALUES ('Subtotal Product', 'Tech', 50.00, 100) "
            "RETURNING product_id;"
        )
        prod_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO orders (customer_id) VALUES (%s) RETURNING order_id;", (cust_id,)
        )
        order_id = cursor.fetchone()[0]

        # 3 units at $50, no discount band (qty < 10) -> subtotal = 150.00
        cursor.execute(
            "INSERT INTO order_details (order_id, product_id, quantity, unit_price) "
            "VALUES (%s, %s, 3, 50.00) RETURNING subtotal, discount_percent;",
            (order_id, prod_id),
        )
        subtotal, discount = cursor.fetchone()
        assert discount == 0.00
        assert subtotal == 150.00
    db_connection.rollback()


def test_inventory_logs_change_reason_and_math_check(db_connection):
    """Verifies change_reason enum and new_stock = previous_stock + change_quantity."""
    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
            "VALUES ('Log Product', 'Tech', 20.00, 50) "
            "RETURNING product_id;"
        )
        prod_id = cursor.fetchone()[0]

        with pytest.raises(psycopg2.errors.CheckViolation):
            cursor.execute(
                "INSERT INTO inventory_logs "
                "(product_id, change_quantity, previous_stock, new_stock, change_reason) "
                "VALUES (%s, -5, 50, 45, 'MYSTERY_REASON');",
                (prod_id,),
            )
    db_connection.rollback()

    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
            "VALUES ('Log Product 2', 'Tech', 20.00, 50) "
            "RETURNING product_id;"
        )
        prod_id = cursor.fetchone()[0]

        # previous_stock + change_quantity (50 + -5 = 45) must equal new_stock; 46 is wrong
        with pytest.raises(psycopg2.errors.CheckViolation):
            cursor.execute(
                "INSERT INTO inventory_logs "
                "(product_id, change_quantity, previous_stock, new_stock, change_reason) "
                "VALUES (%s, -5, 50, 46, 'MANUAL_ADJUSTMENT');",
                (prod_id,),
            )
    db_connection.rollback()


def test_deleting_order_cascades_order_details(db_connection):
    """Verifies ON DELETE CASCADE from orders to order_details."""
    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Cascade User', 'cascade@test.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
            "VALUES ('Cascade Product', 'Tech', 20.00, 100) "
            "RETURNING product_id;"
        )
        prod_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO orders (customer_id) VALUES (%s) RETURNING order_id;", (cust_id,)
        )
        order_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO order_details (order_id, product_id, quantity, unit_price) "
            "VALUES (%s, %s, 1, 20.00);",
            (order_id, prod_id),
        )

        cursor.execute("DELETE FROM orders WHERE order_id = %s;", (order_id,))

        cursor.execute("SELECT COUNT(*) FROM order_details WHERE order_id = %s;", (order_id,))
        assert cursor.fetchone()[0] == 0
    db_connection.rollback()


def test_deleting_referenced_customer_is_restricted(db_connection):
    """Verifies ON DELETE RESTRICT: a customer with orders cannot be deleted."""
    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Restrict User', 'restrict@test.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        cursor.execute("INSERT INTO orders (customer_id) VALUES (%s);", (cust_id,))

        with pytest.raises(psycopg2.errors.ForeignKeyViolation):
            cursor.execute("DELETE FROM customers WHERE customer_id = %s;", (cust_id,))
    db_connection.rollback()


def test_required_indexes_exist(db_connection):
    """Verifies the performance indexes from docs/entity.puml are present."""
    expected_indexes = {
        "idx_orders_customer_id",
        "idx_orders_order_date",
        "idx_order_details_order_id",
        "idx_order_details_product_id",
        "idx_inventory_logs_product_id",
        "idx_inventory_logs_logged_at",
        "idx_products_low_stock",
    }
    with db_connection.cursor() as cursor:
        cursor.execute(
            "SELECT indexname FROM pg_indexes WHERE schemaname = 'public';"
        )
        existing = {row[0] for row in cursor.fetchall()}
    missing = expected_indexes - existing
    assert not missing, f"Missing indexes: {missing}"
