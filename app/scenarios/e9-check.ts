// E9 (2/2) · after promoting replica1: which payments confirmed to the app
// do not exist on the new primary?
import { readFileSync } from "node:fs";
import pg from "pg";
import { saveResult } from "../lib.ts";

const FILE = new URL("../../saidas/E9-confirmados.jsonl", import.meta.url).pathname;
const delay = process.argv[2] ?? "?";
const confirmed = readFileSync(FILE, "utf8").trim().split("\n").filter(Boolean)
  .map((l) => JSON.parse(l) as { order_id: number; key: string; confirmed_at: string });

const next = new pg.Pool({ connectionString: process.env.PG_REPLICA1 });
const { rows: [rec] } = await next.query("SELECT pg_is_in_recovery() AS in_recovery");
const { rows } = await next.query("SELECT idempotency_key::text AS key FROM payments WHERE idempotency_key = ANY($1::uuid[])", [
  confirmed.map((c) => c.key),
]);
const present = new Set(rows.map((r) => r.key));
const vanished = confirmed.filter((c) => !present.has(c.key));
const { rows: [tot] } = await next.query("SELECT count(*)::int AS n, max(id) AS last_id FROM payments");

console.log(`replica1 promoted: pg_is_in_recovery() = ${rec.in_recovery}`);
console.log(`payments confirmed to the app: ${confirmed.length}`);
console.log(`on the new primary (replica1): ${confirmed.length - vanished.length}`);
console.log(`vanished:                      ${vanished.length}`);
if (vanished.length) {
  const first = vanished[0];
  const last = vanished[vanished.length - 1];
  const lastOk = confirmed[confirmed.length - 1];
  console.log(`  the first that vanished: order ${first.order_id}, confirmed at ${first.confirmed_at}`);
  console.log(`  the last that vanished:  order ${last.order_id}, confirmed at ${last.confirmed_at}`);
  console.log(`  lost window: ${(Date.parse(lastOk.confirmed_at) - Date.parse(first.confirmed_at))} ms of confirmed payments`);
  console.log("  examples:");
  for (const s of vanished.slice(-3)) console.log(`    order ${s.order_id}  key ${s.key}  confirmed at ${s.confirmed_at}`);
}
const gap = vanished.length ? confirmed.findIndex((c) => !present.has(c.key)) : -1;
const contiguous = gap < 0 || vanished.every((s, i) => s.key === confirmed[gap + i]?.key);

saveResult("E9", {
  primary_to_replicas_delay: delay,
  confirmed_to_app: confirmed.length,
  present_on_new_primary: confirmed.length - vanished.length,
  vanished: vanished.length,
  vanished_are_the_last_in_sequence: contiguous,
  payments_on_new_primary: tot.n,
  first_vanished: vanished[0] ?? null,
  last_vanished: vanished[vanished.length - 1] ?? null,
});
await next.end();
