-- File: sql/03_procedures.sql
-- Description: Atomic operations for Order Placement, Stock Replenishment, and Order Cancellation.
--
-- None of these three procedures issue their own COMMIT or ROLLBACK.
-- Transaction control stays with the caller - that is what makes each one
-- atomic from the outside: if anything inside raises an exception, the
-- caller's transaction (and therefore everything this procedure already
-- did) rolls back as a whole, never partially. It is also what lets
-- tests/conftest.py wrap every test in a transaction it rolls back itself.


-- Idempotent reset of procedures
DROP PROCEDURE IF EXISTS sp_place_order(UUID, JSONB, UUID);
DROP PROCEDURE IF EXISTS sp_replenish_stock(UUID);
DROP PROCEDURE IF EXISTS sp_cancel_order(UUID);


-- 1. PROCEDURE: sp_place_order
-- Description: Creates an order header and inserts line items atomically.
--              Aggregates duplicate product IDs in p_items JSONB input payload.
-- Inputs:
--   p_customer_id : UUID of the purchasing customer
--   p_items       : JSONB array, e.g. '[{"product_id": "...", "quantity": 5}]'
-- Output:
--   p_order_id    : OUT UUID generated for the placed order
--
-- Every line item insert below fires all three order_details triggers in
-- sql/02_triggers.sql: the bulk discount, the stock deduction + audit log,
-- and the order-total recompute. This procedure itself never touches
-- discount_percent, stock_quantity, or total_amount directly - it only
-- ever inserts rows and lets the trigger layer derive everything else.

CREATE OR REPLACE PROCEDURE sp_place_order(
    p_customer_id UUID,
    p_items JSONB,
    INOUT p_order_id UUID DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_item RECORD;
    v_unit_price NUMERIC(10, 2);
    v_current_stock INTEGER;
    v_customer_exists BOOLEAN;
BEGIN
    -- 1. Validate payload non-empty
    IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'INVALID_PAYLOAD: Order must contain at least one item.';
    END IF;

    -- 2. Validate customer existence explicitly, so a bad customer_id
    -- raises a clear CUSTOMER_NOT_FOUND message here rather than a raw
    -- foreign-key-violation error from the INSERT below.
    SELECT EXISTS (
        SELECT 1 FROM customers WHERE customer_id = p_customer_id
    ) INTO v_customer_exists;

    IF NOT v_customer_exists THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND: Customer with ID % does not exist.', p_customer_id;
    END IF;

    -- 3. Create the order header as CONFIRMED immediately - not PENDING.
    -- This is safe precisely because this whole procedure is one atomic
    -- unit: if any line item below fails (insufficient stock, an unknown
    -- product), the RAISE EXCEPTION aborts the entire call, and this INSERT
    -- is rolled back right along with it. A CONFIRMED order row is never
    -- left behind with missing or partial line items.
    INSERT INTO orders (customer_id, order_status)
    VALUES (p_customer_id, 'CONFIRMED')
    RETURNING order_id INTO p_order_id;

    -- 4. Aggregate input payload by product_id to prevent duplicate key
    -- constraint violations: order_details has UNIQUE (order_id, product_id),
    -- so if the caller's JSON lists the same product twice (e.g. added to
    -- a cart in two separate clicks), summing their quantities here into
    -- one group is what lets the order still succeed as a single line.
    FOR v_item IN
        SELECT
            (elem->>'product_id')::UUID AS product_id,
            SUM((elem->>'quantity')::INTEGER) AS total_quantity
        FROM jsonb_array_elements(p_items) AS elem
        GROUP BY (elem->>'product_id')::UUID
    LOOP
        -- Check quantity validity
        IF v_item.total_quantity <= 0 THEN
            RAISE EXCEPTION 'INVALID_QUANTITY: Requested quantity % for product % must be greater than zero.',
                v_item.total_quantity, v_item.product_id;
        END IF;

        -- Row-level lock on product for update safety: this is the same
        -- FOR UPDATE lock trg_2_process_inventory_and_log will need a
        -- moment later for the same row, so taking it here means the stock
        -- check below and the trigger's own deduction see a consistent,
        -- unchanging value - no other transaction can slip in between.
        SELECT unit_price, stock_quantity
        INTO v_unit_price, v_current_stock
        FROM products
        WHERE product_id = v_item.product_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND: Product % does not exist.', v_item.product_id;
        END IF;

        IF v_current_stock < v_item.total_quantity THEN
            RAISE EXCEPTION 'INSUFFICIENT_STOCK: Product % has % in stock, but % requested.',
                v_item.product_id, v_current_stock, v_item.total_quantity;
        END IF;

        -- Insert line item (fires bulk discount, inventory deduction, and order total triggers).
        -- unit_price is copied from the product NOW, as a snapshot - so a
        -- later price change never rewrites the value of this order.
        INSERT INTO order_details (order_id, product_id, quantity, unit_price)
        VALUES (p_order_id, v_item.product_id, v_item.total_quantity, v_unit_price);
    END LOOP;
END;
$$;


-- 2. PROCEDURE: sp_replenish_stock
-- Description: Identifies products at or below reorder_level and increases stock
--              by reorder_quantity. Appends REPLENISHMENT audit log.
-- Inputs:
--   p_product_id : Optional UUID.
--                  NULL      -> replenish every product currently at or
--                               below its own reorder_level (the automatic
--                               replenishment mode - this is what make demo,
--                               make seed, and tests use).
--                  a specific -> replenish that ONE product unconditionally,
--                  product_id   even if it is not currently low on stock.
--                               This is a manual top-up path: it exists for
--                               an operator who wants to restock a specific
--                               product on demand, and is intentionally not
--                               gated by reorder_level. Verified directly
--                               against a well-stocked product (500 units,
--                               reorder_level 10) - it still added
--                               reorder_quantity on top.

CREATE OR REPLACE PROCEDURE sp_replenish_stock(
    p_product_id UUID DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prod RECORD;
    v_new_stock INTEGER;
BEGIN
    FOR v_prod IN
        SELECT product_id, stock_quantity, reorder_level, reorder_quantity
        FROM products
        WHERE (p_product_id IS NULL AND stock_quantity <= reorder_level)
           OR (p_product_id IS NOT NULL AND product_id = p_product_id)
        FOR UPDATE
    LOOP
        v_new_stock := v_prod.stock_quantity + v_prod.reorder_quantity;

        -- Update product stock
        UPDATE products
        SET stock_quantity = v_new_stock,
            updated_at = NOW()
        WHERE product_id = v_prod.product_id;

        -- Append-only inventory log. order_id is omitted/NULL here - a
        -- replenishment is never tied to any particular order, unlike
        -- ORDER_PLACEMENT and ORDER_CANCELLATION log rows.
        INSERT INTO inventory_logs (
            product_id, change_quantity, previous_stock, new_stock, change_reason
        ) VALUES (
            v_prod.product_id, v_prod.reorder_quantity, v_prod.stock_quantity, v_new_stock, 'REPLENISHMENT'
        );
    END LOOP;
END;
$$;


-- 3. PROCEDURE: sp_cancel_order
-- Description: Cancels an order, restores inventory stock, writes cancellation
--              audit logs, and triggers customer tier recalculation.
-- Inputs:
--   p_order_id : UUID of the order to cancel
--
-- Verified directly: calling this twice on the same order raises
-- ORDER_ALREADY_CANCELLED on the second call and does NOT restore stock a
-- second time - the "already cancelled" check below is what prevents that.

CREATE OR REPLACE PROCEDURE sp_cancel_order(
    p_order_id UUID
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_status VARCHAR(20);
    v_item RECORD;
    v_current_stock INTEGER;
    v_new_stock INTEGER;
BEGIN
    -- Check order existence and status. FOR UPDATE here locks the order
    -- row itself, so two concurrent cancel attempts on the same order are
    -- serialized rather than both reading "not yet cancelled".
    SELECT order_status INTO v_order_status
    FROM orders
    WHERE order_id = p_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ORDER_NOT_FOUND: Order % does not exist.', p_order_id;
    END IF;

    IF v_order_status = 'CANCELLED' THEN
        RAISE EXCEPTION 'ORDER_ALREADY_CANCELLED: Order % is already cancelled.', p_order_id;
    END IF;

    -- Return stock for each line item and log cancellation. change_quantity
    -- is positive here (stock going back up) - the mirror image of
    -- trg_2_process_inventory_and_log's negative deduction for the same
    -- product when the order was first placed.
    FOR v_item IN
        SELECT product_id, quantity
        FROM order_details
        WHERE order_id = p_order_id
    LOOP
        SELECT stock_quantity INTO v_current_stock
        FROM products
        WHERE product_id = v_item.product_id
        FOR UPDATE;

        v_new_stock := v_current_stock + v_item.quantity;

        UPDATE products
        SET stock_quantity = v_new_stock,
            updated_at = NOW()
        WHERE product_id = v_item.product_id;

        INSERT INTO inventory_logs (
            product_id, order_id, change_quantity, previous_stock, new_stock, change_reason
        ) VALUES (
            v_item.product_id, p_order_id, v_item.quantity, v_current_stock, v_new_stock, 'ORDER_CANCELLATION'
        );
    END LOOP;

    -- Update order status to CANCELLED. This UPDATE OF order_status is what
    -- fires trg_recalculate_customer_tier (sql/02_triggers.sql), which
    -- excludes CANCELLED orders from its SUM - so the customer's
    -- total_spent and customer_tier both correct themselves automatically
    -- as a side effect of this one statement.
    UPDATE orders
    SET order_status = 'CANCELLED'
    WHERE order_id = p_order_id;
END;
$$;
