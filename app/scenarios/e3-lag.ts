// E3 · the lag measured, during the write load.
// Every --interval ms, for --seconds s:
//   on the primary: replay_lag from pg_stat_replication (and the bytes still to replay)
//   on each replica: now() - pg_last_xact_replay_timestamp()
//                    (and clock_timestamp() - ..., because now() is the start of the transaction)
import pg from "pg";
import { primary, replicas } from "../db.ts";
import { stats, fmt, saveResult, sleep, arg } from "../lib.ts";

const SECONDS = Number(arg("seconds", "30"));
const INTERVAL = Number(arg("interval", "250"));

const r1 = new pg.Pool({ connectionString: process.env.PG_REPLICA1, max: 1 });
const r2 = new pg.Pool({ connectionString: process.env.PG_REPLICA2, max: 1 });

const SQL_PRIMARY = `SELECT application_name,
       replay_lag::text AS replay_lag,
       extract(epoch FROM replay_lag) * 1000 AS replay_lag_ms,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS bytes_behind
  FROM pg_stat_replication ORDER BY application_name`;
const SQL_REPLICA = `SELECT (now() - pg_last_xact_replay_timestamp())::text AS lag,
       extract(epoch FROM now() - pg_last_xact_replay_timestamp()) * 1000 AS lag_ms,
       extract(epoch FROM clock_timestamp() - pg_last_xact_replay_timestamp()) * 1000 AS clock_lag_ms`;

const REPLICAS = ["replica1", "replica2"] as const;
type PerReplica<T> = Record<string, T>;
type Sample = {
  t_s: number;
  replay_lag: PerReplica<string | null>;
  replay_lag_ms: PerReplica<number | null>;
  bytes_behind: PerReplica<number>;
  now_minus_replay_ts: PerReplica<string>;
  now_minus_replay_ts_ms: PerReplica<number>;
  clock_minus_replay_ts_ms: PerReplica<number>;
};
const series: Sample[] = [];
const start = performance.now();
console.log("  t(s) | replay_lag replica1 | replay_lag replica2 | now()-replay_ts replica1 | now()-replay_ts replica2");
while (performance.now() - start < SECONDS * 1000) {
  const t = (performance.now() - start) / 1000;
  const [p, a1, a2] = await Promise.all([primary.query(SQL_PRIMARY), r1.query(SQL_REPLICA), r2.query(SQL_REPLICA)]);
  const s: Sample = {
    t_s: Number(t.toFixed(2)), replay_lag: {}, replay_lag_ms: {}, bytes_behind: {},
    now_minus_replay_ts: {}, now_minus_replay_ts_ms: {}, clock_minus_replay_ts_ms: {},
  };
  for (const row of p.rows) {
    s.replay_lag[row.application_name] = row.replay_lag;
    s.replay_lag_ms[row.application_name] = row.replay_lag_ms === null ? null : Number(row.replay_lag_ms);
    s.bytes_behind[row.application_name] = Number(row.bytes_behind);
  }
  REPLICAS.forEach((r, i) => {
    const row = [a1, a2][i].rows[0];
    s.now_minus_replay_ts[r] = row.lag;
    s.now_minus_replay_ts_ms[r] = Number(row.lag_ms);
    s.clock_minus_replay_ts_ms[r] = Number(row.clock_lag_ms);
  });
  series.push(s);
  console.log(
    `${s.t_s.toFixed(2).padStart(6)} | ${String(s.replay_lag.replica1).padEnd(19)} | ${String(s.replay_lag.replica2).padEnd(19)} | ` +
      `${s.now_minus_replay_ts.replica1.padEnd(24)} | ${s.now_minus_replay_ts.replica2}`,
  );
  await sleep(INTERVAL);
}

const summary: Record<string, ReturnType<typeof stats>> = {};
const numbers = (xs: (number | null | undefined)[]) => xs.filter((x): x is number => typeof x === "number");
for (const r of REPLICAS) {
  summary[`replay_lag_${r}_ms`] = stats(numbers(series.map((a) => a.replay_lag_ms[r])));
  summary[`now_minus_replay_ts_${r}_ms`] = stats(series.map((a) => a.now_minus_replay_ts_ms[r]));
  summary[`clock_minus_replay_ts_${r}_ms`] = stats(series.map((a) => a.clock_minus_replay_ts_ms[r]));
  summary[`bytes_behind_${r}`] = stats(numbers(series.map((a) => a.bytes_behind[r])));
}
console.log(`\nsummary of ${series.length} samples (every ${INTERVAL} ms for ${SECONDS} s):`);
for (const [k, s] of Object.entries(summary)) console.log(`  ${k.padEnd(34)} ${fmt(s, k.startsWith("bytes") ? "B" : "ms")}`);
const nulls: Record<string, number> = {};
for (const r of REPLICAS) nulls[r] = series.filter((a) => a.replay_lag_ms[r] === null || a.replay_lag_ms[r] === undefined).length;
console.log(`  samples with replay_lag NULL: replica1=${nulls.replica1}, replica2=${nulls.replica2}`);
const negatives = Object.fromEntries(REPLICAS.map((r) => [r, series.filter((a) => a.now_minus_replay_ts_ms[r] < 0).length]));
console.log(`  samples with negative now() - replay_ts: replica1=${negatives.replica1}, replica2=${negatives.replica2}`);

saveResult("E3", {
  seconds: SECONDS, interval_ms: INTERVAL, samples: series.length,
  summary, replay_lag_null: nulls, now_minus_replay_ts_negative: negatives, series,
});
await Promise.all([primary.end(), replicas.end(), r1.end(), r2.end()]);
