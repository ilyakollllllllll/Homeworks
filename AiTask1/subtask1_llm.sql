-- Create indexes first
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders (created_at);
CREATE INDEX IF NOT EXISTS idx_order_items_fulfilled_orderid_covering ON order_items (status, order_id) WHERE status = 'FULFILLED';
CREATE INDEX IF NOT EXISTS idx_refunds_created_at_order_id ON refunds (created_at, order_id);

-- CTE for orders created yesterday
WITH yesterdays_orders AS (
    SELECT
        o.order_id,
        o.customer_id,
        o.currency_id
    FROM orders o
    WHERE o.created_at >= DATE_TRUNC('day', CURRENT_TIMESTAMP - INTERVAL '1 day')
      AND o.created_at < DATE_TRUNC('day', CURRENT_TIMESTAMP)
),
-- CTE for fulfilled order items, aggregated to get gross sales per order
-- This filters by status='FULFILLED' and aggregates early.
fulfilled_items_sales AS (
    SELECT
        oi.order_id,
        SUM(oi.quantity * oi.unit_price) AS calculated_gross_sales
    FROM order_items oi
    WHERE oi.status = 'FULFILLED'
    -- No date filter here; items belong to orders which are filtered in 'yesterdays_orders'
    GROUP BY oi.order_id
),
-- CTE for refund line items from yesterday
yesterdays_refund_details AS (
    SELECT
        r.order_id,
        r.amount
    FROM refunds r
    WHERE r.created_at >= DATE_TRUNC('day', CURRENT_TIMESTAMP - INTERVAL '1 day')
      AND r.created_at < DATE_TRUNC('day', CURRENT_TIMESTAMP)
),
-- CTE to calculate total refund per order using a window function
-- The DISTINCT ensures one row per order_id after the window function.
order_total_refunds AS (
    SELECT DISTINCT -- Crucial to get one unique row per order_id
        urd.order_id,
        SUM(urd.amount) OVER (PARTITION BY urd.order_id) AS calculated_total_refund
    FROM yesterdays_refund_details urd
)
-- Main query joining the prepared CTEs
SELECT
    yo.order_id,
    yo.customer_id,
    COALESCE(fis.calculated_gross_sales, 0) AS gross_sales,
    COALESCE(otr.calculated_total_refund, 0) AS total_refund,
    c.iso_code AS currency
FROM yesterdays_orders yo
LEFT JOIN fulfilled_items_sales fis
    ON yo.order_id = fis.order_id
LEFT JOIN order_total_refunds otr
    ON yo.order_id = otr.order_id
LEFT JOIN currencies c
    ON c.currency_id = yo.currency_id
-- No final GROUP BY needed as aggregations are done in CTEs,
-- and each CTE provides unique order_id records for the join.
ORDER BY
    gross_sales DESC;