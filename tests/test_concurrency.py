"""Isolation (ACID) test for sp_place_order.

Deliberately bypasses the db_connection/conn fixtures: those roll back at
teardown, so data created inside them is never visible to a second,
concurrent connection under READ COMMITTED. Proving two real buyers cannot
oversell the same row requires two real connections that actually commit.
"""

import json
import threading

import psycopg2

from src.utils import get_db_connection


def test_concurrent_orders_cannot_oversell_same_product():
    """Two buyers simultaneously order 6 units each of a 10-unit-stock product.

    The FOR UPDATE row lock in fn_process_inventory_and_log must serialize
    them: exactly one order succeeds, the other is rejected with
    INSUFFICIENT_STOCK, and stock never goes negative or is double-deducted.
    """
    setup_conn = get_db_connection()
    try:
        with setup_conn.cursor() as cur:
            cur.execute(
                "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
                "VALUES ('Concurrency Test Item', 'Tech', 10.00, 10) "
                "RETURNING product_id;"
            )
            product_id = str(cur.fetchone()[0])

            cur.execute(
                "INSERT INTO customers (full_name, email) "
                "VALUES ('Concurrent Buyer One', 'concbuyer1@test.com') "
                "RETURNING customer_id;"
            )
            customer_1 = str(cur.fetchone()[0])

            cur.execute(
                "INSERT INTO customers (full_name, email) "
                "VALUES ('Concurrent Buyer Two', 'concbuyer2@test.com') "
                "RETURNING customer_id;"
            )
            customer_2 = str(cur.fetchone()[0])
        setup_conn.commit()
    finally:
        setup_conn.close()

    results = {}
    barrier = threading.Barrier(2)

    def attempt_order(name, customer_id, quantity):
        conn = get_db_connection()
        try:
            payload = json.dumps([{"product_id": product_id, "quantity": quantity}])
            with conn.cursor() as cur:
                barrier.wait()  # line both threads up to hit CALL at the same instant
                try:
                    cur.execute("CALL sp_place_order(%s, %s::jsonb, NULL);", (customer_id, payload))
                    conn.commit()
                    results[name] = "success"
                except psycopg2.Error as err:
                    conn.rollback()
                    if "INSUFFICIENT_STOCK" in str(err):
                        results[name] = "INSUFFICIENT_STOCK"
                    else:
                        results[name] = f"unexpected_error: {err}"
        finally:
            conn.close()

    thread_1 = threading.Thread(target=attempt_order, args=("buyer_1", customer_1, 6))
    thread_2 = threading.Thread(target=attempt_order, args=("buyer_2", customer_2, 6))
    thread_1.start()
    thread_2.start()
    thread_1.join(timeout=15)
    thread_2.join(timeout=15)

    verify_conn = get_db_connection()
    try:
        with verify_conn.cursor() as cur:
            cur.execute("SELECT stock_quantity FROM products WHERE product_id = %s;", (product_id,))
            final_stock = cur.fetchone()[0]

            cur.execute(
                "SELECT COUNT(*) FROM orders WHERE customer_id IN (%s, %s);",
                (customer_1, customer_2),
            )
            orders_created = cur.fetchone()[0]
    finally:
        verify_conn.close()

    cleanup_conn = get_db_connection()
    try:
        with cleanup_conn.cursor() as cur:
            cur.execute(
                "DELETE FROM orders WHERE customer_id IN (%s, %s);", (customer_1, customer_2)
            )
            cur.execute("DELETE FROM products WHERE product_id = %s;", (product_id,))
            cur.execute(
                "DELETE FROM customers WHERE customer_id IN (%s, %s);", (customer_1, customer_2)
            )
        cleanup_conn.commit()
    finally:
        cleanup_conn.close()

    assert sorted(results.values()) == ["INSUFFICIENT_STOCK", "success"], results
    assert orders_created == 1
    assert final_stock == 4, "stock must reflect exactly one 6-unit deduction from 10, never both"
    assert final_stock >= 0
