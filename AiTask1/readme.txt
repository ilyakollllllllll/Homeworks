Задача 1
Начальный SQL код работающий за 70 секунд выглядит следующим образом

SQL:
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

Спросим llm, какие проблемы она видит в этом запросе
Промпт:
Given a SQL query which works for too long. It contains bottlenecks, and generally is poor optimised.
Your task is:
1. Identify bottlenecks
2. Define optimisation strategies
3. Implement each optimisation strategy

Original SQL query:
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

Ответ:
The original SQL query suffers from performance issues primarily due to non-sargable expressions in `WHERE` clauses and the use of a subquery in a `JOIN` that also contains such an expression. Optimizing this involves rewriting these conditions to be index-friendly and restructuring the query, for instance, by using a Common Table Expression (CTE).

## 1. Identified Bottlenecks

* **Non-SARGable `WHERE` clauses**: The conditions `o.created_at::date = CURRENT_DATE - 1` and `r.created_at::date = CURRENT_DATE - 1` (in the subquery) involve casting the `created_at` column to a date (`::date`). This prevents the database optimizer from effectively using an index on the `created_at` column, leading to full table or index scans instead of efficient seeks.
* **Subquery in `JOIN`**: The subquery to calculate `total_refund` is evaluated and then joined. While not always a bottleneck, when combined with non-sargable predicates inside it, its performance can degrade. CTEs can often improve readability and sometimes offer better optimization paths for the database.
* **Potential Missing Indexes**: For optimal performance, indexes should exist on columns used in `JOIN` conditions (`orders.order_id`, `order_items.order_id`, `refunds.order_id`, `orders.currency_id`, `currencies.currency_id`), `WHERE` clauses (`orders.created_at`, `refunds.created_at`, `order_items.status`), and potentially `GROUP BY` clauses.

---
## 2. Optimization Strategies

* **Make Predicates SARGable (Search Argument Able)**: Modify date-based `WHERE` clauses to use range comparisons on the original timestamp (or date) column without alteration. For instance, instead of `column::date = specific_date`, use `column >= specific_date_start_of_day AND column < specific_date_end_of_day_or_next_day_start_of_day`. This allows the database to use an index on the `column`.
* **Use Common Table Expressions (CTEs)**: Replace the subquery for refunds with a CTE. This can improve the query's readability and logical structure, and allows the sargable predicate for dates to be clearly defined within the CTE.
* **Ensure Proper Indexing**: Although not part of the SQL query text itself, creating appropriate indexes on the tables is crucial. This includes indexes on foreign key columns, columns used in `WHERE` clause filters, and columns used in `JOIN` conditions.

---
## 3. Implemented Optimised SQL Query

The following optimized query applies the strategies discussed. It assumes `created_at` columns in `orders` and `refunds` are of a timestamp data type. The date filtering for "yesterday" is achieved using `DATE_TRUNC` which is common in PostgreSQL (implied by `::date` syntax). If you're using a different SQL dialect, the exact date functions might vary (e.g., `CAST(CURRENT_DATE - INTERVAL '1 DAY' AS DATE)`).

```sql
WITH daily_refunds AS (
    -- Calculate total refunds for yesterday, making the date predicate SARGable
    -- This CTE filters refunds for the entirety of yesterday
    SELECT
        order_id,
        SUM(amount) AS total_refund
    FROM refunds
    -- Assumes refunds.created_at is a timestamp.
    -- Filters for records from the start of yesterday up to (but not including) the start of today.
    WHERE created_at >= DATE_TRUNC('day', CURRENT_TIMESTAMP - INTERVAL '1 day')
      AND created_at < DATE_TRUNC('day', CURRENT_TIMESTAMP)
    GROUP BY order_id
)
SELECT
    o.order_id,
    o.customer_id,
    -- Calculate gross sales only for 'FULFILLED' items from order_items
    SUM(CASE WHEN oi.status = 'FULFILLED' THEN oi.quantity * oi.unit_price ELSE 0 END) AS gross_sales,
    -- Use COALESCE to show 0 if no refunds exist for an order
    COALESCE(dr.total_refund, 0) AS total_refund,
    c.iso_code AS currency
FROM orders o
LEFT JOIN order_items oi
    ON oi.order_id = o.order_id
LEFT JOIN daily_refunds dr                   -- Join with the CTE for refunds
    ON dr.order_id = o.order_id
LEFT JOIN currencies c
    ON c.currency_id = o.currency_id
-- Filter orders for yesterday, making the date predicate SARGable
-- Assumes orders.created_at is a timestamp.
-- Filters for records from the start of yesterday up to (but not including) the start of today.
WHERE o.created_at >= DATE_TRUNC('day', CURRENT_TIMESTAMP - INTERVAL '1 day')
  AND o.created_at < DATE_TRUNC('day', CURRENT_TIMESTAMP)
GROUP BY
    o.order_id,
    o.customer_id,
    dr.total_refund, -- Included because it's in the SELECT list and not strictly dependent on o.order_id for grouping purposes before aggregation
    c.iso_code
ORDER BY
    gross_sales DESC;
```

### Key changes and why they help:

* **SARGable Date Conditions**: The `WHERE` clauses for `orders.created_at` and `refunds.created_at` now use a range check:
    `created_at >= DATE_TRUNC('day', CURRENT_TIMESTAMP - INTERVAL '1 day') AND created_at < DATE_TRUNC('day', CURRENT_TIMESTAMP)`
    This defines "all of yesterday" for a timestamp column and allows the database to efficiently use an index on `created_at`.
* **CTE for Refunds**: The subquery for refunds has been converted into a CTE named `daily_refunds`. This makes the query cleaner and applies the optimized date filtering directly within the CTE.
* **Preserved Logic**: The core logic of calculating `gross_sales` (only for 'FULFILLED' items) and `total_refund` (summed for the previous day) remains the same, as do the `LEFT JOIN`s to ensure all relevant orders are captured.

---
### Indexing Recommendations (Crucial for Performance)

To ensure the optimized query runs efficiently, the following indexes are recommended. The exact syntax for creating indexes may vary based on your specific SQL database:

```sql
-- On the 'orders' table
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders (created_at);
CREATE INDEX IF NOT EXISTS idx_orders_currency_id ON orders (currency_id); -- Often created by FK constraint

-- On the 'order_items' table
CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON order_items (order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_status ON order_items (status); -- Effective if status has good selectivity

-- On the 'refunds' table
CREATE INDEX IF NOT EXISTS idx_refunds_order_id_created_at ON refunds (order_id, created_at); -- Composite index can be very effective
-- OR separately if queries often filter only by one:
-- CREATE INDEX IF NOT EXISTS idx_refunds_order_id ON refunds (order_id);
-- CREATE INDEX IF NOT EXISTS idx_refunds_created_at ON refunds (created_at);


-- On the 'currencies' table
-- CREATE INDEX IF NOT EXISTS idx_currencies_currency_id ON currencies (currency_id); -- Usually a primary key and automatically indexed
```
Ensure primary keys (`orders.order_id`, `order_items.order_item_id` (if exists), `refunds.refund_id` (if exists), `currencies.currency_id`) are also indexed, which is typically done automatically. Regularly analyze query performance (e.g., using `EXPLAIN ANALYZE`) to confirm that indexes are being used as expected.

И так, из изначальных проблем он обнаружил 2 запроса (основной и подзапрос с join), остальные 2 join и spill risk за проблему он не посчитал, и, на самом деле, мы ничего от этого не потеряли, так как оставшиеся 2 hash джоина с точки зрения запроса упростить нельзя, а Spill Risk всегда само собой разумеющееся + сам риск скорее отражает уже имеющееся проблемы оптимизации запроса, а не является отдельной проблемой в данном случае. Считаю, что с нахождением проблемных мест LLM справилась на 8\10.

Из оптимизаций он предложил индексироване и включил в индексы все ключевые колонки, вынес подзапрос в CTE и избавился от каста индексированной колонки. Тем не менее, все еще можно применить оконную функцию + добавить фильтр status='FULFILLED'. Укажем LLM на это в нашем следующем запросе:

Your answer still miss some optimisations:
1. Rewrite with window functions to remove the self-aggregating sub-query.
2. Filter early by moving status='FULFILLED' and the date predicate into CTEs.
3. Include this status filter to the indexing

Получили такой ответ:

You're right to push for even more fine-grained optimizations! The previous suggestions focused on the most common and impactful issues. Let's incorporate your advanced points: using window functions for refunds, filtering earlier with more CTEs, and refining indexing for status-based filters.

These further optimizations aim to reduce the amount of data processed at each stage of the query and leverage more specialized database features.

---
## 1. Identified Bottlenecks (Revisited for Advanced Optimization)

While the previous optimization addressed major issues, we can further refine by considering:

* **Late Aggregation**: Aggregating sums (`gross_sales`, `total_refund`) after joining several tables can mean the aggregation step processes a larger intermediate result set than necessary.
* **Sub-optimal Aggregation Patterns**: While a `GROUP BY` in a subquery/CTE for refunds is clear, a window function might offer different execution plans that could be beneficial in some RDBMS or if further per-item details were needed alongside the sum (though here we use `DISTINCT` to mimic `GROUP BY`). The user specifically requested exploring this.
* **Generic Indexing for Specific Filters**: A general index on `status` is good, but for highly selective and common filters like `status = 'FULFILLED'`, more specialized indexing (like partial indexes) can be even more effective.

---
## 2. Defined Optimisation Strategies (Enhanced)

Based on the bottlenecks and your suggestions:

1.  **Aggressively Filter and Aggregate Early via CTEs**:
    * Create a CTE for `orders` filtered by yesterday's date.
    * Create a CTE for `order_items` that *only* includes `'FULFILLED'` items and immediately aggregates `gross_sales` per `order_id`.
    * Create a CTE for `refunds` filtered by yesterday's date.
2.  **Utilize Window Functions for Refund Aggregation**:
    * Calculate `total_refund` per `order_id` using a window function (`SUM() OVER (PARTITION BY ...)`) on the filtered refund data, followed by `DISTINCT` to get one value per order. This replaces the `GROUP BY` in the refund calculation CTE.
3.  **Eliminate Final `GROUP BY`**: By performing all aggregations within CTEs such that each CTE provides unique `order_id` rows, the final `SELECT` statement can avoid a `GROUP BY` clause, simplifying the main query block.
4.  **Specialized Indexing for Filters**: Recommend partial indexes or finely-tuned composite indexes for columns with highly selective filter criteria, such as `order_items.status = 'FULFILLED'`.

---
## 3. Implemented Optimised SQL Query (with Window Functions and Early Filtering)

This version breaks down the query into more focused CTEs, performs aggregations earlier, and uses a window function for calculating total refunds.

```sql
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

```

### Key Changes in this Version:

* **`yesterdays_orders` CTE**: Isolates filtering for orders from yesterday.
* **`fulfilled_items_sales` CTE**: Filters for `order_items.status = 'FULFILLED'` and immediately calculates `SUM(quantity * unit_price)` per `order_id`. This is early filtering and aggregation.
* **`yesterdays_refund_details` CTE**: Isolates filtering for refund line items from yesterday.
* **`order_total_refunds` CTE**: Uses `SUM(amount) OVER (PARTITION BY order_id)` on the `yesterdays_refund_details` to get the total refund for each order. `DISTINCT` then ensures that we get one row per `order_id` with this total, effectively replacing a `GROUP BY` operation for this step.
* **No Final `GROUP BY`**: Because `yesterdays_orders` provides unique `order_id`s (assuming `order_id` is primary key or has a unique constraint for the filtered set), and both `fulfilled_items_sales` and `order_total_refunds` are aggregated to be unique per `order_id` before joining, the final `SELECT` statement doesn't require a `GROUP BY` clause. This can simplify the execution plan for the final assembly of results.
* **`COALESCE`**: Used to ensure 0 is shown for orders with no fulfilled items or no refunds.

---
### Enhanced Indexing Recommendations (Including Status Filter)

To support this more granular CTE structure:

1.  **For `orders` table (supporting `yesterdays_orders` CTE):**
    ```sql
    CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders (created_at);
    -- Index on orders.currency_id (often covered by FK)
    -- CREATE INDEX IF NOT EXISTS idx_orders_currency_id ON orders (currency_id);
    ```

2.  **For `order_items` table (supporting `fulfilled_items_sales` CTE):**
    The query `SELECT oi.order_id, SUM(oi.quantity * oi.unit_price) FROM order_items oi WHERE oi.status = 'FULFILLED' GROUP BY oi.order_id` benefits greatly from an index that handles both the `status` filter and the `order_id` grouping.

    * **Option A: Composite Index:**
        ```sql
        CREATE INDEX IF NOT EXISTS idx_order_items_status_orderid ON order_items (status, order_id);
        ```
        If `quantity` and `unit_price` are included, it can become a covering index for the aggregation part:
        ```sql
        CREATE INDEX IF NOT EXISTS idx_order_items_status_orderid_covering ON order_items (status, order_id, quantity, unit_price);
        ```

    * **Option B: Partial Index (often best for highly selective fixed values like 'FULFILLED'):**
        ```sql
        CREATE INDEX IF NOT EXISTS idx_order_items_fulfilled_orderid_covering ON order_items (order_id, status) WHERE status = 'FULFILLED';
        ```
        This index is smaller as it only includes rows where `status = 'FULFILLED'` and directly provides `order_id` and `status` for efficient grouping and summation.

3.  **For `refunds` table (supporting `yesterdays_refund_details` and `order_total_refunds` CTEs):**
    A composite index on `(created_at, order_id, amount)` can be beneficial for filtering by `created_at` and then partitioning by `order_id` and summing `amount`.
    ```sql
    CREATE INDEX IF NOT EXISTS idx_refunds_createdat_orderid_amount ON refunds (created_at, order_id, amount);
    -- Or, if partitioning by order_id after date filter is more common:
    -- CREATE INDEX IF NOT EXISTS idx_refunds_orderid_createdat_amount ON refunds (order_id, created_at, amount);
    -- Simpler index if the above is too wide:
    -- CREATE INDEX IF NOT EXISTS idx_refunds_created_at_order_id ON refunds (created_at, order_id);
    ```

4.  **For `currencies` table:**
    ```sql
    -- CREATE INDEX IF NOT EXISTS idx_currencies_currency_id ON currencies (currency_id); -- Usually PK
    ```

These advanced strategies and specialized indexing should lead to significant performance improvements, especially on large datasets, by minimizing data movement and enabling more efficient data access patterns. Always test with `EXPLAIN ANALYZE` (or your RDBMS equivalent) to verify the effectiveness of these changes.

Теперь, когда ответ выглядит полным, мы получили готовый SQL запрос + набор необходимых индексов. Итоговый вариант можно посмотреть в файле subtask1_llm.sql


Теперь попрбоуем с Cursor
Результат до и после "Rewrite to use a single window-function to pass over order_items (partition by order_id) and JOIN that result to orders. Eliminate the refunds sub-query by turning it into a window sum on refunds with a FILTER clause. Add EXPLAIN ANALYZE before and after." будет в файле subtask1_cursor.sql









Задача 2
Для начала выполним скрипт инциализации из условия:

CREATE TABLE orders (
    id INTEGER PRIMARY KEY,
    customer TEXT,
    amount REAL,
    order_date DATE
);

INSERT INTO orders (customer, amount, order_date) VALUES
('Alice', 5000, '2024-03-01'),
('Bob', 8000, '2024-03-05'),
('Alice', 3000, '2024-03-15'),
('Charlie', 7000, '2024-02-20'),
('Alice', 10000, '2024-02-28'),
('Bob', 4000, '2024-02-10'),
('Charlie', 9000, '2024-03-22'),
('Alice', 2000, '2024-03-30');

Далее отправим следующий промпт в LLM:
"
Solve the tasks

Input Data (Script to Populate the Table):

Run this script in SQLite Online:



CREATE TABLE orders (

    id INTEGER PRIMARY KEY,

    customer TEXT,

    amount REAL,

    order_date DATE

);



INSERT INTO orders (customer, amount, order_date) VALUES

('Alice', 5000, '2024-03-01'),

('Bob', 8000, '2024-03-05'),

('Alice', 3000, '2024-03-15'),

('Charlie', 7000, '2024-02-20'),

('Alice', 10000, '2024-02-28'),

('Bob', 4000, '2024-02-10'),

('Charlie', 9000, '2024-03-22'),

('Alice', 2000, '2024-03-30');



Tasks:

Calculate the total sales volume for March 2024.



Find the customer who spent the most overall.



Calculate the average order value for the last three months.
"


Ответ, если честно, шокировал:
Here are the solutions to your tasks:

## March 2024 Sales Volume

The total sales volume for March 2024 is **$27,000**. This is calculated by summing the amounts of all orders placed in March 2024.

---
## Top Spending Customer

The customer who spent the most overall is **Alice**, with a total spending of **$20,000**.

---
## Average Order Value (Last Three Months)

The average order value for the last three months (January, February, and March 2024, based on the provided data) is **$6,000**. This is calculated by dividing the total amount of all orders by the total number of orders.


LLM нам просто выдала правильные ответы на поставленные вопросы, но так не интересно, поэтому следующим промптом попросим ее написать sql код
Промпт:
Write a sql code to calculate this

Ответ (код):
-- Create the orders table (if it doesn't exist)
CREATE TABLE IF NOT EXISTS orders (
    id INTEGER PRIMARY KEY,
    customer TEXT,
    amount REAL,
    order_date DATE
);

-- Insert sample data (if the table is empty)
-- Note: In a real scenario, you'd check if this data already exists
-- or handle potential primary key conflicts if re-running.
-- For this example, we assume it's run on a fresh table or a table
-- where these specific IDs don't yet exist.
INSERT INTO orders (id, customer, amount, order_date) VALUES
(1, 'Alice', 5000, '2024-03-01'),
(2, 'Bob', 8000, '2024-03-05'),
(3, 'Alice', 3000, '2024-03-15'),
(4, 'Charlie', 7000, '2024-02-20'),
(5, 'Alice', 10000, '2024-02-28'),
(6, 'Bob', 4000, '2024-02-10'),
(7, 'Charlie', 9000, '2024-03-22'),
(8, 'Alice', 2000, '2024-03-30')
ON CONFLICT(id) DO NOTHING; -- Prevents errors if data is re-inserted

-- Task 1: Calculate the total sales volume for March 2024.
SELECT
    SUM(amount) AS total_sales_march_2024
FROM
    orders
WHERE
    order_date >= '2024-03-01' AND order_date <= '2024-03-31';

-- Task 2: Find the customer who spent the most overall.
SELECT
    customer,
    SUM(amount) AS total_spent
FROM
    orders
GROUP BY
    customer
ORDER BY
    total_spent DESC
LIMIT 1;

-- Task 3: Calculate the average order value for the last three months.
-- Based on the provided data, the relevant months are February and March 2024.
-- If January data existed, the condition would be order_date >= '2024-01-01'.
SELECT
    AVG(amount) AS average_order_value_last_months
FROM
    orders
WHERE
    order_date >= '2024-01-01' AND order_date <= '2024-03-31';
    -- The original data only has Feb and Mar, so effectively '2024-02-01' to '2024-03-31'
    -- Using '2024-01-01' makes the query robust if January data were added.

-- For a more precise "last three months" if the data spanned more,
-- and assuming '2024-03-31' is the "current" reference point for "last three months":
SELECT
    AVG(amount) AS average_order_value_feb_mar_2024
FROM
    orders
WHERE
    order_date >= DATE('2024-03-31', '-3 months') AND order_date <= '2024-03-31';
-- SQLite's date functions might need specific handling for 'start of month' logic
-- if you need exactly Jan, Feb, Mar.
-- A simpler approach given the data:
SELECT
    AVG(amount) AS average_order_value_feb_mar_2024_specific
FROM
    orders
WHERE
    (STRFTIME('%Y-%m', order_date) = '2024-03') OR
    (STRFTIME('%Y-%m', order_date) = '2024-02') OR
    (STRFTIME('%Y-%m', order_date) = '2024-01');


Получилось совсем неинтересно - данные SQL запросы просто выдают правильные ответы.

