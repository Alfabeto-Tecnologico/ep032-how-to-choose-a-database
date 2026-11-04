#!/usr/bin/env bash
# Laboratório do tutorial: reproduz cada cenário do zero e grava a saída exata em
# saidas/<ID>.txt (os números também vão para resultados.json).
#
#   ./rodar.sh E1 | E2 | ... | E15   um cenário (sobe o banco do zero antes)
#   ./rodar.sh postgres               E15 E1 E2 E3 E4 E5 E13 E14 E6 E7 E8 E9
#   ./rodar.sh scylla                 E10 E11 E12 (um cluster só para os três)
#   ./rodar.sh todos                  postgres e depois scylla
#   ./rodar.sh gravar <o mesmo>       idem, gravando em gravacoes/ com o asciinema
#   ./rodar.sh derrubar               docker compose down -v
#
# Variável: CARGA_CLIENTES (padrão 8) = clientes do pgbench na carga de fundo.
#
# Tudo o que sai na tela dos cenários (saídas, comandos, comentários, nomes) é em inglês, porque a saída
# vai para o vídeo como foi gravada. Os comentários deste arquivo e os nomes das funções ficam em português.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
SAIDAS="$LAB/saidas"
export COMPOSE_FILE="$LAB/docker-compose.yml"
CARGA_CLIENTES="${CARGA_CLIENTES:-8}"
PROJETO="delivery-lab"
mkdir -p "$SAIDAS"
cd "$LAB"  # os caminhos que a tela mostra (sql/…, scylla/…) são relativos à pasta do laboratório

dc() { docker compose "$@"; }
log() { printf '>> %s\n' "$*" >&2; }
mostra() { printf '\n$ %s\n' "$*"; }
# cita: os argumentos como o shell precisa deles (entre aspas simples quando têm espaço ou caractere especial), para a
# linha "$" rodar igual se for colada no terminal (03/11/2026: o E4 mostrava --sync ANY 1 (replica1, replica2) sem aspas)
cita() {
  local a q out=() ok='^[A-Za-z0-9_./:=@%+,-]+$'
  for a in "$@"; do
    if [[ $a =~ $ok ]]; then out+=("$a"); else q=${a//\'/\'\\\'\'}; out+=("'$q'"); fi
  done
  printf '%s' "${out[*]}"
}
roda() { local c; c=$(cita "$@"); mostra "${c/#dc /docker compose }"; "$@"; }
# executa '<comando>': a linha "$" é exatamente o que roda, com aspas, pipes e laços (03/11/2026: nenhuma linha "$"
# pode ser legenda; o que não é comando vai num comentário "#")
executa() { mostra "$1"; eval "$1"; }
hora() { date '+%H:%M:%S'; }
titulo() { printf '\n==== %s ====\n' "$*"; }

# psql com eco das consultas (-e), sem psqlrc. O stderr (ERROR, WARNING) é juntado ao
# stdout dentro do container, para a saída sair na ordem em que aconteceu.
PSQL=(sh -c 'exec psql -X -e -U postgres -d delivery "$@" 2>&1' psql)
sql() {
  local svc=$1; shift
  printf '\n-- psql on %s\n' "$svc"
  dc exec -T "$svc" "${PSQL[@]}" "$@"
}
valor() { local svc=$1; shift; dc exec -T "$svc" psql -X -q -tA -U postgres -d delivery -c "$1"; }
app() { mostra "docker compose exec -T app npx tsx $(cita "$@")   # $(hora)"; dc exec -T app npx tsx "$@"; }
app_com() { local env=$1; shift; mostra "docker compose exec -T -e $(cita "$env") app npx tsx $(cita "$@")   # $(hora)"; dc exec -T -e "$env" app npx tsx "$@"; }
registrar() { python3 "$LAB/ferramentas/registrar.py" "$@"; }

# ---------------------------------------------------------------- PostgreSQL
subir_pg() {
  log "starting PostgreSQL from scratch (primary, 2 replicas, balancer, app)"
  dc rm -sfv primary replica1 replica2 replicas >/dev/null 2>&1 || true
  docker volume rm -f ${PROJETO}_pg_primary ${PROJETO}_pg_replica1 ${PROJETO}_pg_replica2 >/dev/null
  dc build -q primary >/dev/null 2>&1  # a imagem leva o net.sh e os scripts de réplica
  dc up -d --wait primary replica1 replica2 replicas app >/dev/null 2>&1
  dc exec -T app sh -c 'test -d node_modules/pg || npm ci --no-audit --no-fund' >/dev/null
  dc exec -T primary psql -X -q -v ON_ERROR_STOP=1 -U postgres -d delivery -f /lab-sql/schema.sql
  dc exec -T primary pgbench -U postgres -i -s 10 -q delivery >/dev/null 2>&1
  esperar_replicas_em_dia
}

esperar_replicas_em_dia() {
  for _ in $(seq 1 120); do
    local ok
    ok=$(valor primary "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming' AND replay_lsn = pg_current_wal_lsn()")
    [ "$ok" = "2" ] && return 0
    sleep 0.5
  done
  log "the replicas did not catch up"; return 1
}

esperar_saudavel() {
  for svc in "$@"; do
    for _ in $(seq 1 120); do
      [ "$(docker inspect -f '{{.State.Health.Status}}' "${PROJETO}-${svc}-1" 2>/dev/null)" = healthy ] && break
      sleep 1
    done
  done
}

CARGA_PID=""
LOAD_LOG=""
carga_inicia() {  # pgbench TPC-B no primário, em segundo plano (o nome da variável aparece na tela: em inglês)
  LOAD_LOG=$(mktemp)
  executa "docker compose exec -T primary pgbench -U postgres -c $CARGA_CLIENTES -j 4 -T 3600 -P 5 delivery > \"\$LOAD_LOG\" 2>&1 &   # background write load (TPC-B, pgbench_* tables)"
  CARGA_PID=$!
  printf '# %s\n' "$(hora)"
  sleep 6
}
carga_para() {
  dc exec -T primary pkill -INT -x pgbench >/dev/null 2>&1 || true
  wait "$CARGA_PID" 2>/dev/null || true
  printf '\n-- %s: background pgbench log (progress every 5 s):\n' "$(hora)"
  cat "$LOAD_LOG"
  rm -f "$LOAD_LOG"
}

cenario_E1() {
  titulo "E1 · versions and topology (asynchronous replication, the default)"
  sql primary <<'SQL'
SELECT version();
SHOW synchronous_standby_names;
SHOW synchronous_commit;
SELECT application_name, state, sync_state, write_lag, flush_lag, replay_lag FROM pg_stat_replication;
SQL
  titulo "E1 · the same query with writes happening"
  carga_inicia
  sql primary <<'SQL'
SELECT application_name, state, sync_state, write_lag, flush_lag, replay_lag FROM pg_stat_replication;
SQL
  carga_para
}

cenario_E15() {
  titulo "E15 · the opening screen: one payment, the primary and the replica at the same instant"
  app scenarios/e15-one-order.ts
}

cenario_E2() {  # três rodadas de 1.000 em cada condição, para ver a variação
  titulo "E2 · read-your-writes with the database idle (only the test running)"
  for r in 1 2 3; do app scenarios/e2-stale-read.ts --label "idle_$r" --n 1000; done
  titulo "E2 · read-your-writes with a write load running in parallel"
  carga_inicia
  for r in 1 2 3; do app scenarios/e2-stale-read.ts --label "load_$r" --n 1000; done
  carga_para
}

cenario_E3() {
  titulo "E3 · the lag measured during the load"
  carga_inicia
  executa "docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' delivery-lab-primary-1 delivery-lab-replica1-1 delivery-lab-replica2-1 delivery-lab-app-1   # the lab's CPU and memory during the load"
  app scenarios/e3-lag.ts --seconds 30 --interval 250
  carga_para
}

cenario_E4() {
  titulo "E4 · read-your-writes fixes, under load"
  carga_inicia
  app scenarios/e4-fixes.ts --fix none --label no_fix
  app scenarios/e4-fixes.ts --fix a --label a_read_from_primary
  app scenarios/e4-fixes.ts --fix b --label b_wait_for_lsn
  app scenarios/e4-fixes.ts --fix c --sync 'ANY 1 (replica1, replica2)' --label c_any1_any_replica
  app_com PG_REPLICAS=postgres://postgres:postgres@replica1:5432/delivery \
    scenarios/e4-fixes.ts --fix c --sync 'FIRST 1 (replica1)' --label c_first1_reading_replica1
  app scenarios/e4-fixes.ts --fix c --sync 'ANY 2 (replica1, replica2)' --label c_any2_any_replica
  app_com PG_REPLICAS=postgres://postgres:postgres@replica2:5432/delivery \
    scenarios/e4-fixes.ts --fix c --sync 'FIRST 1 (replica1)' --label c_first1_reading_replica2
  carga_para
}

ida_e_volta() {  # tempo de um SELECT 1 da replica1 até o primário, pela rede de replicação
  executa "docker compose exec -T -e PGPASSWORD=postgres replica1 psql -X -h primary-repl -U postgres -d delivery -c '\\timing on' -c 'SELECT 1' -c 'SELECT 1' -c 'SELECT 1' | grep -E '^Time'   # from replica1, over the replication network"
}

cenario_E5() {
  titulo "E5 · the price of synchronous, with no network delay"
  for s in primary replica1 replica2; do dc exec -T "$s" net.sh show; done
  ida_e_volta
  app scenarios/e5-sync-price.ts --label no_delay --n 500
  titulo "E5 · the price of synchronous, with 10 ms each way between primary and replicas"
  for s in primary replica1 replica2; do roda dc exec -T "$s" net.sh delay 10ms; done
  ida_e_volta
  app scenarios/e5-sync-price.ts --label delay_10ms --n 500
  for s in primary replica1 replica2; do dc exec -T "$s" net.sh clear >/dev/null; done
}

cenario_E13() {
  titulo "E13 · machine and limits"
  mostra "sysctl hw.model machdep.cpu.brand_string hw.ncpu hw.memsize   # the Mac"
  sysctl hw.model machdep.cpu.brand_string hw.ncpu hw.memsize
  executa "docker info --format 'Docker {{.ServerVersion}} {{.OSType}}/{{.Architecture}}, {{.NCPU}} CPUs, {{.MemTotal}} bytes of memory, {{.Containers}} containers in total ({{.ContainersRunning}} running)'   # the Docker Desktop VM"
  executa "for s in primary replica1 replica2; do docker inspect -f '{{.Name}} NanoCpus={{.HostConfig.NanoCpus}} CpuQuota={{.HostConfig.CpuQuota}} Memory={{.HostConfig.Memory}}' delivery-lab-\$s-1; done   # container limits (0 = no limit)"
  executa "cat sql/pgbench-payment.sql"

  # Checkpoints fora da janela medida (02/11/2026). Na 1ª e na 2ª tomada de 02/11, um checkpoint disparado pelo
  # volume de WAL (max_wal_size = 1GB, o padrão) caiu no meio das execuções, e as full-page writes que vêm logo
  # depois dele derrubaram a vazão (os logs mostram o "checkpoint starting: wal" na hora das quedas). É a prática
  # padrão de benchmark com pgbench: limite de WAL alto e intervalo longo durante as medições, e um CHECKPOINT
  # forçado no primário e nas réplicas antes de cada execução. Só no E13; no fim ele volta ao padrão.
  local e13_start  # aparece na tela, no docker logs do fim: em inglês
  e13_start=$(date -u +%Y-%m-%dT%H:%M:%S)
  titulo "E13 · checkpoints outside the measured window"
  for s in primary replica1 replica2; do
    sql "$s" <<'SQL'
ALTER SYSTEM SET max_wal_size = '16GB';
ALTER SYSTEM SET checkpoint_timeout = '30min';
SELECT pg_reload_conf();
SQL
  done

  # Três rodadas de 30 s em cada modo, alternadas, porque a vazão varia de uma rodada
  # para outra (a VM do Docker é dividida com outros containers da máquina).
  for r in 1 2 3; do
    titulo "E13 · round $r · payment throughput, asynchronous replication"
    sql primary <<'SQL'
ALTER SYSTEM RESET synchronous_standby_names;
ALTER SYSTEM RESET synchronous_commit;
SELECT pg_reload_conf();
SQL
    sleep 1
    sql primary -c "SHOW synchronous_standby_names" -c "SHOW synchronous_commit" \
      -c "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1"
    checkpoints_antes
    roda dc exec -T primary pgbench -U postgres -n -c 16 -j 4 -T 30 -P 5 -f /lab-sql/pgbench-payment.sql delivery

    titulo "E13 · round $r · payment throughput, ANY 1 (replica1, replica2) + synchronous_commit = on"
    sql primary <<'SQL'
ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 (replica1, replica2)';
ALTER SYSTEM SET synchronous_commit = 'on';
SELECT pg_reload_conf();
SQL
    sleep 1
    sql primary -c "SHOW synchronous_standby_names" -c "SHOW synchronous_commit" \
      -c "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1"
    checkpoints_antes
    roda dc exec -T primary pgbench -U postgres -n -c 16 -j 4 -T 30 -P 5 -f /lab-sql/pgbench-payment.sql delivery
  done
  sql primary <<'SQL'
ALTER SYSTEM RESET synchronous_standby_names;
ALTER SYSTEM RESET synchronous_commit;
SELECT pg_reload_conf();
SQL
  # a prova: os checkpoints e restartpoints do E13 (os forçados, "immediate force wait", entre as execuções;
  # nenhum "wal" ou "time" pode cair dentro de uma execução)
  executa "for s in primary replica1 replica2; do docker logs --since \"\$e13_start\" delivery-lab-\$s-1 2>&1 | grep -E '(checkpoint|restartpoint) starting' | sed \"s/^/\$s: /\"; done   # checkpoints and restartpoints during E13"
  for s in primary replica1 replica2; do
    sql "$s" <<'SQL'
ALTER SYSTEM RESET max_wal_size;
ALTER SYSTEM RESET checkpoint_timeout;
SELECT pg_reload_conf();
SQL
  done
}

checkpoints_antes() {  # E13: um CHECKPOINT forçado no primário e nas réplicas, logo antes de cada execução medida
  for s in primary replica1 replica2; do sql "$s" -c "CHECKPOINT"; done
}

# Sessão A: paga e segura a transação aberta (pg_sleep) depois do UPDATE.
sessao_E14_A() {
  dc exec -T -e PGAPPNAME=session_A primary "${PSQL[@]}" -v order_id="$1" <<'SQL'
\timing on
\echo [A] `date +%H:%M:%S.%3N` starts
BEGIN;
INSERT INTO payments (order_id, idempotency_key, amount_cents) VALUES (:order_id, 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', 2590);
UPDATE orders SET status = 'paid' WHERE id = :order_id AND status = 'awaiting_payment';
\echo [A] `date +%H:%M:%S.%3N` UPDATE done; holding the transaction open for 5 s
SELECT pg_sleep(5);
\echo [A] `date +%H:%M:%S.%3N` COMMIT
COMMIT;
\echo [A] `date +%H:%M:%S.%3N` done
SQL
}

# Sessão B: o mesmo pedido, outra chave. Se o UPDATE não pegar nada, o código desfaz.
sessao_E14_B() {
  dc exec -T -e PGAPPNAME=session_B primary "${PSQL[@]}" -v order_id="$1" <<'SQL'
\timing on
\echo [B] `date +%H:%M:%S.%3N` starts
BEGIN;
INSERT INTO payments (order_id, idempotency_key, amount_cents) VALUES (:order_id, 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb', 2590);
\echo [B] `date +%H:%M:%S.%3N` UPDATE on the same order
UPDATE orders SET status = 'paid' WHERE id = :order_id AND status = 'awaiting_payment';
\echo [B] `date +%H:%M:%S.%3N` the UPDATE returned; rows updated = :ROW_COUNT
SELECT :ROW_COUNT = 0 AS nothing_updated \gset
\if :nothing_updated
\echo [B] `date +%H:%M:%S.%3N` no rows: the order was already paid. ROLLBACK
ROLLBACK;
\else
COMMIT;
\endif
\echo [B] `date +%H:%M:%S.%3N` done
SQL
}

# Sessão C: quem está esperando o quê, no meio da espera.
sessao_E14_C() {
  dc exec -T primary "${PSQL[@]}" <<'SQL'
\echo [C] `date +%H:%M:%S.%3N` looking at both sessions
SELECT application_name, state, wait_event_type, wait_event, left(query, 60) AS query
  FROM pg_stat_activity WHERE application_name IN ('session_A', 'session_B') ORDER BY 1;
SQL
}

cenario_E14() {
  titulo "E14 · concurrent double payment (same order, different keys)"
  local pedido a b c
  pedido=$(valor primary "INSERT INTO orders (customer_id, restaurant_id, total_cents) VALUES (777, 12, 2590) RETURNING id")
  sql primary -c "SELECT id, status FROM orders WHERE id = $pedido"
  a=$(mktemp); b=$(mktemp); c=$(mktemp)
  painel "$a" sessao-A sessao_E14_A "$pedido"
  local pid_a=$!
  sleep 1
  painel "$b" sessao-B sessao_E14_B "$pedido"
  local pid_b=$!
  sleep 1.5
  painel "$c" sessao-C sessao_E14_C
  local pid_c=$!
  wait "$pid_a" "$pid_b" "$pid_c"
  printf '\n-- session A (psql on primary)\n'; cat "$a"
  printf '\n-- session B (psql on primary, started 1 s later)\n'; cat "$b"
  printf '\n-- session C (psql on primary, in the middle of the wait)\n'; cat "$c"
  rm -f "$a" "$b" "$c"
  titulo "E14 · at the end"
  sql primary <<SQL
SELECT id, status FROM orders WHERE id = $pedido;
SELECT id, order_id, idempotency_key, amount_cents FROM payments WHERE order_id = $pedido;
SQL
}

pagamento_psql() {  # a transação do pagamento, com \timing (pedido, chave, rótulo da sessão, comando extra)
  cat <<SQL
\\timing on
\\echo [$3] \`date +%H:%M:%S.%3N\` starts
BEGIN;
$4
INSERT INTO payments (order_id, idempotency_key, amount_cents) VALUES ($1, '$2', 2590);
UPDATE orders SET status = 'paid' WHERE id = $1 AND status = 'awaiting_payment';
COMMIT;
\\echo [$3] \`date +%H:%M:%S.%3N\` done
SQL
}

sessao_E6_2() {  # o pagamento que fica esperando, no psql
  pagamento_psql "$1" 22222222-0000-4000-8000-000000000002 "session 2" "" \
    | dc exec -T -e PGAPPNAME=session_2 primary "${PSQL[@]}"
}
sessao_E6_app() { dc exec -T app npx tsx scenarios/e6-app.ts "$1"; }  # o mesmo, pelo node-pg

cenario_E6() {
  titulo "E6 · ANY 1 (replica1, replica2) with synchronous_commit = on"
  local p1 p2 p3 p4 p5 espera_psql espera_app
  read -r p1 p2 p3 p4 p5 < <(valor primary "WITH x AS (INSERT INTO orders (customer_id, restaurant_id, total_cents) SELECT 600 + g, 12, 2590 FROM generate_series(1, 5) g RETURNING id) SELECT string_agg(id::text, ' ' ORDER BY id) FROM x")
  sql primary <<'SQL'
ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 (replica1, replica2)';
SELECT pg_reload_conf();
SQL
  sleep 1
  sql primary <<'SQL'
SHOW synchronous_standby_names;
SHOW synchronous_commit;
SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1;
SQL

  titulo "E6 · stops replica2: the COMMIT goes on"
  roda dc stop replica2
  sql primary -c "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1"
  pagamento_psql "$p1" 11111111-0000-4000-8000-000000000001 "session 1" "" | sql primary

  titulo "E6 · stops replica1 too: the COMMIT waits"
  roda dc stop replica1
  sql primary -c "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1"
  espera_psql=$(mktemp); espera_app=$(mktemp)
  painel "$espera_psql" sessao-2 sessao_E6_2 "$p2"
  local pid_psql=$!
  painel "$espera_app" app sessao_E6_app "$p3"
  local pid_app=$!
  sleep 12  # a cena da espera dura uns 10 s
  printf '\n# %s: both sessions are still waiting\n' "$(hora)"
  sql primary -c "SELECT pid, application_name, state, wait_event_type, wait_event, now() - xact_start AS waiting_for, left(query, 30) AS query FROM pg_stat_activity WHERE wait_event = 'SyncRep' ORDER BY application_name"

  titulo "E6 · meanwhile: synchronous_commit = local confirms right away"
  pagamento_psql "$p4" 44444444-0000-4000-8000-000000000004 "session 3" "SET LOCAL synchronous_commit = local;" | sql primary
  titulo "E6 · and the read on the primary works"
  sql primary -c '\timing on' -c "SELECT id, status FROM orders WHERE id IN ($p1, $p2, $p3, $p4) ORDER BY id"

  titulo "E6 · cancels the wait (pg_cancel_backend)"
  sql primary -c "SELECT pid, application_name, pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep' ORDER BY application_name"
  wait "$pid_psql" "$pid_app" || true
  printf '\n-- session 2 (psql on primary), the one that was waiting\n'; cat "$espera_psql"
  printf '\n-- the app (node-pg), which was also waiting\n'; cat "$espera_app"
  rm -f "$espera_psql" "$espera_app"
  sql primary -c "SELECT id, status FROM orders WHERE id IN ($p1, $p2, $p3, $p4) ORDER BY id"

  titulo "E6 · brings the replicas back"
  roda dc start replica1 replica2
  esperar_saudavel replica1 replica2
  esperar_replicas_em_dia
  sql primary -c "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1"
  sql replica1 -c "SELECT id, status FROM orders WHERE id IN ($p1, $p2, $p3, $p4) ORDER BY id"
  sql primary <<'SQL'
ALTER SYSTEM RESET synchronous_standby_names;
SELECT pg_reload_conf();
SQL
}

cenario_E7() {
  titulo "E7 · network partition: replica2 loses the primary but keeps serving"
  local load_log rede="${PROJETO}_replication_net" ctn="${PROJETO}-replica2-1"  # load_log aparece na tela
  load_log=$(mktemp)
  executa "docker compose exec -T primary pgbench -U postgres -n -c 1 -R 50 -T 3600 -f /lab-sql/orders-load.sql delivery > \"\$load_log\" 2>&1 &   # ~50 new orders per second on the primary"
  local pid_carga=$!
  sleep 3
  sql primary -c "SELECT application_name, state, sent_lsn, replay_lsn FROM pg_stat_replication ORDER BY 1"
  roda docker network disconnect "$rede" "$ctn"
  printf '# %s: replica2 disconnected from the replication network (still on the app network)\n' "$(hora)"
  for i in 1 2 3 4; do
    sleep 5
    printf '\n# %s: sample %s\n' "$(hora)" "$i"
    sql primary -c "SELECT count(*) AS orders_on_primary, now()::time(0) AS time_now FROM orders"
    sql replica2 -c "SELECT count(*) AS orders_on_replica2, pg_last_xact_replay_timestamp()::time(3) AS last_replayed, now() - pg_last_xact_replay_timestamp() AS lag FROM orders"
    sql replica1 -c "SELECT count(*) AS orders_on_replica1, now() - pg_last_xact_replay_timestamp() AS lag FROM orders"
  done
  sql primary -c "SELECT application_name, state, sent_lsn, replay_lsn, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS bytes_behind FROM pg_stat_replication ORDER BY 1"
  sql replica2 -c "SELECT status, sender_host, latest_end_lsn, latest_end_time FROM pg_stat_wal_receiver"

  titulo "E7 · reconnects replica2"
  roda docker network connect "$rede" "$ctn"
  local t0=$SECONDS
  for _ in $(seq 1 240); do
    local p r
    p=$(valor primary "SELECT count(*) FROM orders"); r=$(valor replica2 "SELECT count(*) FROM orders")
    [ "$r" -ge "$p" ] && break
    sleep 0.5
  done
  printf '# %s: replica2 caught up with the primary %s s after reconnecting\n' "$(hora)" "$((SECONDS - t0))"
  dc exec -T primary pkill -INT -x pgbench >/dev/null 2>&1 || true
  wait "$pid_carga" 2>/dev/null || true
  rm -f "$load_log"
  sleep 1
  sql primary -c "SELECT count(*) AS orders_on_primary FROM orders"
  sql replica2 -c "SELECT count(*) AS orders_on_replica2, now() - pg_last_xact_replay_timestamp() AS lag FROM orders"
  sql primary -c "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1"
}

cenario_E8() {
  titulo "E8 · idempotency in psql (same idempotency_key twice)"
  local pedido
  pedido=$(valor primary "INSERT INTO orders (customer_id, restaurant_id, total_cents) VALUES (888, 12, 2590) RETURNING id")
  sql primary -v order_id="$pedido" <<'SQL'
\set VERBOSITY verbose
BEGIN;
INSERT INTO payments (order_id, idempotency_key, amount_cents) VALUES (:order_id, '9f1c2a7e-3b4d-4e8f-a1b2-c3d4e5f60718', 2590);
UPDATE orders SET status = 'paid' WHERE id = :order_id AND status = 'awaiting_payment';
COMMIT;
BEGIN;
INSERT INTO payments (order_id, idempotency_key, amount_cents) VALUES (:order_id, '9f1c2a7e-3b4d-4e8f-a1b2-c3d4e5f60718', 2590);
UPDATE orders SET status = 'paid' WHERE id = :order_id AND status = 'awaiting_payment';
COMMIT;
SELECT count(*) AS payments FROM payments WHERE order_id = :order_id;
SQL
  titulo "E8 · the same thing through the app (node-pg)"
  app scenarios/e8-idempotency.ts
}

sessao_E9_escritor() { dc exec -T app npx tsx scenarios/e9-writer.ts --per-second 115; }

cenario_E9() {
  titulo "E9 · asynchronous failover: 1 s of delay from the primary to the replicas"
  sql primary -c "SHOW synchronous_standby_names" -c "SHOW synchronous_commit"
  roda dc exec -T primary net.sh delay 1000ms limit 100000
  local out
  out=$(mktemp)
  # o escritor roda no painel dele; aqui, um comentário (não é "$": este terminal não digitou nada) com o comando exato
  printf '\n# %s: in the WRITER panel: docker compose exec -T app npx tsx scenarios/e9-writer.ts --per-second 115   (the pace of the peak; notes every COMMIT ok)\n' "$(hora)"
  painel "$out" escritor sessao_E9_escritor
  local pid=$!
  sleep 6
  printf '\n# %s\n' "$(hora)"
  sql replica1 -c "SELECT now() - pg_last_xact_replay_timestamp() AS replica1_lag"
  roda docker kill "${PROJETO}-primary-1"
  printf '# %s: primary dead (SIGKILL)\n' "$(hora)"
  wait "$pid" || true
  cat "$out"; rm -f "$out"
  titulo "E9 · promotes replica1"
  sql replica1 -c "SELECT pg_promote()" -c "SELECT pg_is_in_recovery()"
  app scenarios/e9-check.ts 1000ms
}

# ---------------------------------------------------------------- ScyllaDB
cql() {  # cql <nó> "comando 1" "comando 2" ...  (uma sessão cqlsh só; as saídas vêm em ordem, depois dos comandos)
  local no=$1; shift
  local juntos=""
  printf '\n'
  for c in "$@"; do printf 'cqlsh@%s> %s;\n' "$no" "$c"; juntos+="${juntos:+ }$c;"; done
  dc exec -T -e PYTHONUNBUFFERED=1 "$no" sh -c 'cqlsh -e "$1" 2>&1' cqlsh "$juntos" || true
}

esperar_scylla() {  # espera os três nós UN vistos de cada nó vivo
  for _ in $(seq 1 180); do
    local ok=1
    for no in "$@"; do
      [ "$(dc exec -T "$no" nodetool status 2>/dev/null | grep -c '^UN')" = 3 ] || ok=0
      dc exec -T "$no" cqlsh -e 'SELECT now() FROM system.local' >/dev/null 2>&1 || ok=0
    done
    [ $ok = 1 ] && return 0
    sleep 2
  done
  log "the Scylla cluster did not come up"; return 1
}

subir_scylla() {
  log "stopping PostgreSQL (frees CPU) and starting ScyllaDB from scratch (3 nodes, in sequence)"
  dc stop primary replica1 replica2 replicas app >/dev/null 2>&1 || true
  dc rm -sfv scylla1 scylla2 scylla3 >/dev/null 2>&1 || true
  dc up -d --wait scylla1 scylla2 scylla3 >/dev/null 2>&1
  esperar_scylla scylla1 scylla2 scylla3
}

LER_42="SELECT * FROM deliveries.positions WHERE courier_id = 42 AND day = '2026-10-28' LIMIT 1"
LER_7="SELECT * FROM deliveries.positions WHERE courier_id = 7 AND day = '2026-10-28' LIMIT 1"

cenario_E10() {
  titulo "E10 · versions and cluster"
  roda dc exec -T scylla1 scylla --version
  roda dc exec -T scylla1 nodetool status
  titulo "E10 · schema (keyspace deliveries, RF = 3)"
  executa "cat scylla/schema.cql"
  roda dc exec -T scylla1 cqlsh -f /lab-scylla/schema.cql
  cql scylla1 "DESCRIBE KEYSPACE deliveries"
  titulo "E10 · a few positions and the query by key"
  cql scylla1 \
    "INSERT INTO deliveries.positions (courier_id, day, recorded_at, lat, lon) VALUES (42, '2026-10-28', '2026-10-28 12:00:00+0000', -23.5614, -46.6559)" \
    "INSERT INTO deliveries.positions (courier_id, day, recorded_at, lat, lon) VALUES (42, '2026-10-28', '2026-10-28 12:00:30+0000', -23.5621, -46.6548)" \
    "INSERT INTO deliveries.positions (courier_id, day, recorded_at, lat, lon) VALUES (42, '2026-10-28', '2026-10-28 12:01:00+0000', -23.5629, -46.6537)" \
    "INSERT INTO deliveries.positions (courier_id, day, recorded_at, lat, lon) VALUES (42, '2026-10-28', '2026-10-28 12:01:30+0000', -23.5636, -46.6526)" \
    "INSERT INTO deliveries.positions (courier_id, day, recorded_at, lat, lon) VALUES (43, '2026-10-28', '2026-10-28 12:01:10+0000', -23.5505, -46.6333)" \
    "INSERT INTO deliveries.positions (courier_id, day, recorded_at, lat, lon) VALUES (42, '2026-10-27', '2026-10-27 19:40:00+0000', -23.5489, -46.6388)"
  cql scylla1 "$LER_42"
  cql scylla1 "SELECT * FROM deliveries.positions WHERE courier_id = 42 AND day = '2026-10-28'"
  titulo "E10 · query without the partition key"
  cql scylla1 "SELECT * FROM deliveries.positions WHERE lat > 0"
  titulo "E10 · which nodes the partition (42, 2026-10-28) lives on"
  roda dc exec -T scylla1 nodetool getendpoints deliveries positions 42:2026-10-28
  printf '\n# Node IPs: '
  for no in scylla1 scylla2 scylla3; do
    printf '%s=%s ' "$no" "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${PROJETO}-${no}-1")"
  done
  printf '\n'
}

cenario_E11() {
  titulo "E11 · per-operation consistency with a node down"
  # O TRACING lê o keyspace system_traces, que no Scylla tem RF 2: com um nó fora, o trace
  # pode não ser lido (aconteceu na primeira rodada). Sobe para RF 3 antes de parar o nó.
  cql scylla1 "SELECT keyspace_name, replication FROM system_schema.keyspaces WHERE keyspace_name = 'system_traces'" \
    "ALTER KEYSPACE system_traces WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 3}"
  roda dc stop scylla3
  sleep 3
  roda dc exec -T scylla1 nodetool status
  cql scylla1 "CONSISTENCY QUORUM" \
    "INSERT INTO deliveries.positions (courier_id, day, recorded_at, lat, lon) VALUES (42, '2026-10-28', '2026-10-28 12:02:00+0000', -23.5643, -46.6515)" \
    "$LER_42"
  cql scylla1 "CONSISTENCY ALL" "$LER_42"
  cql scylla1 "CONSISTENCY ALL" \
    "INSERT INTO deliveries.positions (courier_id, day, recorded_at, lat, lon) VALUES (42, '2026-10-28', '2026-10-28 12:02:30+0000', -23.5650, -46.6504)"
  titulo "E11 · TRACING: how many replicas answered"
  cql scylla1 "CONSISTENCY QUORUM" "TRACING ON" "$LER_42"
  titulo "E11 · node 3 comes back"
  roda dc start scylla3
  esperar_scylla scylla1 scylla2 scylla3
  roda dc exec -T scylla1 nodetool status
}

api() {  # api <nó> <GET|POST> <caminho>: a API REST do Scylla (porta 10000), de dentro do nó
  local no=$1 metodo=$2 caminho=$3
  mostra "docker compose exec -T $no curl -s -X $metodo 'localhost:10000$caminho'"
  dc exec -T "$no" curl -s -X "$metodo" "localhost:10000$caminho"; echo
}

cenario_E12() {
  titulo "E12 · ONE/ONE with RF = 3: the old value, written to all three nodes"
  cql scylla1 "CONSISTENCY ALL" \
    "INSERT INTO deliveries.positions (courier_id, day, recorded_at, lat, lon) VALUES (7, '2026-10-28', '2026-10-28 12:00:00+0000', -23.5610, -46.6560)" \
    "$LER_7"
  titulo "E12 · stops node 3 and turns hinted handoff off on the others"
  roda dc stop scylla3
  sleep 3
  # O nodetool do Scylla 2026.3 não tem disablehandoff/statushandoff: vai pela API REST.
  roda dc exec -T scylla1 nodetool disablehandoff || true
  for no in scylla1 scylla2; do
    api "$no" POST "/storage_proxy/hinted_handoff_enabled?enable=false"
    api "$no" GET /storage_proxy/hinted_handoff_enabled
    api "$no" GET /storage_proxy/total_hints
  done
  roda dc exec -T scylla1 nodetool status
  titulo "E12 · writes the new position with ONE (node 3 down)"
  cql scylla1 "CONSISTENCY ONE" \
    "INSERT INTO deliveries.positions (courier_id, day, recorded_at, lat, lon) VALUES (7, '2026-10-28', '2026-10-28 12:05:00+0000', -23.5702, -46.6481)"
  for no in scylla1 scylla2; do api "$no" GET /storage_proxy/total_hints; done
  titulo "E12 · node 3 comes back and we read from it with ONE"
  roda dc start scylla3
  esperar_scylla scylla1 scylla2 scylla3
  roda dc exec -T scylla3 nodetool status
  for i in 1 2 3 4 5; do
    printf '\n# read %s on node 3, %s\n' "$i" "$(hora)"
    cql scylla3 "CONSISTENCY ONE" "$LER_7"
  done
  titulo "E12 · the same read with TRACING (where the answer came from)"
  cql scylla3 "CONSISTENCY ONE" "TRACING ON" "$LER_7"
  titulo "E12 · now with QUORUM, on node 3"
  cql scylla3 "CONSISTENCY QUORUM" "$LER_7"
  titulo "E12 · and ONE on node 3 again, after the QUORUM read"
  cql scylla3 "CONSISTENCY ONE" "$LER_7"
  for no in scylla1 scylla2; do api "$no" POST "/storage_proxy/hinted_handoff_enabled?enable=true"; done
}

# ---------------------------------------------------------------- gravação
# Um .cast (asciicast v2, texto com o tempo real de cada saída) por cenário, e um por
# painel nos cenários com sessões em paralelo. A subida do banco fica fora da gravação.
GRAVACOES="$LAB/gravacoes"
TELA="120x40"

cast() {  # cast <painel ou ""> <comando...>: grava e anota o instante do início (a linha do tempo comum)
  local arq="$GRAVACOES/$ID_GRAVANDO${1:+-$1}.cast"; shift
  printf '{"cast": "%s", "inicio_ms": %s}\n' "$(basename "$arq")" "$(python3 -c 'import time; print(int(time.time() * 1000))')" \
    >>"$GRAVACOES/$ID_GRAVANDO.inicios.jsonl"
  asciinema rec --quiet --headless --overwrite --return -f asciicast-v2 --window-size "$TELA" \
    --command "$(printf '%q ' "$@")" "$arq" </dev/null
}

painel() {  # painel <arquivo> <nome> <função> [args]: em segundo plano; na gravação, num terminal próprio
  local arq=$1 nome=$2; shift 2
  if [ -n "${ID_GRAVANDO:-}" ]; then
    cast "$nome" "$LAB/rodar.sh" --painel "$arq" "$@" &
  else
    "$@" >"$arq" 2>&1 &
  fi
}

gravar() {
  export ID_GRAVANDO=$1
  log "recording $1"
  mkdir -p "$GRAVACOES"
  : >"$GRAVACOES/$1.inicios.jsonl"
  cast "" "$LAB/rodar.sh" --cenario "$1"
  python3 "$LAB/ferramentas/cast_linhas.py" "$1"
}

# ---------------------------------------------------------------- execução
rodar() {  # rodar <ID>: grava saidas/<ID>.txt e registra as tabelas no resultados.json
  local id=$1
  [ -n "${ID_GRAVANDO:-}" ] || log "running $id"
  { printf '# %s · %s\n' "$id" "$(date '+%Y-%m-%d %H:%M:%S %Z')"; "cenario_$id"; } 2>&1 | tee "$SAIDAS/$id.txt"
  case $id in
    E1 | E6 | E7 | E8 | E10 | E11 | E12 | E13 | E14) registrar "$id" "saidas/$id.txt" ;;
  esac
}

esquema_scylla() { dc exec -T scylla1 cqlsh -f /lab-scylla/schema.cql; }

PG=(E15 E1 E2 E3 E4 E5 E13 E14 E6 E7 E8 E9)
SCYLLA=(E10 E11 E12)

case "${1:-}" in
  E1 | E2 | E3 | E4 | E5 | E6 | E7 | E8 | E9 | E13 | E14 | E15) subir_pg; rodar "$1" ;;
  E10 | E11 | E12) subir_scylla; [ "$1" = E10 ] || esquema_scylla; rodar "$1" ;;
  postgres) for id in "${PG[@]}"; do subir_pg; rodar "$id"; done ;;
  scylla) subir_scylla; for id in "${SCYLLA[@]}"; do rodar "$id"; done ;;
  todos) "$0" postgres; "$0" scylla ;;
  gravar)
    case "${2:-}" in
      E1 | E2 | E3 | E4 | E5 | E6 | E7 | E8 | E9 | E13 | E14 | E15) subir_pg; gravar "$2" ;;
      E10 | E11 | E12) subir_scylla; [ "$2" = E10 ] || esquema_scylla; gravar "$2" ;;
      postgres) for id in "${PG[@]}"; do subir_pg; gravar "$id"; done ;;
      scylla) subir_scylla; for id in "${SCYLLA[@]}"; do gravar "$id"; done ;;
      todos) "$0" gravar postgres; "$0" gravar scylla ;;
      *) sed -n '2,13p' "$0"; exit 2 ;;
    esac ;;
  --cenario) rodar "$2" ;;                                  # dentro da gravação
  --painel) arq=$2; shift 2; "$@" 2>&1 | tee "$arq" ;;      # dentro da gravação de um painel
  derrubar) dc down -v ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
