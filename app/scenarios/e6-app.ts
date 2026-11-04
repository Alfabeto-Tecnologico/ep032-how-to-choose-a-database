// E6 (the app's view) · the same payment, through node-pg, with both replicas down.
// The COMMIT waits; rodar.sh cancels the wait with pg_cancel_backend.
// What does the app receive: an error or a success? And where does the PostgreSQL warning arrive?
import { primary, replicas } from "../db.ts";
import { pay } from "../lib.ts";

const orderId = Number(process.argv[2]);
const now = () => new Date().toISOString().slice(11, 23);

primary.on("connect", (client) => {
  client.on("notice", (n) => {
    console.log(`[app ${now()}] notice: ${n.severity} ${n.code}: ${n.message}`);
    if (n.detail) console.log(`[app ${now()}] notice.detail: ${n.detail}`);
  });
});

console.log(`[app ${now()}] paying order ${orderId} (synchronous_commit = on)`);
try {
  const p = await pay(orderId);
  console.log(`[app ${now()}] pay() returned WITHOUT error: the COMMIT took ${(p.commitMs / 1000).toFixed(2)} s`);
} catch (e) {
  const err = e as Error & { code?: string };
  console.log(`[app ${now()}] pay() returned WITH error: ${err.code} ${err.message}`);
}
await Promise.all([primary.end(), replicas.end()]);
