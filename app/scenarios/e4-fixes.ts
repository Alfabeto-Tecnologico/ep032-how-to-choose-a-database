// E4 · read-your-writes fixes, under load. Same loop as E2, changing the fix:
//   --fix none   reads from the replica right after the COMMIT (control, same as E2)
//   --fix a      reads from the primary right after writing
//   --fix b      takes pg_current_wal_lsn() on the primary after the COMMIT and waits for the
//                replica to have pg_last_wal_replay_lsn() >= lsn before reading (same connection)
//   --fix c      synchronous_standby_names = --sync and SET LOCAL synchronous_commit =
//                remote_apply only in the payment transaction; reads through read (replicas)
// To read from a single replica, rodar.sh changes PG_REPLICAS (db.ts is the same).
import { write, read, primary, replicas } from "../db.ts";
import {
  createOrder, pay, stats, fmt, saveResult, trackReplicas, inParallel, arg,
  configurePrimary, replicationState, READ_STATUS,
} from "../lib.ts";

const fix = arg("fix", "none");
const label = arg("label", fix);
const N = Number(arg("n", "1000"));
const CLIENTS = Number(arg("clients", "4"));
const SYNC = arg("sync", "");

const tracker = await trackReplicas(replicas);

if (fix === "c") {
  // Only the payment waits for the replicas: the server default stays 'local' (pgbench and the
  // order creation do not wait) and the payment asks for remote_apply with SET LOCAL.
  await configurePrimary({ synchronous_standby_names: SYNC, synchronous_commit: "local" });
}
const state = await replicationState();
const config = (await write("SELECT current_setting('synchronous_standby_names') AS ssn, current_setting('synchronous_commit') AS sc")).rows[0];

type Row = { id: number; reader: string; status: string | null; commitMs: number; transactionMs: number; waitMs: number; waitQueries: number; readMs: number; payAndReadMs: number };
const rows: Row[] = [];

await inParallel(N, CLIENTS, async () => {
  const id = await createOrder();
  const t0 = performance.now();
  const payment = await pay(id, fix === "c" ? { synchronousCommit: "remote_apply" } : {});
  const t1 = performance.now();
  let found: { status: string }[];
  let reader = "?";
  let waitMs = 0;
  let waitQueries = 0;
  let tRead = t1;

  if (fix === "a") {
    ({ rows: found } = await write(READ_STATUS, [id]));
    reader = "primary";
  } else if (fix === "b") {
    const { rows: [{ lsn }] } = await write("SELECT pg_current_wal_lsn() AS lsn");
    const c = await replicas.connect();
    try {
      reader = tracker.clientName(c);
      for (;;) {
        waitQueries++;
        const r = await c.query("SELECT pg_last_wal_replay_lsn() >= $1::pg_lsn AS ok", [lsn]);
        if (r.rows[0].ok) break;
        if (performance.now() - t1 > 10_000) throw new Error(`replica did not reach ${lsn} within 10 s`);
      }
      tRead = performance.now();
      waitMs = tRead - t1;
      ({ rows: found } = await c.query(READ_STATUS, [id]));
    } finally {
      c.release();
    }
  } else {
    ({ rows: found } = await read(READ_STATUS, [id]));
    reader = tracker.who(id);
  }
  const t2 = performance.now();
  rows.push({
    id, reader, status: found.length ? found[0].status : null,
    commitMs: payment.commitMs, transactionMs: payment.transactionMs, waitMs, waitQueries,
    readMs: t2 - tRead, payAndReadMs: t2 - t0,
  });
});

const stale = rows.filter((r) => r.status !== "paid");
const perReader: Record<string, { reads: number; stale: number }> = {};
for (const r of rows) {
  perReader[r.reader] ??= { reads: 0, stale: 0 };
  perReader[r.reader].reads++;
  if (r.status !== "paid") perReader[r.reader].stale++;
}
const examples = [];
for (const r of stale.slice(0, 3)) {
  const { rows: now } = await write(READ_STATUS, [r.id]);
  examples.push({ id: r.id, primary_says: now[0]?.status ?? null, reader: r.reader, reader_said: r.status ?? "(no row)" });
}

const result = {
  fix, label, n: rows.length, concurrent_clients: CLIENTS,
  synchronous_standby_names: config.ssn, default_synchronous_commit: config.sc,
  payment_synchronous_commit: fix === "c" ? "remote_apply" : config.sc,
  pg_stat_replication: state,
  stale_reads: stale.length,
  stale_awaiting_payment: stale.filter((r) => r.status === "awaiting_payment").length,
  stale_row_missing: stale.filter((r) => r.status === null).length,
  stale_percent: Number(((100 * stale.length) / rows.length).toFixed(1)),
  per_reader: perReader,
  commit_ms: stats(rows.map((r) => r.commitMs)),
  payment_transaction_ms: stats(rows.map((r) => r.transactionMs)),
  lsn_wait_ms: fix === "b" ? stats(rows.map((r) => r.waitMs)) : undefined,
  wait_queries: fix === "b" ? stats(rows.map((r) => r.waitQueries)) : undefined,
  read_ms: stats(rows.map((r) => r.readMs)),
  pay_and_read_ms: stats(rows.map((r) => r.payAndReadMs)),
  examples,
};

console.log(`E4 fix ${fix} (${label}) — ${rows.length} payments, ${CLIENTS} concurrent clients`);
console.log(`synchronous_standby_names = '${config.ssn}', default synchronous_commit = ${config.sc}, on the payment = ${result.payment_synchronous_commit}`);
console.log(`pg_stat_replication: ${state.map((e) => `${e.application_name}=${e.state}/${e.sync_state}`).join(", ")}`);
console.log(`stale reads: ${stale.length} of ${rows.length} (${result.stale_percent}%)` +
  ` [awaiting_payment: ${result.stale_awaiting_payment}, row missing: ${result.stale_row_missing}]`);
for (const [r, v] of Object.entries(perReader)) console.log(`  ${r}: ${v.stale} stale in ${v.reads} reads`);
console.log(`payment COMMIT:           ${fmt(result.commit_ms)}`);
if (fix === "b") {
  console.log(`wait for the LSN:         ${fmt(result.lsn_wait_ms!)}`);
  console.log(`wait queries:             ${fmt(result.wait_queries!, "queries")}`);
}
console.log(`read:                     ${fmt(result.read_ms)}`);
console.log(`pay + read (total):       ${fmt(result.pay_and_read_ms)}`);
for (const e of examples) console.log(`  example: order ${e.id}: primary says '${e.primary_says}', ${e.reader} said '${e.reader_said}'`);

saveResult(`E4_${label}`, result);
if (fix === "c") {
  await write("ALTER SYSTEM RESET synchronous_standby_names");
  await write("ALTER SYSTEM RESET synchronous_commit");
  await write("SELECT pg_reload_conf()");
}
await Promise.all([primary.end(), replicas.end()]);
