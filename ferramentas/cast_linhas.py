#!/usr/bin/env python3
"""Junta os .cast de um cenário em gravacoes/<ID>.linhas.json: cada linha com o instante
em que apareceu, numa linha do tempo só (segundos desde o início do cenário).

    cast_linhas.py E6

É o que a cena de terminal da /animate lê. Não muda texto nenhum: tira só o \\r e, se
houver, os códigos de cor.
"""
import json
import re
import sys
from pathlib import Path

GRAVACOES = Path(__file__).resolve().parent.parent / "gravacoes"
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def linhas_do_cast(arq):
    linhas, atual, inicio = [], "", None
    for bruto in arq.read_text().splitlines()[1:]:
        t, tipo, dado = json.loads(bruto)
        if tipo != "o":
            continue
        for pedaco in dado.splitlines(keepends=True):
            if not atual and inicio is None:
                inicio = t
            atual += pedaco
            if atual.endswith("\n"):
                linhas.append({"t": round(inicio, 3), "texto": ANSI.sub("", atual).rstrip("\r\n")})
                atual, inicio = "", None
    if atual:
        linhas.append({"t": round(inicio, 3), "texto": ANSI.sub("", atual).rstrip("\r\n")})
    return linhas


def main():
    cenario = sys.argv[1]
    inicios = [json.loads(l) for l in (GRAVACOES / f"{cenario}.inicios.jsonl").read_text().splitlines()]
    principal = next(i["inicio_ms"] for i in inicios if i["cast"] == f"{cenario}.cast")
    paineis = {}
    for i in inicios:
        nome = i["cast"].removesuffix(".cast").removeprefix(cenario).removeprefix("-") or "principal"
        deslocamento = (i["inicio_ms"] - principal) / 1000
        linhas = linhas_do_cast(GRAVACOES / i["cast"])
        for l in linhas:
            l["t"] = round(l["t"] + deslocamento, 3)
        paineis[nome] = {"cast": i["cast"], "inicio_s": round(deslocamento, 3), "linhas": linhas}
    saida = {"cenario": cenario, "paineis": paineis}
    (GRAVACOES / f"{cenario}.linhas.json").write_text(json.dumps(saida, indent=1, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
