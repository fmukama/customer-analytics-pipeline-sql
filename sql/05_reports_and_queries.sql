-- File: sql/05_reports_and_queries.sql
-- Description: Business Reports & Query Performance Benchmarks.
--              Every SELECT in this file is read-only and safe to re-run at
--              any time; nothing here mutates data. Run via `make reports`
--              or directly with psql - see README.md Step 6.

-- 1. REPORT: Order Summaries Per Customer
-- Aggregate lifetime order statistics grouped by customer.
-- net_confirmed_spend deliberately only sums CONFIRMED orders' totals - a
-- CANCELLED order's total_amount is real (it was actually calculated), but
-- it never became revenue, so counting it here would overstate spend
-- relative to what customers.total_spent (the derived spending column)
-- itself reports.

SELECT
    c.customer_id,
    c.full_name,
    c.email,
    c.customer_tier,
    COUNT(o.order_id) AS total_orders_placed,
    COUNT(CASE WHEN o.order_status = 'CONFIRMED' THEN 1 END) AS confirmed_orders,
    COUNT(CASE WHEN o.order_status = 'CANCELLED' THEN 1 END) AS cancelled_orders,
    COALESCE(SUM(CASE WHEN o.order_status = 'CONFIRMED' THEN o.total_amount ELSE 0 END), 0.00) AS net_confirmed_spend
FROM customers AS c
LEFT JOIN orders AS o ON c.customer_id = o.customer_id
GROUP BY c.customer_id, c.full_name, c.email, c.customer_tier
ORDER BY net_confirmed_spend DESC;


-- 2. REPORT: Low-Stock Replenishment Summary
-- Direct query against v_low_stock_alerts (sql/04_views.sql), with an
-- estimated_replenishment_cost column added on top: what it would cost to
-- buy reorder_quantity more units of each flagged product at its current
-- unit_price.

SELECT
    product_id,
    product_name,
    category,
    stock_quantity,
    reorder_level,
    reorder_quantity,
    stock_deficit,
    (reorder_quantity * unit_price) AS estimated_replenishment_cost
FROM v_low_stock_alerts;


-- 3. REPORT: Customer Spending Tiers & Rankings
-- Uses window functions to rank customers within their respective spending
-- tiers, and across all customers - two different ranking styles on
-- purpose:
--   tier_rank   - RANK() PARTITION BY customer_tier: rank #1 resets for
--                 each of Bronze/Silver/Gold separately, and ties SKIP the
--                 next rank (two people tied for #1 means the next is #3).
--   global_rank - DENSE_RANK() with no partition: one ranking across every
--                 customer regardless of tier, and ties do NOT skip a rank.

SELECT
    customer_id,
    full_name,
    customer_tier,
    total_spent,
    RANK() OVER (
        PARTITION BY customer_tier
        ORDER BY total_spent DESC
    ) AS tier_rank,
    DENSE_RANK() OVER (
        ORDER BY total_spent DESC
    ) AS global_rank
FROM customers
ORDER BY total_spent DESC;


-- 4. REPORT: Bulk-Discount Effectiveness Analysis
-- Evaluates discount impact grouped by quantity discount bands.
-- Restricted to CONFIRMED orders: a cancelled order's discount never turned
-- into real revenue, so it must not count here - matching how Report 1
-- (net_confirmed_spend) and Report 6 (top-selling products) already treat it.

SELECT
    CASE
        WHEN oi.discount_percent = 15.00 THEN '15% Discount (Qty >= 50)'
        WHEN oi.discount_percent = 10.00 THEN '10% Discount (Qty >= 25)'
        WHEN oi.discount_percent = 5.00 THEN '5% Discount (Qty >= 10)'
        ELSE '0% Discount (Standard)'
    END AS discount_band,
    COUNT(oi.order_detail_id) AS total_line_items,
    SUM(oi.quantity) AS total_units_sold,
    SUM(oi.quantity * oi.unit_price) AS gross_revenue_before_discount,
    SUM((oi.quantity * oi.unit_price) * (oi.discount_percent / 100.0)) AS total_discount_given,
    SUM(oi.subtotal) AS net_revenue_after_discount
FROM order_details AS oi
INNER JOIN orders AS o ON oi.order_id = o.order_id
WHERE o.order_status = 'CONFIRMED'
GROUP BY oi.discount_percent
ORDER BY oi.discount_percent DESC;


-- 5. REPORT: Full Chronological Inventory Audit Trail
-- Tracks full historical stock changes per product with a running balance.
-- This is the direct evidence for the "full history of inventory
-- changes ... retrievable for auditing purposes" requirement - every row here traces
-- back to a trigger or procedure in sql/02_triggers.sql / 03_procedures.sql,
-- and inventory_logs is append-only, so nothing here can have been
-- silently edited after the fact.
--
-- cumulative_stock_impact is a running SUM computed in chronological order
-- (ORDER BY logged_at ASC, log_id ASC inside the window) independently of
-- how the rows are finally displayed (ORDER BY ... DESC below) - the two
-- ORDER BYs serve different purposes and do not need to match.
-- log_id DESC is added as a tiebreaker on the display order because a
-- single transaction (e.g. one sp_place_order call inserting several log
-- rows) can produce identical logged_at timestamps; without a tiebreaker,
-- "most recent first" would be ambiguous for rows written in the same
-- transaction.

SELECT
    il.log_id,
    il.logged_at,
    p.product_name,
    il.change_reason,
    il.change_quantity,
    il.previous_stock,
    il.new_stock,
    il.order_id,
    SUM(il.change_quantity) OVER (
        PARTITION BY il.product_id
        ORDER BY il.logged_at ASC, il.log_id ASC
    ) AS cumulative_stock_impact
FROM inventory_logs AS il
INNER JOIN products AS p ON il.product_id = p.product_id
ORDER BY p.product_name ASC, il.logged_at DESC, il.log_id DESC;


-- 6. REPORT: Top-Selling Products by Revenue & Units Sold
-- Restricted to CONFIRMED orders for the same reason as Report 4: a
-- cancelled order never became a real sale.

SELECT
    p.product_id,
    p.product_name,
    p.category,
    COUNT(DISTINCT oi.order_id) AS times_ordered,
    SUM(oi.quantity) AS total_units_sold,
    SUM(oi.subtotal) AS gross_revenue
FROM products AS p
INNER JOIN order_details AS oi ON p.product_id = oi.product_id
INNER JOIN orders AS o ON oi.order_id = o.order_id
WHERE o.order_status = 'CONFIRMED'
GROUP BY p.product_id, p.product_name, p.category
ORDER BY gross_revenue DESC
LIMIT 10;


-- 7. PERFORMANCE BENCHMARKS: EXPLAIN ANALYZE Evidence
-- Note: Run `make seed` or populate data first so query plans reflect real
-- estimates - EXPLAIN ANALYZE against near-empty tables just shows trivial
-- sequential scans regardless of which indexes exist, because the planner
-- correctly judges a full scan cheaper than an index lookup at that size.


-- A. Customer Order Lookup Optimization
-- Expected Plan Node: Index Scan / Bitmap Heap Scan using idx_orders_customer_id.
-- The inner subquery picks a deterministic, arbitrary customer_id (ORDER BY
-- + LIMIT 1, not just LIMIT 1 alone) so this benchmark's query plan and row
-- count are reproducible from one run to the next.
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    o.order_id,
    o.order_date,
    o.total_amount,
    o.order_status
FROM orders AS o
WHERE o.customer_id = (
        SELECT c.customer_id FROM customers AS c
        ORDER BY c.customer_id LIMIT 1
    );

-- B. Low-Stock Alert Scan Optimization
-- Expected Plan Node: Index Scan or Bitmap Index Scan using idx_products_low_stock
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM v_low_stock_alerts;

-- C. Customer Spending & Tier Aggregate Optimization
-- Expected Plan Node: Aggregate Scan using PK / Indexes on orders
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    customer_tier,
    COUNT(*) AS customer_count,
    SUM(total_spent) AS tier_revenue
FROM customers
GROUP BY customer_tier;
