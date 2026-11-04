// E2 · the cold-open bug (read-your-writes).
// N times: creates an order and pays it through the transaction (write, on the primary) and right
// after reads the status through the read function (replicas). Counts the stale reads.
//   npx tsx scenarios/e2-stale-read.ts --label idle|load [--n 1000] [--clients 4]
import { write, read, replicas, primary } from "../db.ts";
import { createOrder, pay, stats, fmt, saveResult, trackReplicas, inParallel, arg, READ_STATUS } from "../lib.ts";

const label = arg("label", "idle");
const N = Number(arg("n", "1000"));
const CLIENTS = Number(arg("clients", "4"));

const tracker = await trackReplicas(replicas);
type Row = { id: number; replica: string; status: string | null; commitMs: number; readMs: number; cycleMs: number };
const rows: Row[] = [];

const start = performance.now();
await inParallel(N, CLIENTS, async () => {
  const t0 = performance.now();
  const id = await createOrder();
  const payment = await pay(id);
  const t1 = performance.now();
  const { rows: found } = await read(READ_STATUS, [id]);
  const t2 = performance.now();
  rows.push({
    id,
    replica: tracker.who(id),
    status: found.length ? found[0].status : null,
    commitMs: payment.commitMs,
    readMs: t2 - t1,
    cycleMs: t2 - t0,
  });
});
const durationS = (performance.now() - start) / 1000;

const stale = rows.filter((r) => r.status !== "paid");
const perReplica: Record<string, { reads: number; stale: number }> = {};
for (const r of rows) {
  perReplica[r.replica] ??= { reads: 0, stale: 0 };
  perReplica[r.replica].reads++;
  if (r.status !== "paid") perReplica[r.replica].stale++;
}

// Concrete examples: what the primary says now and what the replica said at the time.
const examples = [];
for (const r of stale.slice(0, 3)) {
  const { rows: now } = await write(READ_STATUS, [r.id]);
  examples.push({
    id: r.id,
    primary_says: now[0]?.status ?? null,
    replica: r.replica,
    replica_said: r.status ?? "(no row)",
    read_ms_after_commit: Number(r.readMs.toFixed(3)),
  });
}

const result = {
  label,
  n: rows.length,
  concurrent_clients: CLIENTS,
  duration_s: Number(durationS.toFixed(1)),
  stale_reads: stale.length,
  stale_awaiting_payment: stale.filter((r) => r.status === "awaiting_payment").length,
  stale_row_missing: stale.filter((r) => r.status === null).length,
  stale_percent: Number(((100 * stale.length) / rows.length).toFixed(1)),
  per_replica: perReplica,
  commit_ms: stats(rows.map((r) => r.commitMs)),
  read_ms: stats(rows.map((r) => r.readMs)),
  examples,
};

console.log(`E2 (${label}) — ${N} payments, ${CLIENTS} concurrent clients, ${result.duration_s} s`);
console.log(`stale reads: ${stale.length} of ${rows.length} (${result.stale_percent}%)`);
console.log(`  status 'awaiting_payment': ${result.stale_awaiting_payment}`);
console.log(`  row missing on the replica:  ${result.stale_row_missing}`);
for (const [r, v] of Object.entries(perReplica)) console.log(`  ${r}: ${v.stale} stale in ${v.reads} reads`);
console.log(`COMMIT on the primary: ${fmt(result.commit_ms)}`);
console.log(`read on the replica:  ${fmt(result.read_ms)}`);
console.log("examples:");
for (const e of examples) {
  console.log(`  order ${e.id}: primary says '${e.primary_says}', ${e.replica} said '${e.replica_said}' (${e.read_ms_after_commit} ms after the COMMIT)`);
}

saveResult(`E2_${label}`, result);
await primary.end();
await replicas.end();
