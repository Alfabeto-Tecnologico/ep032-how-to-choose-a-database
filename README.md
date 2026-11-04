# Database lab: the delivery app

The lab behind the Alfabeto Tecnológico tutorial on how to choose a database (Fundamentals of Architecture #1, technical version). Every terminal output in the video comes from running this code. The video is in Brazilian Portuguese with on-screen text in English. The PDF guide and every link from the video are in the episode's community post, linked in the video description.

The system is a food delivery back end:

- **PostgreSQL 18** (`primary`) stores orders and payments and streams every change to **two replicas** (`replica1`, `replica2`).
- Reads can go to the replicas through **one address**, `replicas`, an HAProxy that spreads connections between them.
- A **3-node ScyllaDB** cluster (`scylla1..3`, replication factor 3) stores courier positions.
- The **app** (Node + TypeScript, `pg`) runs in its own container, next to the databases.

On top of it, the lab breaks things on purpose, one at a time: two customers paying the same order at once, a replica answering stale data right after a payment, the primary dying and taking confirmed payments with it, a network partition between the primary and a replica, and a ScyllaDB node going down.

## Requirements

- Docker with Compose (tested on Docker Desktop 29.9.2, Apple Silicon).
- `python3` on the host. You don't need Node, `psql` or `cqlsh` on the host: everything runs in the containers.
- To record the runs: `asciinema` 3.2.1.

## Running

The runner, `rodar.sh`, keeps the Portuguese names it had when the video was made. Everything it prints on screen is in English, and every `$` line it prints is the exact command it runs (paste it and it runs the same).

```bash
./rodar.sh E2          # one scenario: starts PostgreSQL from scratch and writes saidas/E2.txt
./rodar.sh postgres    # E15 E1 E2 E3 E4 E5 E13 E14 E6 E7 E8 E9, each on a fresh cluster
./rodar.sh scylla      # E10 E11 E12, on a fresh ScyllaDB cluster
./rodar.sh todos       # both ("todos" = all)
./rodar.sh gravar E6   # the same scenario, recorded with asciinema ("gravar" = record)
./rodar.sh derrubar    # docker compose down -v ("derrubar" = tear down)
```

| Name | Meaning |
|---|---|
| `saidas/` | outputs: the exact terminal output of each scenario |
| `gravacoes/` | recordings: one asciinema `.cast` per scenario, plus `<ID>.linhas.json` with the time of each line |
| `resultados.json` | the numbers of each scenario, written by `ferramentas/registrar.py` |
| `ferramentas/` | tools: `registrar.py` (numbers into `resultados.json`) and `cast_linhas.py` (the line timings of a recording) |

`CARGA_CLIENTES=8` (the default) sets the number of pgbench clients in the background load.

**Run `./rodar.sh derrubar` before a measured run.** `postgres` starts only PostgreSQL and doesn't stop a ScyllaDB cluster left running by an earlier run, and three idle ScyllaDB nodes take CPU from the Docker VM.

To poke around by hand: `primary` listens on `127.0.0.1:54180`, the replicas on `54181` and `54182` (user and password `postgres`, database `delivery`), and ScyllaDB on `127.0.0.1:59042`. Use the `cqlsh` inside the container: `docker compose exec scylla1 cqlsh`.

## The scenarios

| ID | What it shows |
|---|---|
| E15 | The app pays an order and immediately reads its status on the primary and on a replica, until the replica answers stale. |
| E1 | Asynchronous streaming replication: `pg_stat_replication` with both replicas `async`. |
| E2 | The stale-read count: a read on a replica right after the COMMIT on the primary, 1,000 payments per round, idle and under load. |
| E3 | Replication lag measured for 30 s, every 250 ms, under load, with `replay_lag` and `now() - pg_last_xact_replay_timestamp()`. |
| E4 | Three fixes for read-your-writes: (a) read from the primary, (b) wait on the replica for the commit's LSN, (c) `remote_apply` with `ANY 1`, `FIRST 1` and `ANY 2`. |
| E5 | The price of synchronous replication: COMMIT latency for each `synchronous_commit` level, with no delay and with 10 ms of network delay each way. |
| E13 | Throughput with pgbench (create the order and pay), asynchronous versus synchronous, in three alternating rounds. |
| E14 | Two sessions paying the same order at the same time: the row lock makes the second one wait and update nothing. |
| E6 | CAP in practice with `synchronous_commit = on`: one replica down, then both, the COMMIT waiting, and how the app sees that wait. |
| E7 | A network partition between the primary and `replica2`: the replica stops, keeps answering reads, and the primary still lists it. |
| E8 | Idempotency: the second attempt with the same key fails on the unique constraint, and only one payment stays. |
| E9 | Asynchronous failover loses data: 1 s of replication delay, a writer at 115 payments per second, `docker kill` on the primary, `pg_promote()` on `replica1`, and the confirmed payments that are gone. |
| E10 | ScyllaDB: the query by partition key, and the one without it. |
| E11 | One ScyllaDB node down: `QUORUM` reads and writes, `ALL` fails. |
| E12 | The ONE/ONE puzzle with replication factor 3 and hinted handoff off: write with `ONE` while a node is down, then read with `ONE` from that node. |

## How it's built

- **Replication:** physical streaming, asynchronous by default. Each replica clones `primary` with `pg_basebackup` and connects with `application_name` set to its service name, each one with its own replication slot.
- **Two networks:** `app_net`, where the app talks to the databases, and `replication_net`, which carries only replication (`primary` answers there as `primary-repl`). The simulated delay between the primary and the replicas doesn't slow the app down.
- **The app runs in a container** on `app_net` (`npx tsx`), not on the host: Docker Desktop's port forwarding would add a variable hop between the app and the database.
- **`replicas`** is HAProxy with `balance roundrobin`. It spreads **connections**, not queries: the `pg` pool reuses the last free connection, so a sequential loop would stick to one replica. The app scenarios run 4 concurrent clients, which opens two connections on each replica, and each output says how many reads hit each replica.
- **The payment transaction** is read from `sql/payment.sql` and runs on a single `primary` connection (`primary.connect()`), because `BEGIN ... COMMIT` can't go through `pool.query`.
- **Background load:** pgbench TPC-B with 8 clients on `primary`, on the `pgbench_*` tables, alongside the test.
- **Network failures:** `postgres/net.sh` uses `tc netem` (`net.sh delay 10ms`, `clear`, `show`); the partition is `docker network disconnect` on `replication_net`.
- **Throughput (E13):** checkpoints are kept out of the measured window. During the run, `max_wal_size` goes to 16 GB and `checkpoint_timeout` to 30 min, and a `CHECKPOINT` runs on the primary and the replicas before each execution. A checkpoint in the middle of an execution drops throughput because of full-page writes.
- **ScyllaDB settings:** `--max-networking-io-control-blocks 1000`, so three nodes start under the Docker VM's default `fs.aio-max-nr`; `stop_grace_period: 120s`, so a stopped node flushes its memtables; `system_traces` with replication factor 3, so traces can be read with a node down.

## Versions

PostgreSQL 18.6 (`postgres:18.6` plus `iproute2` and `procps`), ScyllaDB 2026.3.4, Node 22.23.4, `pg` 8.23.1, `tsx` 4.23.15, HAProxy 3.2.25.

## About the numbers

Running again changes the exact numbers. The ones in the video are from the recorded run of November 3, 2026, on an Apple M3 Max with Docker Desktop: the Docker VM had 10 CPUs and 32 GB, with only the lab's 5 containers running, and nothing heavy running on the Mac. The containers have no CPU or memory limits, so anything else running on the same machine changes the results. What should reproduce is the behavior: the stale reads, the lost payments, the waits and the errors.

## License

MIT, see [LICENSE](LICENSE).
