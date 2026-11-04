CREATE TABLE orders (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id    bigint NOT NULL,
  restaurant_id  bigint NOT NULL,
  status         text   NOT NULL DEFAULT 'awaiting_payment',
  total_cents    integer NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE payments (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id         bigint NOT NULL REFERENCES orders(id),
  idempotency_key  uuid   NOT NULL UNIQUE,
  amount_cents     integer NOT NULL,
  approved_at      timestamptz NOT NULL DEFAULT now()
);
