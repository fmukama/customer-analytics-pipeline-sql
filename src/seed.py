"""Database seeder for the Inventory & Order Management System.

Populates customers and products with Faker-generated data, then places
orders through the real `sp_place_order` stored procedure (never a raw
INSERT) so every trigger - bulk discount, stock deduction, inventory
logging, order total, customer tier - fires exactly as it would for a
genuine customer.

Run directly with `make seed`, or `uv run python -m src.seed`.
"""

import json
import os
import random

import psycopg2
from dotenv import load_dotenv
from faker import Faker

from src.logger import get_logger
from src.utils import get_db_connection

load_dotenv()
logger = get_logger("seeder")

# Volume and reproducibility knobs, read from .env (see .env.example).
# Names must match .env.example / README exactly - a naming drift here makes
# the .env values silently ignored in favour of the fallback below, with no
# error to signal it.
RANDOM_SEED = int(os.getenv("SEED_RANDOM_STATE", "42"))
CUSTOMER_COUNT = int(os.getenv("SEED_CUSTOMERS_COUNT", "50"))
PRODUCT_COUNT = int(os.getenv("SEED_PRODUCTS_COUNT", "20"))
ORDER_COUNT = int(os.getenv("SEED_ORDERS_COUNT", "100"))

# Faker.seed() and random.seed() are both fixed, so two runs with the same
# .env produce byte-identical customers/products/order attempts - useful for
# reproducing a bug report or comparing EXPLAIN ANALYZE output run to run.
fake = Faker()
Faker.seed(RANDOM_SEED)
random.seed(RANDOM_SEED)

PRODUCT_CATEGORIES = [
    "Electronics",
    "Apparel",
    "Home & Kitchen",
    "Books",
    "Sports & Outdoors",
]


def seed_customers(conn) -> list[str]:
    """Insert CUSTOMER_COUNT fake customers and return their generated UUIDs."""
    logger.info(f"Seeding {CUSTOMER_COUNT} customers...")
    customer_ids = []

    with conn.cursor() as cur:
        for _ in range(CUSTOMER_COUNT):
            cur.execute(
                """
                INSERT INTO customers (full_name, email, phone_number)
                VALUES (%s, %s, %s)
                RETURNING customer_id;
                """,
                (
                    fake.name(),
                    fake.unique.email(),
                    fake.phone_number()[:20],
                ),
            )
            customer_ids.append(str(cur.fetchone()[0]))

    conn.commit()
    logger.info(f"Successfully seeded {len(customer_ids)} customers.")
    return customer_ids


def seed_products(conn) -> list[str]:
    """Insert PRODUCT_COUNT fake products and return their generated UUIDs.

    reorder_level/reorder_quantity are fixed (not randomised) so every
    seeded product has the same, predictable replenishment behaviour -
    that keeps sp_replenish_stock's effect easy to reason about while
    seed_orders() is depleting stock below it.
    """
    logger.info(f"Seeding {PRODUCT_COUNT} products...")
    product_ids = []

    with conn.cursor() as cur:
        for _ in range(PRODUCT_COUNT):
            unit_price = round(random.uniform(12.0, 450.0), 2)
            stock_qty = random.randint(30, 100)
            reorder_lvl = 15
            reorder_qty = 50

            cur.execute(
                """
                INSERT INTO products (
                    product_name, category, unit_price,
                    stock_quantity, reorder_level, reorder_quantity
                ) VALUES (%s, %s, %s, %s, %s, %s)
                RETURNING product_id;
                """,
                (
                    fake.catch_phrase()[:150],
                    random.choice(PRODUCT_CATEGORIES),
                    unit_price,
                    stock_qty,
                    reorder_lvl,
                    reorder_qty,
                ),
            )
            product_ids.append(str(cur.fetchone()[0]))

    conn.commit()
    logger.info(f"Successfully seeded {len(product_ids)} products.")
    return product_ids


def seed_orders(conn, customer_ids: list[str], product_ids: list[str]):
    """Place up to ORDER_COUNT orders via sp_place_order for random customers.

    ORDER_COUNT is a ceiling, not a guarantee: with only PRODUCT_COUNT
    products in play, a run of 100 orders routinely exhausts a product's
    stock partway through. That is expected, not a bug - when it happens,
    sp_place_order raises INSUFFICIENT_STOCK, this function rolls back that
    one attempt, replenishes every low-stock product, and moves on to the
    next attempt rather than retrying the same one. The final
    "Successfully placed N orders" log line is the true count; N < ORDER_COUNT
    is normal.
    """
    logger.info(f"Seeding {ORDER_COUNT} orders via sp_place_order...")
    placed_orders = 0
    replenishment_events = 0

    with conn.cursor() as cur:
        for attempt in range(1, ORDER_COUNT + 1):
            customer_id = random.choice(customer_ids)

            # Sample 1 to 3 distinct items per order
            selected_products = random.sample(
                product_ids, k=random.randint(1, min(3, len(product_ids)))
            )

            # Mix quantities to exercise all three bulk discount bands (5/10/15%)
            items_payload = [
                {
                    "product_id": pid,
                    "quantity": random.choice([2, 5, 12, 28, 50]),
                }
                for pid in selected_products
            ]

            try:
                cur.execute(
                    "CALL sp_place_order(%s, %s::jsonb, NULL);",
                    (customer_id, json.dumps(items_payload)),
                )
                conn.commit()
                placed_orders += 1
            except psycopg2.Error as err:
                conn.rollback()
                if "INSUFFICIENT_STOCK" in str(err):
                    replenishment_events += 1
                    # str(err) carries sp_place_order's own RAISE EXCEPTION
                    # text ("Product <uuid> has X in stock, but Y requested")
                    # followed by a "CONTEXT: PL/pgSQL function ... line N"
                    # continuation line with no trailing newline of its own.
                    # Keep only the first line - the actual message - so it
                    # doesn't run on into whatever this log call appends next.
                    detail = str(err).strip().splitlines()[0]
                    logger.warning(
                        f"Order attempt {attempt}/{ORDER_COUNT} for customer "
                        f"{customer_id} hit insufficient stock ({detail}). "
                        "Replenishing and continuing."
                    )
                    cur.execute("CALL sp_replenish_stock(NULL);")
                    conn.commit()
                else:
                    logger.error(
                        f"Order attempt {attempt}/{ORDER_COUNT} for customer "
                        f"{customer_id} failed unexpectedly: {err}"
                    )

    logger.info(
        f"Successfully placed {placed_orders}/{ORDER_COUNT} orders "
        f"({replenishment_events} replenishment(s) triggered along the way)."
    )


def run_optimizer_analyze(conn):
    """Run ANALYZE so the query planner has real statistics to work from.

    Without this, EXPLAIN ANALYZE in sql/05_reports_and_queries.sql reflects
    stale (often zero-row) statistics and the index-usage performance benchmarks
    are meaningless.
    """
    logger.info("Updating PostgreSQL query planner statistics via ANALYZE...")
    old_autocommit = conn.autocommit
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute("ANALYZE customers, products, orders, order_details, inventory_logs;")
    finally:
        conn.autocommit = old_autocommit
    logger.info("ANALYZE execution complete.")


def run_seed():
    """Entry point: seed customers, then products, then orders, then ANALYZE."""
    logger.info("Starting database seeding execution...")
    conn = get_db_connection()

    try:
        customers = seed_customers(conn)
        products = seed_products(conn)
        seed_orders(conn, customers, products)
        run_optimizer_analyze(conn)
        logger.info("Database seeding finished cleanly!")
    except Exception as exc:
        logger.error(f"Seeding process failed: {exc}")
        raise exc
    finally:
        conn.close()


if __name__ == "__main__":
    run_seed()
