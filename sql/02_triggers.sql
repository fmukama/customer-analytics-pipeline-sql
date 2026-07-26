-- File: sql/02_triggers.sql
-- Description: Database Automation - Triggers for Discounts, Inventory,
--              Order Totals, and Customer Spending Tiers.
--
-- Firing order matters for the two triggers that share AFTER INSERT ON
-- order_details (trg_2, trg_3): PostgreSQL fires same-timing triggers on the
-- same table/event in ALPHABETICAL ORDER BY TRIGGER NAME, not creation
-- order. They are deliberately named trg_1_/trg_2_/trg_3_ so that ordering
-- is explicit in the name itself, not an accident of how they happen to
-- sort: trg_2 (deduct stock, log it) must run before trg_3 (recompute the
-- order total from the now-final set of line items).

-- Idempotent reset of triggers and functions
DROP TRIGGER IF EXISTS trg_1_apply_bulk_discount ON order_details;
DROP TRIGGER IF EXISTS trg_2_process_inventory_and_log ON order_details;
DROP TRIGGER IF EXISTS trg_3_update_order_total ON order_details;
DROP TRIGGER IF EXISTS trg_recalculate_customer_tier ON orders;

DROP FUNCTION IF EXISTS fn_apply_bulk_discount();
DROP FUNCTION IF EXISTS fn_process_inventory_and_log();
DROP FUNCTION IF EXISTS fn_update_order_total();
DROP FUNCTION IF EXISTS fn_recalculate_customer_tier();


-- 1. BULK DISCOUNT TRIGGER
-- Rule: qty >= 50 -> 15%, qty >= 25 -> 10%, qty >= 10 -> 5%
-- Bands are checked largest-first, so a qty of 50 gets 15% rather than
-- falling through to the >= 25 or >= 10 branch - only the first matching
-- IF/ELSIF wins.
--
-- BEFORE INSERT (not AFTER): this trigger only ever needs to set a column
-- on the row that is about to be written. Doing that in a BEFORE trigger
-- lets it just assign NEW.discount_percent and let Postgres write the
-- already-correct value in a single pass, instead of writing the row once
-- and then UPDATEing it again afterwards.

CREATE OR REPLACE FUNCTION fn_apply_bulk_discount()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.quantity >= 50 THEN
        NEW.discount_percent := 15.00;
    ELSIF NEW.quantity >= 25 THEN
        NEW.discount_percent := 10.00;
    ELSIF NEW.quantity >= 10 THEN
        NEW.discount_percent := 5.00;
    ELSE
        NEW.discount_percent := 0.00;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_1_apply_bulk_discount
BEFORE INSERT ON order_details
FOR EACH ROW
EXECUTE FUNCTION fn_apply_bulk_discount();


-- 2. STOCK DEDUCTION & INVENTORY AUDIT LOG TRIGGER
-- Rule: Row-lock product, verify stock >= quantity, deduct, log ORDER_PLACEMENT
--
-- This is the trigger that makes overselling impossible under concurrency.
-- SELECT ... FOR UPDATE takes an exclusive row lock on the product BEFORE
-- its stock is read, so if two customers try to buy the last few units of
-- the same product at the same instant, the second transaction blocks here
-- until the first one commits or rolls back - it never reads a stale
-- stock_quantity and oversells. This is proven under real concurrent load
-- in tests/test_concurrency.py, not just asserted in a comment.

CREATE OR REPLACE FUNCTION fn_process_inventory_and_log()
RETURNS TRIGGER AS $$
DECLARE
    v_current_stock INTEGER;
    v_new_stock     INTEGER;
BEGIN
    -- Row-level lock on products to prevent concurrent race conditions
    SELECT stock_quantity INTO v_current_stock
    FROM products
    WHERE product_id = NEW.product_id
    FOR UPDATE;

    IF v_current_stock < NEW.quantity THEN
        RAISE EXCEPTION 'INSUFFICIENT_STOCK: Product % has % in stock, but % requested.',
            NEW.product_id, v_current_stock, NEW.quantity;
    END IF;

    v_new_stock := v_current_stock - NEW.quantity;

    -- Update product stock
    UPDATE products
    SET stock_quantity = v_new_stock,
        updated_at = NOW()
    WHERE product_id = NEW.product_id;

    -- Write append-only inventory audit record. change_quantity is negative
    -- here (stock going down); sp_replenish_stock and sp_cancel_order write
    -- the same table with a positive value, and chk_inventory_math on
    -- inventory_logs enforces that previous_stock + change_quantity always
    -- equals new_stock for every row, regardless of which of the three
    -- wrote it.
    INSERT INTO inventory_logs (
        product_id, order_id, change_quantity, previous_stock, new_stock, change_reason
    ) VALUES (
        NEW.product_id, NEW.order_id, -NEW.quantity, v_current_stock, v_new_stock, 'ORDER_PLACEMENT'
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_2_process_inventory_and_log
AFTER INSERT ON order_details
FOR EACH ROW
EXECUTE FUNCTION fn_process_inventory_and_log();


-- 3. RECALCULATE ORDER TOTAL AMOUNT
-- Rule: Aggregate SUM(subtotal) on order_details mutation. Return OLD on DELETE.
--
-- Recomputes from scratch every time rather than incrementing/decrementing
-- total_amount. That is not a stylistic choice: a 3-item order fires this
-- trigger three times (once per INSERT), so `total_amount += subtotal`
-- would triple-count. SUM(...) over the current row set is idempotent -
-- run it once or run it three times, the answer is the same - and it is
-- also what makes total_amount self-correct after a line item is removed
-- (e.g. by sp_cancel_order's cascade, or any future edit path).
--
-- COALESCE(NEW.order_id, OLD.order_id): NEW is NULL on DELETE and OLD is
-- NULL on INSERT, so this picks whichever one the current TG_OP populated.
-- Note this assumes an order_detail's order_id is never itself changed by an
-- UPDATE - there is no code path that does that today, but if one is added
-- later, this trigger would need to recompute BOTH the old and new order's
-- totals, not just NEW's.

CREATE OR REPLACE FUNCTION fn_update_order_total()
RETURNS TRIGGER AS $$
DECLARE
    v_target_order_id UUID;
BEGIN
    v_target_order_id := COALESCE(NEW.order_id, OLD.order_id);

    UPDATE orders
    SET total_amount = (
        SELECT COALESCE(SUM(subtotal), 0.00)
        FROM order_details
        WHERE order_id = v_target_order_id
    )
    WHERE order_id = v_target_order_id;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_3_update_order_total
AFTER INSERT OR UPDATE OR DELETE ON order_details
FOR EACH ROW
EXECUTE FUNCTION fn_update_order_total();


-- 4. RECALCULATE CUSTOMER SPEND & TIER
-- Rule: Total spent derived ONLY from CONFIRMED orders.
-- Tier thresholds: < 1000 Bronze, 1000-4999.99 Silver, >= 5000 Gold.
--
-- Same "recompute, don't increment" reasoning as trg_3 above applies here,
-- one level up: placing an order fires this trigger at least twice for the
-- same customer (once on the orders INSERT itself, again when trg_3's
-- cascading UPDATE on orders.total_amount re-fires it) - and again on every
-- subsequent order or cancellation. SUM(...) over that customer's current
-- CONFIRMED orders is correct no matter how many times it runs, which is
-- also what lets a cancellation demote a tier automatically: excluding
-- CANCELLED orders from the SUM means total_spent - and therefore
-- customer_tier - simply reflects reality again the next time this fires.
--
-- WHEN (pg_trigger_depth() < 2): a defensive recursion guard. This trigger
-- only ever writes to `customers`, never back to `orders`, so nothing here
-- can currently trigger itself recursively - but the guard costs nothing
-- and protects against that becoming true by accident in a future edit.
-- It does NOT block the legitimate nested-UPDATE call from trg_3 (verified
-- directly: that invocation runs at depth 2, and the WHEN clause is
-- evaluated at the depth *before* this trigger's own execution begins, so
-- it still passes) - proven by tests/test_procedures.py::test_sp_cancel_order
-- actually promoting a customer's tier via that exact cascade path.

CREATE OR REPLACE FUNCTION fn_recalculate_customer_tier()
RETURNS TRIGGER AS $$
DECLARE
    v_target_customer_id UUID;
    v_total_spent        NUMERIC(12, 2);
    v_new_tier           VARCHAR(10);
BEGIN
    v_target_customer_id := COALESCE(NEW.customer_id, OLD.customer_id);

    -- Calculate aggregate spend strictly for CONFIRMED orders
    SELECT COALESCE(SUM(total_amount), 0.00) INTO v_total_spent
    FROM orders
    WHERE customer_id = v_target_customer_id
      AND order_status = 'CONFIRMED';

    -- Pinned Business Rule Tier Calculation
    IF v_total_spent >= 5000.00 THEN
        v_new_tier := 'Gold';
    ELSIF v_total_spent >= 1000.00 THEN
        v_new_tier := 'Silver';
    ELSE
        v_new_tier := 'Bronze';
    END IF;

    UPDATE customers
    SET total_spent = v_total_spent,
        customer_tier = v_new_tier,
        updated_at = NOW()
    WHERE customer_id = v_target_customer_id;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_recalculate_customer_tier
AFTER INSERT OR UPDATE OF total_amount, order_status OR DELETE ON orders
FOR EACH ROW
WHEN (pg_trigger_depth() < 2)
EXECUTE FUNCTION fn_recalculate_customer_tier();
