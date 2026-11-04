// Pieces shared by the scenarios: the payment transaction (read from sql/payment.sql),
// statistics, writing resultados.json and tracking which replica answered.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { lookup } from "node:dns/promises";
import type { Pool, PoolClient } from "pg";
import { write, primary } from "./db.ts";

const LAB = new URL("..", import.meta.url).pathname;

// sql/payment.sql, exactly as it is in the file: BEGIN; INSERT; UPDATE; COMMIT;
const PAYMENT = readFileSync(`${LAB}sql/payment.sql`, "utf8")
  .split(";")
  .map((s) => s.trim())
  .filter(Boolean);
if (PAYMENT.length !== 4 || PAYMENT[0] !== "BEGIN" || PAYMENT[3] !== "COMMIT") {
  throw new Error(`unexpected sql/payment.sql: ${JSON.stringify(PAYMENT)}`);
}
const [BEGIN, INSERT_PAYMENT, UPDATE_ORDER, COMMIT] = PAYMENT;
export const READ_STATUS = "SELECT status FROM orders WHERE id = $1";

export async function createOrder(): Promise<number> {
  const total = 1000 + Math.floor(Math.random() * 9000);
  const { rows } = await write(
    "INSERT INTO orders (customer_id, restaurant_id, total_cents) VALUES ($1, $2, $3) RETURNING id",
    [1 + Math.floor(Math.random() * 5000), 1 + Math.floor(Math.random() * 300), total],
  );
  return Number(rows[0].id);
}

export type Payment = { key: string; commitMs: number; transactionMs: number };

// The payment transaction on a single primary connection. synchronousCommit, when
// given, goes in as SET LOCAL right after the BEGIN (only for this transaction).
export async function pay(
  orderId: number,
  options: { synchronousCommit?: string; key?: string; amount?: number } = {},
): Promise<Payment> {
  const key = options.key ?? randomUUID();
  const amount = options.amount ?? 2590;
  const c = await primary.connect();
  try {
    const t0 = performance.now();
    await c.query(BEGIN);
    if (options.synchronousCommit) await c.query(`SET LOCAL synchronous_commit = ${options.synchronousCommit}`);
    await c.query(INSERT_PAYMENT, [orderId, key, amount]);
    await c.query(UPDATE_ORDER, [orderId]);
    const t1 = performance.now();
    await c.query(COMMIT);
    const t2 = performance.now();
    return { key, commitMs: t2 - t1, transactionMs: t2 - t0 };
  } catch (e) {
    await c.query("ROLLBACK").catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

// ---------- statistics (percentile by nearest rank) ----------
export function stats(values: number[]) {
  const v = [...values].sort((a, b) => a - b);
  const n = v.length;
  const p = (q: number) => (n ? v[Math.min(n - 1, Math.ceil(q * n) - 1)] : NaN);
  const r3 = (x: number) => Math.round(x * 1000) / 1000;
  return {
    n,
    min: r3(v[0]),
    p50: r3(p(0.5)),
    p90: r3(p(0.9)),
    p99: r3(p(0.99)),
    max: r3(v[n - 1]),
    mean: r3(v.reduce((a, b) => a + b, 0) / (n || 1)),
  };
}

export const fmt = (s: ReturnType<typeof stats>, unit = "ms") =>
  `n=${s.n}  p50=${s.p50} ${unit}  p99=${s.p99} ${unit}  max=${s.max} ${unit}  (min=${s.min}, mean=${s.mean})`;

// ---------- resultados.json (each scenario writes its own key) ----------
export function saveResult(key: string, value: unknown) {
  const file = `${LAB}resultados.json`;
  const current = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
  current[key] = { ...(value as object), recorded_at: new Date().toISOString() };
  writeFileSync(file, JSON.stringify(current, null, 2) + "\n");
}

// ---------- primary configuration ----------
export async function configurePrimary(cfg: Record<string, string>) {
  for (const [k, v] of Object.entries(cfg)) {
    await write(`ALTER SYSTEM SET ${k} = '${v}'`);
  }
  await write("SELECT pg_reload_conf()");
  // waits for the reload to take effect on a new connection
  for (let i = 0; i < 100; i++) {
    const c = await primary.connect();
    try {
      let ok = true;
      for (const [k, v] of Object.entries(cfg)) {
        const { rows } = await c.query("SELECT current_setting($1) AS v", [k]);
        if (rows[0].v !== v) ok = false;
      }
      if (ok) return;
    } finally {
      c.release(true); // discards it: the next connection is born with the new configuration
    }
    await sleep(50);
  }
  throw new Error(`configuration did not apply: ${JSON.stringify(cfg)}`);
}

export async function replicationState() {
  const { rows } = await write(
    "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY application_name",
  );
  return rows;
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ---------- which replica answered each read ----------
// For the measurement only (outside db.ts): in the pool's `verify`, which runs once on each
// new connection before it is used, finds out which replica the connection landed on
// (inet_server_addr) and starts recording, per order read, who read it.
type Tracked = PoolClient & { replica?: string };
export async function trackReplicas(pool: Pool) {
  const nameByIp = new Map<string, string>();
  for (const name of ["replica1", "replica2", "primary"]) {
    nameByIp.set((await lookup(name)).address, name);
  }
  const readBy = new Map<string, string>();
  (pool as unknown as { options: { verify: unknown } }).options.verify = (
    client: Tracked,
    ready: (err?: Error) => void,
  ) => {
    client.query("SELECT host(inet_server_addr()) AS ip").then((r) => {
      const name = nameByIp.get(r.rows[0].ip) ?? r.rows[0].ip;
      client.replica = name;
      const original = client.query.bind(client) as (...a: unknown[]) => unknown;
      (client as unknown as { query: unknown }).query = (...args: unknown[]) => {
        if (Array.isArray(args[1])) readBy.set(String(args[1][0]), name);
        return original(...args);
      };
      ready();
    }, ready);
  };
  return {
    who: (orderId: number) => readBy.get(String(orderId)) ?? "?",
    clientName: (c: PoolClient) => (c as Tracked).replica ?? "?",
  };
}

// Runs `total` iterations split among `clients` simultaneous loops.
export async function inParallel(total: number, clients: number, fn: (i: number) => Promise<void>) {
  let next = 0;
  await Promise.all(
    Array.from({ length: clients }, async () => {
      while (next < total) await fn(next++);
    }),
  );
}

export function arg(name: string, fallback: string) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : fallback;
}
