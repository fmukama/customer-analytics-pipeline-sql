-- File: sql/06_demo.sql
-- Description: End-to-End Walkthrough - Scripted demonstration of schema,
--              triggers, procedures, replenishment, and report views.
--              This is Deliverable 4's "demonstration of how the system
--              identifies low-stock products and replenishes them", and
--              README.md Step 5 in the marking path. Every RAISE NOTICE /
--              SELECT '=== STEP N ===' below narrates one requirement from
--              the brief so a reader can watch it happen, in order:
--                Step 1 - starting stock, Bronze tier
--                Step 2 - a multi-product order with a bulk discount
--                Step 3 - the resulting low-stock alert
--                Step 4 - automatic replenishment clearing that alert
--                Step 5 - cancellation reverting stock, spend and tier
--              Pure SQL only (no psql meta-commands) - this file is also
--              executed by `psql -f` directly, so \i/\echo would not work.


BEGIN;


-- STEP 0: RESET PRIOR DEMO RUN (idempotency)
-- This script leaves its data in place on purpose - Step 6/7 of the README
-- (reports, Adminer) read it back as the evidence of Steps 1-5. Deleting them
-- at the END of the script (as a naive "cleanup" would) is not possible
-- anyway: orders_customer_id_fkey / order_details_product_id_fkey are ON
-- DELETE RESTRICT, and the order row (even cancelled) still references both,
-- so that DELETE would fail and roll back the whole demo before COMMIT.
--
-- Instead, any previous run's demo rows are cleared here, before new data is
-- created. Deleting the order first lets CASCADE remove its order_details;
-- deleting products and the customer after that is then unblocked. This also
-- resets stock_quantity back to its starting value on every run, so the
-- narrated before/after numbers in Steps 2-5 stay identical no matter how
-- many times this script is re-run.
DELETE FROM orders
WHERE customer_id = '11111111-1111-1111-1111-111111111111';
DELETE FROM products
WHERE product_id IN (
        '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333'
    );
DELETE FROM customers
WHERE customer_id = '11111111-1111-1111-1111-111111111111';


-- STEP 1: INITIAL STATE & SETUP
-- Register a demo customer and high-value demo products

SELECT '=== STEP 1: CREATING DEMO CUSTOMER & PRODUCTS ===' AS demo_step;

INSERT INTO customers (customer_id, full_name, email, phone_number)
VALUES
('11111111-1111-1111-1111-111111111111', 'Jane Doe (Demo)', 'jane.demo@example.com', '+250-788-000-000')
ON CONFLICT (email) DO NOTHING;

INSERT INTO products (product_id, product_name, category, unit_price, stock_quantity, reorder_level, reorder_quantity)
VALUES
('22222222-2222-2222-2222-222222222222', 'Demo Workstation Laptop', 'Electronics', 1500.00, 20, 5, 10),
('33333333-3333-3333-3333-333333333333', 'Demo Mechanical Keyboard', 'Electronics', 100.00, 30, 10, 25)
ON CONFLICT (product_id) DO NOTHING;

-- Display initial customer tier & spending ($0.00, Bronze)
SELECT
    full_name,
    total_spent,
    customer_tier
FROM customers
WHERE customer_id = '11111111-1111-1111-1111-111111111111';


-- STEP 2: PLACE ORDER WITH BULK DISCOUNT & STOCK DEDUCTION
-- Place an order for 25 Keyboards (qualifies for 10% bulk discount) and 18 Laptops

SELECT '=== STEP 2: ATOMIC ORDER PLACEMENT VIA PROCEDURE ===' AS demo_step;

DO $$
DECLARE
    v_order_id UUID;
    v_payload JSONB;
BEGIN
    v_payload := '[
        {"product_id": "33333333-3333-3333-3333-333333333333", "quantity": 25},
        {"product_id": "22222222-2222-2222-2222-222222222222", "quantity": 18}
    ]'::jsonb;

    CALL sp_place_order('11111111-1111-1111-1111-111111111111', v_payload, v_order_id);
    RAISE NOTICE 'Order successfully created with Order ID: %', v_order_id;
END;
$$;

-- Verify Order Total, Items, and Applied Discounts
SELECT * FROM v_order_summary
WHERE customer_id = '11111111-1111-1111-1111-111111111111';

-- Verify Automatic Customer Tier Upgrade (Spend > $5,000 -> Gold Tier)
SELECT
    full_name,
    total_spent,
    customer_tier
FROM customers
WHERE customer_id = '11111111-1111-1111-1111-111111111111';


-- STEP 3: INSPECT INVENTORY LOGS & LOW STOCK ALERTS
-- Laptop stock went from 20 -> 2 (dips below reorder_level 5)
-- Keyboard stock went from 30 -> 5 (dips below reorder_level 10)

SELECT '=== STEP 3: LOW STOCK REORDER ALERTS ===' AS demo_step;

SELECT
    product_name,
    stock_quantity,
    reorder_level,
    reorder_quantity,
    stock_deficit
FROM v_low_stock_alerts
WHERE product_id IN ('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333');


-- STEP 4: REPLENISH LOW STOCK PRODUCTS
-- Trigger sp_replenish_stock to restock items below threshold.
-- Passing NULL means "replenish every product currently at or below its
-- own reorder_level" - both demo products qualify after Step 2, so one
-- call restocks both (laptop +10, keyboard +25) in a single statement.

SELECT '=== STEP 4: EXECUTING AUTOMATED STOCK REPLENISHMENT ===' AS demo_step;

CALL sp_replenish_stock(NULL);

-- Verify Low Stock Alerts are cleared
SELECT COUNT(*) AS remaining_low_stock_items
FROM v_low_stock_alerts
WHERE product_id IN ('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333');

-- Inspect Inventory Audit Logs for Replenishment Entries
SELECT
    il.log_id,
    p.product_name,
    il.change_quantity,
    il.previous_stock,
    il.new_stock,
    il.change_reason,
    il.logged_at
FROM inventory_logs AS il
INNER JOIN products AS p ON il.product_id = p.product_id
WHERE il.product_id IN ('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333')
ORDER BY il.log_id DESC;


-- STEP 5: CANCEL ORDER & REVERT CUSTOMER TIER
-- Cancel the demo order, restoring stock and updating spending tier.
-- Looked up by "most recent order for this customer" rather than a
-- hardcoded order_id, since sp_place_order generates a fresh UUID for
-- v_order_id every run - there is no fixed ID to reference here the way
-- the customer/product IDs above are fixed.

SELECT '=== STEP 5: ATOMIC ORDER CANCELLATION & TIER DEMOTION ===' AS demo_step;

DO $$
DECLARE
    v_demo_order_id UUID;
BEGIN
    SELECT order_id INTO v_demo_order_id
    FROM orders
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
    ORDER BY order_date DESC
    LIMIT 1;

    CALL sp_cancel_order(v_demo_order_id);
END;
$$;

-- Verify Customer spending re-evaluated to $0.00 (Bronze)
SELECT
    full_name,
    total_spent,
    customer_tier
FROM customers
WHERE customer_id = '11111111-1111-1111-1111-111111111111';

-- No cleanup here by design: this data is the evidence README Step 6
-- (sql/05_reports_and_queries.sql) and Step 7 (Adminer) read back. See the
-- STEP 0 note above for how the next run resets it instead.

COMMIT;

SELECT '=== DEMO WALKTHROUGH COMPLETED SUCCESSFULLY ===' AS demo_status;
