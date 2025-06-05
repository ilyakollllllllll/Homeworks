-- Before
SELECT
    o.order_id,
    o.customer_id,
    SUM(CASE WHEN oi.status = 'FULFILLED' THEN oi.quantity * oi.unit_price ELSE 0 END) AS gross_sales,
    COALESCE(r.total_refund, 0) AS total_refund,
    c.iso_code                                   AS currency
FROM orders o
LEFT JOIN order_items oi
       ON oi.order_id = o.order_id
LEFT JOIN (
    SELECT
        order_id,
        SUM(amount) AS total_refund
    FROM refunds
    WHERE created_at::date = CURRENT_DATE - 1
    GROUP BY order_id
) r ON r.order_id = o.order_id
LEFT JOIN currencies c
       ON c.currency_id = o.currency_id
WHERE o.created_at::date = CURRENT_DATE - 1
GROUP BY
    o.order_id, o.customer_id, r.total_refund, c.iso_code
ORDER BY gross_sales DESC;


-- After
WITH order_items_sums AS (
    SELECT DISTINCT
        order_id,
        SUM(CASE WHEN status = 'FULFILLED' THEN quantity * unit_price ELSE 0 END) 
            OVER (PARTITION BY order_id) AS gross_sales
    FROM order_items
),
refund_sums AS (
    SELECT DISTINCT
        order_id,
        SUM(amount) FILTER (WHERE created_at::date = CURRENT_DATE - 1)
            OVER (PARTITION BY order_id) AS total_refund
    FROM refunds
)
SELECT
    o.order_id,
    o.customer_id,
    COALESCE(ois.gross_sales, 0) AS gross_sales,
    COALESCE(rs.total_refund, 0) AS total_refund,
    c.iso_code AS currency
FROM orders o
LEFT JOIN order_items_sums ois ON ois.order_id = o.order_id
LEFT JOIN refund_sums rs ON rs.order_id = o.order_id
LEFT JOIN currencies c ON c.currency_id = o.currency_id
WHERE o.created_at::date = CURRENT_DATE - 1
ORDER BY gross_sales DESC;