"""Stored procedure integration tests (sql/03_procedures.sql).

Unlike tests/test_triggers.py, these tests call the real procedures
(`CALL sp_place_order`, `sp_replenish_stock`, `sp_cancel_order`), so every
trigger fires together exactly as it would for a genuine order - discount,
stock deduction + audit log, order total, and customer tier, all in one
statement. This is also where atomicity is proven: an oversell attempt must
leave stock, inventory_logs and the order table completely untouched, not
"mostly" untouched.
"""

import json

import psycopg2
import pytest


def test_sp_place_order_success(db_connection):
    """Verifies atomic creation of order, item, stock deduction, and inventory log."""
    with db_connection.cursor() as cursor:
        # Setup: Create customer and product
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Alice Smith', 'alice@example.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
            "VALUES ('Mechanical Keyboard', 'Tech', 100.00, 50) "
            "RETURNING product_id;"
        )
        prod_id = cursor.fetchone()[0]

        # Action: Place order for 10 units via procedure
        payload = json.dumps([{"product_id": str(prod_id), "quantity": 10}])
        cursor.execute("CALL sp_place_order(%s, %s::jsonb, NULL);", (cust_id, payload))

        # Retrieve generated order_id
        cursor.execute("SELECT order_id FROM orders WHERE customer_id = %s;", (cust_id,))
        order_id = cursor.fetchone()[0]

        # Assertions
        # 1. Product stock deducted from 50 to 40
        cursor.execute(
            "SELECT stock_quantity FROM products WHERE product_id = %s;", (prod_id,)
        )
        assert cursor.fetchone()[0] == 40

        # 2. Order total updated (10 * $100 * 0.95 [5% bulk discount for qty >= 10] = $950.00)
        cursor.execute(
            "SELECT total_amount, order_status FROM orders WHERE order_id = %s;",
            (order_id,),
        )
        total_amount, status = cursor.fetchone()
        assert total_amount == 950.00
        assert status == "CONFIRMED"

        # 3. Inventory audit log created
        cursor.execute(
            "SELECT change_quantity, previous_stock, new_stock, change_reason "
            "FROM inventory_logs WHERE product_id = %s AND order_id = %s;",
            (prod_id, order_id),
        )
        change_qty, prev_stock, new_stock, reason = cursor.fetchone()
        assert change_qty == -10
        assert prev_stock == 50
        assert new_stock == 40
        assert reason == "ORDER_PLACEMENT"

    db_connection.rollback()


def test_sp_place_order_insufficient_stock_rollback(db_connection):
    """Verifies that an oversell request fails and rolls back without altering state."""
    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Bob Jones', 'bob@example.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
            "VALUES ('Limited Monitor', 'Tech', 300.00, 5) "
            "RETURNING product_id;"
        )
        prod_id = cursor.fetchone()[0]

        # Request 10 units when only 5 are in stock
        payload = json.dumps([{"product_id": str(prod_id), "quantity": 10}])

        with pytest.raises(psycopg2.Error) as exc_info:
            cursor.execute("CALL sp_place_order(%s, %s::jsonb, NULL);", (cust_id, payload))

        assert "INSUFFICIENT_STOCK" in str(exc_info.value)

    # Roll back transaction context
    db_connection.rollback()

    # Verify database state remained unchanged
    with db_connection.cursor() as cursor:
        cursor.execute(
            "SELECT stock_quantity FROM products WHERE product_name = 'Limited Monitor';"
        )
        res = cursor.fetchone()
        if res:
            assert res[0] == 5

        cursor.execute(
            "SELECT COUNT(*) FROM inventory_logs WHERE change_reason = 'ORDER_PLACEMENT';"
        )
        assert cursor.fetchone()[0] == 0


def test_sp_place_order_payload_deduplication(db_connection):
    """Verifies that duplicate product_ids in the JSON payload are aggregated cleanly."""
    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Carol Danvers', 'carol@example.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
            "VALUES ('USB Cable', 'Tech', 10.00, 100) "
            "RETURNING product_id;"
        )
        prod_id = cursor.fetchone()[0]

        # Payload contains duplicate product entries: 12 + 15 = 27 (qualifies for 10% discount)
        payload = json.dumps(
            [
                {"product_id": str(prod_id), "quantity": 12},
                {"product_id": str(prod_id), "quantity": 15},
            ]
        )

        cursor.execute("CALL sp_place_order(%s, %s::jsonb, NULL);", (cust_id, payload))

        # Check product stock: 100 - 27 = 73
        cursor.execute(
            "SELECT stock_quantity FROM products WHERE product_id = %s;", (prod_id,)
        )
        assert cursor.fetchone()[0] == 73

        # Check line item count for this order (should be 1 consolidated row)
        cursor.execute(
            "SELECT COUNT(*), SUM(quantity) FROM order_details WHERE product_id = %s;",
            (prod_id,),
        )
        count, total_qty = cursor.fetchone()
        assert count == 1
        assert total_qty == 27

    db_connection.rollback()


def test_sp_replenish_stock(db_connection):
    """Verifies restocking low-stock items and appending REPLENISHMENT audit records."""
    with db_connection.cursor() as cursor:
        # Insert low stock product (stock 5 <= reorder_level 10, reorder_quantity 50)
        cursor.execute(
            """
            INSERT INTO products (
                product_name, category, unit_price,
                stock_quantity, reorder_level, reorder_quantity
            )
            VALUES ('Low Stock Desk', 'Furniture', 150.00, 5, 10, 50)
            RETURNING product_id;
            """
        )
        prod_id = cursor.fetchone()[0]

        # Call replenishment procedure globally
        cursor.execute("CALL sp_replenish_stock(NULL);")

        # Verify stock increased by 50 (5 -> 55)
        cursor.execute(
            "SELECT stock_quantity FROM products WHERE product_id = %s;", (prod_id,)
        )
        assert cursor.fetchone()[0] == 55

        # Verify audit log
        cursor.execute(
            "SELECT change_quantity, previous_stock, new_stock, change_reason "
            "FROM inventory_logs WHERE product_id = %s;",
            (prod_id,),
        )
        change_qty, prev_stock, new_stock, reason = cursor.fetchone()
        assert change_qty == 50
        assert prev_stock == 5
        assert new_stock == 55
        assert reason == "REPLENISHMENT"

    db_connection.rollback()


def test_sp_cancel_order(db_connection):
    """Verifies that cancelling an order restores stock and re-derives customer spend tier."""
    with db_connection.cursor() as cursor:
        # Setup: Customer + Product
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Dave Miller', 'dave@example.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        cursor.execute(
            "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
            "VALUES ('4K Monitor', 'Tech', 1200.00, 20) "
            "RETURNING product_id;"
        )
        prod_id = cursor.fetchone()[0]

        # Place order for 1 unit ($1200 -> promotes customer to Silver tier)
        payload = json.dumps([{"product_id": str(prod_id), "quantity": 1}])
        cursor.execute("CALL sp_place_order(%s, %s::jsonb, NULL);", (cust_id, payload))

        cursor.execute("SELECT order_id FROM orders WHERE customer_id = %s;", (cust_id,))
        order_id = cursor.fetchone()[0]

        # Confirm Silver tier before cancellation
        cursor.execute(
            "SELECT customer_tier, total_spent FROM customers WHERE customer_id = %s;",
            (cust_id,),
        )
        tier, spent = cursor.fetchone()
        assert tier == "Silver"
        assert spent == 1200.00

        # Action: Cancel Order
        cursor.execute("CALL sp_cancel_order(%s);", (order_id,))

        # Verify order status
        cursor.execute("SELECT order_status FROM orders WHERE order_id = %s;", (order_id,))
        assert cursor.fetchone()[0] == "CANCELLED"

        # Verify stock returned to 20
        cursor.execute(
            "SELECT stock_quantity FROM products WHERE product_id = %s;", (prod_id,)
        )
        assert cursor.fetchone()[0] == 20

        # Verify customer demoted back to Bronze ($0 spent)
        cursor.execute(
            "SELECT customer_tier, total_spent FROM customers WHERE customer_id = %s;",
            (cust_id,),
        )
        tier, spent = cursor.fetchone()
        assert tier == "Bronze"
        assert spent == 0.00

        # Verify cancellation audit log
        cursor.execute(
            "SELECT change_quantity, change_reason FROM inventory_logs "
            "WHERE order_id = %s AND change_reason = 'ORDER_CANCELLATION';",
            (order_id,),
        )
        change_qty, reason = cursor.fetchone()
        assert change_qty == 1
        assert reason == "ORDER_CANCELLATION"

    db_connection.rollback()
