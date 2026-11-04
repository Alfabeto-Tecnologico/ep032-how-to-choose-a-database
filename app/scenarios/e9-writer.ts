// E9 (1/2) · pays orders on the primary (asynchronous replication) at the pace of the peak in the brief
// and notes every payment whose COMMIT came back ok. Ends when the primary dies.
// With no pace limit, replication cannot keep up with the delayed network and what is lost stops
// being the network delay: in one run, 8,373 of 10,296 payments, in 4.7 s, with a 1 s delay.
import { appendFileSync, writeFileSync } from "node:fs";
import { primary, replicas } from "../db.ts";
import { arg, createOrder, sleep, pay } from "../lib.ts";

const PER_SECOND = Number(arg("per-second", "115"));
const now = () => new Date().toISOString().slice(11, 23);

const FILE = new URL("../../saidas/E9-confirmados.jsonl", import.meta.url).pathname;
writeFileSync(FILE, "");
let confirmed = 0;
primary.on("error", () => {}); // an idle connection dropping when the primary dies
const start = performance.now();
try {
  for (;;) {
    const id = await createOrder();
    const { key } = await pay(id);
    appendFileSync(FILE, JSON.stringify({ order_id: id, key, confirmed_at: new Date().toISOString() }) + "\n");
    confirmed++;
    if (confirmed % PER_SECOND === 0) console.log(`[${now()}] payments confirmed to the app: ${confirmed}`);
    const slack = start + (confirmed * 1000) / PER_SECOND - performance.now();
    if (slack > 0) await sleep(slack);
  }
} catch (e) {
  const err = e as Error & { code?: string };
  console.log(`[${now()}] writer stopped: ${err.code ?? ""} ${err.message}`);
}
console.log(`payments confirmed to the app (COMMIT ok): ${confirmed}`);
await Promise.allSettled([primary.end(), replicas.end()]);
