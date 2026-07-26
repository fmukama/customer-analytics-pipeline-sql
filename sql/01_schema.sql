-- File: sql/01_schema.sql
-- Description: Database schema definition for the E-Commerce Inventory
--              & Order Management System (see docs/entity.puml for the
--              full annotated ER diagram this file implements).
--
-- Idempotent by design: every object is dropped and recreated on each run,
-- so `make init-db` (and the CI pipeline) can apply this file against an
-- already-populated database without manual cleanup first. This is also
-- why the DROP order below is the exact reverse of the CREATE order -
-- CASCADE handles dependent objects (indexes, FKs), but a table can still
-- only be dropped after anything that references it.

-- Idempotent reset in reverse dependency order
DROP TABLE IF EXISTS inventory_logs CASCADE;
DROP TABLE IF EXISTS order_details CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

-- 1. CUSTOMERS
-- total_spent and customer_tier are NEVER written by application code -
-- sql/02_triggers.sql's fn_recalculate_customer_tier recomputes both from
-- CONFIRMED orders every time an order is placed or cancelled. Treat them
-- as read-only/derived columns from outside the trigger layer.

CREATE TABLE customers (
    customer_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    phone_number VARCHAR(20),
    total_spent NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_spent >= 0),
    customer_tier VARCHAR(10) NOT NULL DEFAULT 'Bronze'
    CHECK (customer_tier IN ('Bronze', 'Silver', 'Gold')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. PRODUCTS
-- stock_quantity is maintained exclusively by triggers and procedures
-- (never a direct UPDATE from application code): trg_2 deducts it on order
-- placement, sp_replenish_stock adds to it, sp_cancel_order restores it.
-- The CHECK below is the last line of defence against overselling - the
-- procedures pre-check stock and raise a readable error first, but this
-- constraint guarantees correctness even if that check is ever bypassed.

CREATE TABLE products (
    product_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_name VARCHAR(150) NOT NULL,
    category VARCHAR(50) NOT NULL,
    unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_quantity INTEGER NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
    reorder_level INTEGER NOT NULL DEFAULT 10 CHECK (reorder_level >= 0),
    reorder_quantity INTEGER NOT NULL DEFAULT 50 CHECK (reorder_quantity > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3. ORDERS
-- total_amount is derived, like customers.total_spent above: trg_3
-- recomputes it as SUM(order_details.subtotal) every time a line item is
-- inserted, updated or deleted, so it is always consistent with the lines
-- that actually make up the order - never manually incremented.
--
-- ON DELETE RESTRICT: a customer with any order (including a cancelled
-- one) cannot be deleted. This is deliberate - order history must outlive
-- the customer record for the audit trail to stay meaningful, and it is
-- also what sql/06_demo.sql's own reset step has to work around (delete the
-- order first, then the customer).

CREATE TABLE orders (
    order_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id UUID NOT NULL REFERENCES customers (customer_id) ON DELETE RESTRICT,
    order_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0),
    order_status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
    CHECK (order_status IN ('PENDING', 'CONFIRMED', 'CANCELLED'))
);

-- 4. ORDER DETAILS
-- This table is the Order Details entity (products ordered, their quantities, and their prices).
--
-- unit_price is a SNAPSHOT copied from products.unit_price at order time,
-- not a live reference - so re-pricing a product later never changes the
-- value of a historical order.
--
-- subtotal is a GENERATED STORED column, not application-computed: Postgres
-- recalculates and persists it automatically from quantity/unit_price/
-- discount_percent, so it can never drift out of sync with its own inputs.
-- Casting to NUMERIC(12,2) on assignment rounds the result for us.
--
-- UNIQUE (order_id, product_id): one product can only appear once per
-- order. sp_place_order therefore aggregates duplicate product_ids in its
-- JSONB input payload into a single line before inserting, or this
-- constraint would reject the whole order.

CREATE TABLE order_details (
    order_detail_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES orders (order_id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products (product_id) ON DELETE RESTRICT,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    discount_percent NUMERIC(5, 2) NOT NULL DEFAULT 0.00
    CHECK (discount_percent BETWEEN 0 AND 100),
    subtotal NUMERIC(12, 2) GENERATED ALWAYS AS (
        (quantity * unit_price) * (1 - discount_percent / 100)
    ) STORED,
    CONSTRAINT uq_order_product UNIQUE (order_id, product_id)
);

COMMENT ON TABLE order_details IS
'Stores line-item details for each order, serving as the Order Details entity in the brief.';


-- 5. INVENTORY LOGS
-- Append-only audit trail for inventory tracking: rows are only ever INSERTed, never
-- UPDATEd or DELETEd, by trg_2 (ORDER_PLACEMENT), sp_replenish_stock
-- (REPLENISHMENT), or sp_cancel_order (ORDER_CANCELLATION). That is what
-- makes the "full history retrievable for auditing" requirement trustworthy
-- - nothing in this system can quietly rewrite what actually happened.
--
-- order_id is nullable because a REPLENISHMENT event is not tied to any
-- order. change_quantity is signed (negative for a deduction, positive for
-- a restock/return), and chk_inventory_math below is a hard guarantee that
-- the arithmetic in every row is internally consistent: whatever the
-- trigger/procedure computed, previous_stock + change_quantity must equal
-- new_stock, or PostgreSQL rejects the insert outright.

CREATE TABLE inventory_logs (
    log_id BIGSERIAL PRIMARY KEY,
    product_id UUID NOT NULL REFERENCES products (product_id) ON DELETE CASCADE,
    order_id UUID REFERENCES orders (order_id) ON DELETE SET NULL,
    change_quantity INTEGER NOT NULL,
    previous_stock INTEGER NOT NULL,
    new_stock INTEGER NOT NULL,
    change_reason VARCHAR(20) NOT NULL
    CHECK (change_reason IN ('ORDER_PLACEMENT', 'REPLENISHMENT', 'MANUAL_ADJUSTMENT', 'ORDER_CANCELLATION')),
    logged_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_inventory_math CHECK (new_stock = previous_stock + change_quantity)
);

-- PERFORMANCE INDEXES (Query Optimization)
-- PostgreSQL does NOT automatically index foreign key columns - both
-- order_details FKs are indexed explicitly below because v_order_summary
-- joins on order_id and the top-sellers report groups by product_id.

CREATE INDEX idx_orders_customer_id ON orders (customer_id);
CREATE INDEX idx_orders_order_date ON orders (order_date);
CREATE INDEX idx_order_details_order_id ON order_details (order_id);
CREATE INDEX idx_order_details_product_id ON order_details (product_id);
CREATE INDEX idx_inventory_logs_product_id ON inventory_logs (product_id);
CREATE INDEX idx_inventory_logs_logged_at ON inventory_logs (logged_at DESC);

-- Partial index for fast low-stock queries matching v_low_stock_alerts predicate.
-- Only rows where a product is actually low on stock are indexed, so this
-- stays tiny (and the reorder report stays fast) no matter how large the
-- product catalogue grows - unlike a full index on stock_quantity, which
-- would scale with the whole table.
CREATE INDEX idx_products_low_stock ON products (product_id) WHERE stock_quantity <= reorder_level;
