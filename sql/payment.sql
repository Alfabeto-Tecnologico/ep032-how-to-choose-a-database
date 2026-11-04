BEGIN;
INSERT INTO payments (order_id, idempotency_key, amount_cents) VALUES ($1, $2, $3);
UPDATE orders SET status = 'paid' WHERE id = $1 AND status = 'awaiting_payment';
COMMIT;
