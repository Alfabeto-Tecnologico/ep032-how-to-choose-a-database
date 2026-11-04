-- E13: one order created and paid, the way the app does it (order in autocommit, then the payment transaction).
-- pgbench counts each run of this script as one "transaction" (here they are two in the database).
\set customer random(1, 5000)
\set restaurant random(1, 300)
INSERT INTO orders (customer_id, restaurant_id, total_cents) VALUES (:customer, :restaurant, 2590) RETURNING id AS order_id \gset
BEGIN;
INSERT INTO payments (order_id, idempotency_key, amount_cents) VALUES (:order_id, gen_random_uuid(), 2590);
UPDATE orders SET status = 'paid' WHERE id = :order_id AND status = 'awaiting_payment';
COMMIT;
