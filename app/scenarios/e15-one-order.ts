// E15 · the opening screen of the video: pays an order and, at the same instant, reads the status on the
// primary and on the replica. Repeats until the replica answers "awaiting_payment" and shows
// all the attempts, including the ones where the replica already had the data.
import { write, read, replicas, primary } from "../db.ts";
import { createOrder, pay, saveResult, trackReplicas, READ_STATUS } from "../lib.ts";

const tracker = await trackReplicas(replicas);
// The connections are already open, like in a running app.
await Promise.all([write("SELECT 1"), read("SELECT 1")]);

const attempts = [];
for (let i = 0; i < 20; i++) {
  const id = await createOrder();
  const { commitMs } = await pay(id);
  const t0 = performance.now();
  const [onPrimary, onReplica] = await Promise.all([
    write(READ_STATUS, [id]),
    read(READ_STATUS, [id]).then((r) => ({ rows: r.rows, ms: performance.now() - t0 })),
  ]);
  const t = {
    order: id,
    commit_ms: Number(commitMs.toFixed(3)),
    primary: onPrimary.rows[0]?.status ?? null,
    replica: tracker.who(id),
    replica_said: onReplica.rows[0]?.status ?? null,
    read_ms_after_commit: Number(onReplica.ms.toFixed(3)),
  };
  attempts.push(t);
  console.log(`order ${t.order}: COMMIT ok in ${t.commit_ms} ms`);
  console.log(`  primary: status = ${t.primary}`);
  console.log(`  ${t.replica}: status = ${t.replica_said ?? "(no row)"}   (${t.read_ms_after_commit} ms after the COMMIT)`);
  if (t.replica_said === "awaiting_payment") break;
}

saveResult("E15", { attempts });
await primary.end();
await replicas.end();
