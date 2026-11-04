// E8 · idempotency: the same payment arrives twice (the app repeated the call)
// with the same idempotency_key. The second attempt must fail and not pay again.
import { randomUUID } from "node:crypto";
import { write, primary, replicas } from "../db.ts";
import { createOrder, pay, saveResult } from "../lib.ts";

const orderId = await createOrder();
const key = randomUUID();
console.log(`order ${orderId}, idempotency_key ${key}`);

await pay(orderId, { key });
console.log("1st attempt: COMMIT ok");

let error: Record<string, unknown> | null = null;
try {
  await pay(orderId, { key });
  console.log("2nd attempt: COMMIT ok (it should not be!)");
} catch (e) {
  const err = e as Record<string, unknown>;
  error = {
    code: err.code, message: err.message, detail: err.detail, constraint: err.constraint,
    table: err.table, schema: err.schema, severity: err.severity,
  };
  console.log("2nd attempt: error, the transaction rolled back (ROLLBACK)");
  for (const [k, v] of Object.entries(error)) console.log(`  err.${k} = ${JSON.stringify(v)}`);
}

const { rows: [order] } = await write("SELECT id, status FROM orders WHERE id = $1", [orderId]);
const { rows: [paid] } = await write("SELECT count(*)::int AS n FROM payments WHERE order_id = $1", [orderId]);
console.log(`afterwards: order ${order.id} is '${order.status}', ${paid.n} payment(s) recorded`);

saveResult("E8_app", { order_id: orderId, idempotency_key: key, node_pg_error: error, status_after: order.status, payments_recorded: paid.n });
await Promise.all([primary.end(), replicas.end()]);
