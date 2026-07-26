-- File: sql/04_views.sql
-- Description: Operational reporting views for Order Summaries and Low-Stock Reorder Alerts.
--              Includes "a view summarizing order information" and "a view displaying stock
--              information for items that need to be reordered".

-- Idempotent reset of views in reverse dependency order
DROP VIEW IF EXISTS v_low_stock_alerts CASCADE;
DROP VIEW IF EXISTS v_order_summary CASCADE;


-- 1. VIEW: v_order_summary
-- Description: Aggregates order metadata, customer profile, status, order totals,
--              and item counts (both distinct SKUs and total physical units).
--
-- The brief asks for "number of items" per order, which is ambiguous
-- between two readings, so this view exposes both rather than guessing:
--   line_count - how many distinct products are on the order (COUNT of
--                order_detail rows)
--   unit_count - how many individual units were ordered in total
--                (SUM of quantity across those rows)
-- e.g. an order of 3 keyboards + 2 mice is line_count=2, unit_count=5.
--
-- LEFT JOIN order_details: every order created via sp_place_order always has
-- at least one item, but the LEFT JOIN (rather than INNER) means this view
-- still shows an order correctly (with line_count/unit_count = 0) if that
-- were ever not true - it degrades gracefully instead of silently hiding
-- the order.

CREATE OR REPLACE VIEW v_order_summary AS
SELECT
    o.order_id,
    o.order_date,
    c.customer_id,
    c.full_name AS customer_name,
    c.email AS customer_email,
    c.customer_tier,
    o.order_status,
    COALESCE(COUNT(oi.order_detail_id), 0) AS line_count,
    COALESCE(SUM(oi.quantity), 0) AS unit_count,
    o.total_amount
FROM orders AS o
INNER JOIN customers AS c ON o.customer_id = c.customer_id
LEFT JOIN order_details AS oi ON o.order_id = oi.order_id
GROUP BY
    o.order_id,
    o.order_date,
    c.customer_id,
    c.full_name,
    c.email,
    c.customer_tier,
    o.order_status;

COMMENT ON VIEW v_order_summary IS
'Summarizes order details per customer including total spent, order status, and item counts.';


-- 2. VIEW: v_low_stock_alerts
-- Description: Identifies products whose stock level is at or below reorder_level.
--              Computes the current stock deficit to assist inventory restocking.
-- Note: Uses the exact predicate WHERE stock_quantity <= reorder_level to
--       leverage the partial index idx_products_low_stock (sql/01_schema.sql)
--       - that index was built with this same WHERE clause, so PostgreSQL
--       can use it directly instead of scanning every product. Changing this
--       predicate's shape (e.g. to `reorder_level >= stock_quantity`) would
--       make the planner unable to match it to the index.

CREATE OR REPLACE VIEW v_low_stock_alerts AS
SELECT
    p.product_id,
    p.product_name,
    p.category,
    p.unit_price,
    p.stock_quantity,
    p.reorder_level,
    p.reorder_quantity,
    (p.reorder_level - p.stock_quantity) AS stock_deficit
FROM products AS p
WHERE p.stock_quantity <= p.reorder_level
ORDER BY p.stock_quantity ASC, p.product_name ASC;

COMMENT ON VIEW v_low_stock_alerts IS 'Displays products at or below reorder level with calculated stock shortfall.';
