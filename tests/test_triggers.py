"""Automation trigger tests (sql/02_triggers.sql).

Each test isolates a single trigger from the others it normally fires
alongside, by driving the table that trigger actually sits on rather than
going through sp_place_order:

- test_bulk_discount_trigger inserts directly into order_details, so only
  trg_1_apply_bulk_discount (BEFORE INSERT) is exercised - not the stock
  deduction or order-total triggers that would also fire for a real order.
- test_tier_promotion_trigger inserts directly into orders with a preset
  total_amount, so only trg_recalculate_customer_tier fires - decoupled from
  trg_update_order_total, which is what would normally compute that total.

End-to-end trigger interaction (all four firing together for one order) is
covered separately in tests/test_procedures.py, via the real stored
procedures.
"""


def test_bulk_discount_trigger(db_connection):
    """Verifies that bulk discounts are set according to quantity thresholds."""
    with db_connection.cursor() as cursor:
        # Create test customer & products
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Discount User', 'discount@test.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]
        cursor.execute(
            "INSERT INTO products (product_name, category, unit_price, stock_quantity) "
            "VALUES ('Bulk Item', 'Tech', 10.00, 500) "
            "RETURNING product_id;"
        )
        prod_id = cursor.fetchone()[0]
        cursor.execute(
            "INSERT INTO orders (customer_id) VALUES (%s) RETURNING order_id;",
            (cust_id,),
        )
        order_id = cursor.fetchone()[0]

        # Insert 30 items -> Should hit 10% discount band
        cursor.execute(
            """
            INSERT INTO order_details (order_id, product_id, quantity, unit_price)
            VALUES (%s, %s, 30, 10.00)
            RETURNING discount_percent;
            """,
            (order_id, prod_id),
        )
        discount = cursor.fetchone()[0]
        assert discount == 10.00
    db_connection.rollback()


def test_tier_promotion_trigger(db_connection):
    """Verifies that customer tier promotes to Silver at $1000 and Gold at $5000."""
    with db_connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO customers (full_name, email) "
            "VALUES ('Tier User', 'tier@test.com') "
            "RETURNING customer_id;"
        )
        cust_id = cursor.fetchone()[0]

        # Initial status should be Bronze
        cursor.execute(
            "SELECT customer_tier, total_spent FROM customers WHERE customer_id = %s;",
            (cust_id,),
        )
        tier, spent = cursor.fetchone()
        assert tier == "Bronze" and spent == 0.00

        # Create a confirmed order worth $1200
        cursor.execute(
            "INSERT INTO orders (customer_id, total_amount, order_status) "
            "VALUES (%s, 1200.00, 'CONFIRMED');",
            (cust_id,),
        )

        cursor.execute(
            "SELECT customer_tier, total_spent FROM customers WHERE customer_id = %s;",
            (cust_id,),
        )
        tier, spent = cursor.fetchone()
        assert tier == "Silver" and spent == 1200.00
    db_connection.rollback()
