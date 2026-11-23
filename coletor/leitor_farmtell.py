"""Leitor do relatório FarmTell "RELATÓRIO LOTES ATIVOS".

Cada lote ocupa um bloco de três faixas (MN, MS e NDT) com as colunas:
Lote/Curral, Cabs/Sexo, Raça/Critério, Dt.Entrada/Dias Conf, Cons. Média 3 dias,
Cons. Dia Anterior, Consumo Médio, Consumo do Dia (kg/cab e %PV em MN, MS e NDT),
Nome Dieta/Dias Dieta, Pesos (Entrada, Atual Prj.), Data Abate/Peso Meta Abate e
Escore (D-2, D-1, Dia).

- Os blocos são achados pelos rótulos "MS" da coluna "Cons. Média 3 dias"; as colunas,
  pela posição dos títulos no cabeçalho de cada página (as páginas podem ter escalas diferentes).
- O "Critério" (nome do dono/parceiro) é ignorado de propósito.
- Para no "Resumo Geral" (totais por grupo, que o app recalcula a partir dos lotes).

Uso:  python leitor_farmtell.py relatorio.pdf   -> imprime JSON
"""
from __future__ import annotations

import io
import json
import re
import sys

import pdfplumber

from leitor_feedmanager import _data, _num

SISTEMA = "farmtell"
JANELA_MEDIA = 3


class RelatorioInvalido(Exception):
    pass


NUMRE = re.compile(r"^-?[\d.]*\d(,\d+)?$")
DATARE = re.compile(r"^\d{2}/\d{2}/\d{4}$")


def _cabecalho(ws):
    """Posições (x0) dos títulos das colunas na página."""
    pos = {}
    cons = [w for w in ws if w["text"] == "Cons." and w["top"] < 90]
    consumo = [w for w in ws if w["text"] == "Consumo" and w["top"] < 90]
    for nome in ("Lote", "Cabs", "Raça", "Dt.Entrada", "Nome", "Pesos", "Data", "Escore", "D-2", "Meta"):
        c = [w for w in ws if w["text"] == nome and w["top"] < 90]
        if c:
            pos[nome] = c[0]["x0"]
    if len(cons) < 2 or len(consumo) < 2 or len(pos) < 10:
        return None
    cons.sort(key=lambda w: w["x0"]); consumo.sort(key=lambda w: w["x0"])
    pos["g3d"], pos["gant"] = cons[0]["x0"], cons[1]["x0"]
    pos["gmed"], pos["gdia"] = consumo[0]["x0"], consumo[1]["x0"]
    pos["y_cab"] = max(w["top"] for w in ws if w["text"] in ("Curral", "Sexo", "Kg\\cab") and w["top"] < 90)
    return pos


def ler(pdf) -> tuple[dict, list[dict]]:
    if isinstance(pdf, (bytes, bytearray)):
        pdf = io.BytesIO(pdf)
    meta: dict = {"sistema": SISTEMA, "janela_media": JANELA_MEDIA}
    baias: list[dict] = []
    sem_trato = 0
    with pdfplumber.open(pdf) as doc:
        for p in doc.pages:
            ws = p.extract_words(x_tolerance=1.5)
            pos = _cabecalho(ws)
            if not pos:
                if any(w["text"] == "Resumo" for w in ws):
                    break               # página só com os resumos
                continue
            if "data_ref" not in meta:
                d = [w for w in ws if w["top"] < 55 and DATARE.match(w["text"])]
                if d:
                    meta["data_ref"] = _data(d[-1]["text"])
            fim = min([w["top"] for w in ws if w["text"] == "Resumo" and w["top"] > pos["y_cab"]] or [p.height])
            corpo = [w for w in ws if pos["y_cab"] + 5 < w["top"] < fim - 2]

            # limites das colunas (x)
            lim_esq = pos["Cabs"] - 8
            col_cab = (lim_esq, pos["Raça"] - 8)
            col_dt = (pos["Dt.Entrada"] - 5, pos["g3d"] - 8)
            grupos = [("3d", pos["g3d"] - 6, pos["gant"] - 6), ("ant", pos["gant"] - 6, pos["gmed"] - 10),
                      ("med", pos["gmed"] - 10, pos["gdia"] - 10), ("dia", pos["gdia"] - 10, pos["Nome"] - 18)]
            col_dieta = (pos["Nome"] - 18, pos["Pesos"] - 12)
            col_pesos = (pos["Pesos"] - 12, pos["Data"] - 4)
            col_abate = (pos["Data"] - 4, pos["D-2"] - 6)
            col_esc = pos["D-2"] - 6

            ancoras = sorted((w for w in corpo if w["text"] == "MS" and grupos[0][1] <= w["x0"] < grupos[0][2]),
                             key=lambda w: w["top"])
            for a in ancoras:
                y = a["top"]
                mn = [w for w in corpo if w["text"] == "MN" and grupos[0][1] <= w["x0"] < grupos[0][2] and 8 < y - w["top"] < 30]
                nd = [w for w in corpo if w["text"] == "NDT" and grupos[0][1] <= w["x0"] < grupos[0][2] and 8 < w["top"] - y < 30]
                if not mn or not nd:
                    raise RelatorioInvalido(f"bloco de lote incompleto na página {p.page_number}")
                y_mn, y_nd = mn[-1]["top"], nd[0]["top"]
                bloco = [w for w in corpo if y_mn - 6 <= w["top"] <= y_nd + 6]

                def faixa(x0, x1, y0, y1):
                    return sorted((w for w in bloco if x0 <= w["x0"] < x1 and y0 <= w["top"] < y1),
                                  key=lambda w: (round(w["top"]), w["x0"]))

                def numeros(x0, x1, y0, y1):          # mesma faixa: da esquerda para a direita
                    ws_ = sorted(faixa(x0, x1, y0, y1), key=lambda w: w["x0"])
                    return [_num(w["text"]) for w in ws_ if NUMRE.match(w["text"])]

                meio = (y_mn + y) / 2 + 2           # divide as linhas de cima (lote) das do meio (critério)
                # Lote (linha de cima) e Curral (linha de baixo); o critério do meio é ignorado
                # "2026-C-21-G3 - NOME": o que vem depois do " - " é o critério (nome), que não guardamos
                lote = " ".join(w["text"] for w in faixa(0, lim_esq, y_mn - 6, meio))
                lote = re.split(r"\s+-(\s|$)", lote, maxsplit=1)[0].strip(" -")
                curral = " ".join(w["text"] for w in faixa(0, lim_esq, y + 6, y_nd + 6)).strip()
                cabs = numeros(*col_cab, y_mn - 6, y - 3)
                sexo = " ".join(w["text"] for w in faixa(*col_cab, y + 6, y_nd + 6)) or None
                raca = " ".join(w["text"] for w in faixa(col_cab[1], col_dt[0], y_mn - 6, meio + 2)) or None
                dts = [w["text"] for w in faixa(*col_dt, y_mn - 6, y) if DATARE.match(w["text"])]
                dias = numeros(*col_dt, y + 6, y_nd + 6)

                cons = {}
                for nome, x0, x1 in grupos:
                    for rot, y0 in (("MN", y_mn), ("MS", y)):
                        v = numeros(x0, x1, y0 - 4, y0 + 4)
                        cons[(nome, rot)] = (v + [None, None])[:2]      # kg/cab, %PV
                dieta = " ".join(w["text"] for w in faixa(*col_dieta, y_mn - 6, y - 3)).strip() or None
                dias_dieta = numeros(*col_dieta, y + 6, y_nd + 6)
                pesos_e = numeros(*col_pesos, y_mn - 6, y - 3)
                pesos_a = numeros(*col_pesos, y + 6, y_nd + 6)
                dt_abate = [w["text"] for w in faixa(*col_abate, y_mn - 6, y - 3) if DATARE.match(w["text"])]
                meta_abate = numeros(*col_abate, y + 6, y_nd + 6)
                esc = numeros(col_esc, p.width, y - 4, y + 4)

                if not curral or not cabs:
                    raise RelatorioInvalido(f"lote sem curral ou cabeças na página {p.page_number}")
                ms_dia = cons[("dia", "MS")][0]
                if not ms_dia and not dieta:
                    sem_trato += 1
                    continue
                esc = (esc + [None, None, None])[:3]           # D-2, D-1, Dia
                baias.append({
                    "curral": curral, "lote": lote or curral, "setor": None, "raca": raca, "ct": sexo,
                    "cab": int(cabs[0]), "dt_entrada": _data(dts[0]) if dts else None,
                    "dias_conf": int(dias[0]) if dias else None,
                    "cons_dia_mn": cons[("dia", "MN")][0], "cons_dia_ms": ms_dia, "cons_dia_pv": cons[("dia", "MS")][1],
                    "mn_1d": cons[("ant", "MN")][0], "ms_1d": cons[("ant", "MS")][0], "ims_pv_1d": cons[("ant", "MS")][1],
                    "mn_5d": cons[("3d", "MN")][0], "ms_5d": cons[("3d", "MS")][0], "ims_pv_5d": cons[("3d", "MS")][1],
                    "mn_med": cons[("med", "MN")][0], "ms_med": cons[("med", "MS")][0], "ims_pv_med": cons[("med", "MS")][1],
                    "racao": dieta, "racao_dias": int(dias_dieta[0]) if dias_dieta else None,
                    "peso_entrada": pesos_e[0] if pesos_e else None, "peso_atual_prj": pesos_a[0] if pesos_a else None,
                    "dt_abate": _data(dt_abate[0]) if dt_abate else None,
                    "peso_abate_prev": meta_abate[0] if meta_abate else None,
                    # escore: "Dia" é a leitura de hoje (equivale à nota "ontem" do TGC, que define o trato do dia)
                    "cocho_d1": esc[2], "cocho_d2": esc[1], "cocho_d3": esc[0],
                })
    if not meta.get("data_ref"):
        raise RelatorioInvalido("não encontrei a data do relatório – não parece o relatório do FarmTell")
    if not baias:
        raise RelatorioInvalido("nenhum lote encontrado no relatório")
    meta.update(n_baias=len(baias), n_cab=sum(b["cab"] for b in baias), sem_trato=sem_trato)
    return meta, baias


if __name__ == "__main__":
    m, b = ler(sys.argv[1])
    print(json.dumps({"meta": m, "baias": b}, ensure_ascii=False, indent=1))
