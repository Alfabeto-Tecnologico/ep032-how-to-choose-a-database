// E5 · the price of synchronous (PACELC). With synchronous_standby_names = 'ANY 1 (replica1, replica2)',
// measures the COMMIT latency of the payment transaction under each synchronous_commit.
// The modes alternate on every iteration (off, local, remote_write, on, remote_apply, off, ...)
// so that any variation of the machine falls equally on all of them. One client, no load.
//   npx tsx scenarios/e5-sync-price.ts --label no_delay|delay_10ms [--n 500]
import { write, primary, replicas } from "../db.ts";
import { createOrder, pay, stats, fmt, saveResult, arg, configurePrimary, replicationState } from "../lib.ts";

const label = arg("label", "no_delay");
const N = Number(arg("n", "500"));
const WARMUP = Number(arg("warmup", "20"));
const MODES = ["off", "local", "remote_write", "on", "remote_apply"] as const;

await configurePrimary({ synchronous_standby_names: "ANY 1 (replica1, replica2)", synchronous_commit: "local" });
const state = await replicationState();

const commit: Record<string, number[]> = Object.fromEntries(MODES.map((m) => [m, []]));
const transaction: Record<string, number[]> = Object.fromEntries(MODES.map((m) => [m, []]));
for (let i = 0; i < WARMUP + N; i++) {
  for (const mode of MODES) {
    const id = await createOrder();
    const p = await pay(id, { synchronousCommit: mode });
    if (i >= WARMUP) {
      commit[mode].push(p.commitMs);
      transaction[mode].push(p.transactionMs);
    }
  }
}

const result: Record<string, unknown> = {
  label, n_per_mode: N, warmup_discarded: WARMUP,
  synchronous_standby_names: "ANY 1 (replica1, replica2)",
  pg_stat_replication: state,
  commit_ms: {} as Record<string, ReturnType<typeof stats>>,
  transaction_ms: {} as Record<string, ReturnType<typeof stats>>,
};
console.log(`E5 (${label}) — synchronous_standby_names = 'ANY 1 (replica1, replica2)', ${N} payments per mode`);
console.log(`pg_stat_replication: ${state.map((e) => `${e.application_name}=${e.state}/${e.sync_state}`).join(", ")}`);
console.log("COMMIT latency of the payment transaction:");
for (const mode of MODES) {
  const s = stats(commit[mode]);
  (result.commit_ms as Record<string, unknown>)[mode] = s;
  (result.transaction_ms as Record<string, unknown>)[mode] = stats(transaction[mode]);
  console.log(`  ${mode.padEnd(13)} ${fmt(s)}`);
}
console.log("whole transaction (BEGIN to the end of the COMMIT):");
for (const mode of MODES) console.log(`  ${mode.padEnd(13)} ${fmt((result.transaction_ms as Record<string, ReturnType<typeof stats>>)[mode])}`);

saveResult(`E5_${label}`, result);
await write("ALTER SYSTEM RESET synchronous_standby_names");
await write("ALTER SYSTEM RESET synchronous_commit");
await write("SELECT pg_reload_conf()");
await Promise.all([primary.end(), replicas.end()]);
