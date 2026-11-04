#!/usr/bin/env python3
"""Grava no resultados.json o que uma saída de psql/cqlsh mostrou.

    registrar.py CHAVE saidas/E1.txt ['{"extra": 1}']

Guarda, da saída: as tabelas (formato alinhado do psql e do cqlsh), as mensagens
(ERROR, WARNING, DETAIL, erros do cqlsh) e os "Time: ... ms" do \\timing, em ordem.
Não calcula nada: só copia o que está no arquivo. As chaves do JSON são em inglês: tables
(line, columns, rows), messages, timing_ms, pgbench (section, clients, transactions, failures,
latency_avg_ms, tps), recorded_at.
"""
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
SEPARADOR = re.compile(r"^-+(\+-+)*$")
FIM = re.compile(r"^\(\d+ rows?\)$")
MENSAGEM = re.compile(
    r"^(ERROR|WARNING|DETAIL|HINT|LOCATION|SCHEMA NAME|TABLE NAME|CONSTRAINT NAME|FATAL|psql:|<stdin>:)"
    r"|Error from server|NoHostAvailable|InvalidRequest|Unavailable|\[app "
)
TEMPO = re.compile(r"^Time: ([\d.]+) ms")


def tabelas(linhas):
    saida = []
    for i, linha in enumerate(linhas):
        if i == 0 or not SEPARADOR.match(linha.strip()):
            continue
        cab = [c.strip() for c in linhas[i - 1].split("|")]
        rows = []
        for l in linhas[i + 1:]:
            s = l.strip()
            if not s or FIM.match(s):
                break
            rows.append(dict(zip(cab, [c.strip() for c in l.split("|")])))
        saida.append({"line": i, "columns": cab, "rows": rows})
    return saida


def pgbench(linhas):
    """Resumos do pgbench, cada um com o título (==== ... ====) da seção em que saiu."""
    saida, secao, atual = [], None, None
    for l in linhas:
        s = l.strip()
        if s.startswith("==== "):
            secao = s.strip("= ").strip()
        elif m := re.match(r"number of clients: (\d+)", s):
            atual = {"section": secao, "clients": int(m.group(1))}
        elif atual is not None and (m := re.match(r"number of transactions actually processed: (\d+)", s)):
            atual["transactions"] = int(m.group(1))
        elif atual is not None and (m := re.match(r"number of failed transactions: (\d+)", s)):
            atual["failures"] = int(m.group(1))
        elif atual is not None and (m := re.match(r"latency average = ([\d.]+) ms", s)):
            atual["latency_avg_ms"] = float(m.group(1))
        elif atual is not None and (m := re.match(r"tps = ([\d.]+)", s)):
            atual["tps"] = float(m.group(1))
            saida.append(atual)
            atual = None
    return saida


def main():
    chave, arquivo = sys.argv[1], sys.argv[2]
    extra = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    linhas = (LAB / arquivo).read_text().splitlines()
    registro = {
        "output": arquivo,
        **extra,
        "tables": tabelas(linhas),
        "messages": [l.strip() for l in linhas if MENSAGEM.search(l)],
        "timing_ms": [float(m.group(1)) for l in linhas if (m := TEMPO.match(l.strip()))],
        "pgbench": pgbench(linhas),
        "recorded_at": datetime.now(timezone.utc).isoformat(),
    }
    arq = LAB / "resultados.json"
    atual = json.loads(arq.read_text()) if arq.exists() else {}
    atual[chave] = registro
    arq.write_text(json.dumps(atual, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
