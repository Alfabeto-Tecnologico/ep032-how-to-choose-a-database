\set customer random(1, 5000)
\set restaurant random(1, 300)
INSERT INTO orders (customer_id, restaurant_id, total_cents) VALUES (:customer, :restaurant, 2590);
