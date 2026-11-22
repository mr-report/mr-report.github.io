"""Leitor do relatório TGC "Controle diário dos lotes ativos" (Ficha 007).

- Lê as células na ordem em que o PDF as desenha, o que separa textos que o
  relatório imprime sobrepostos (nome do rebanho, nome da ração cortado etc.).
- Descobre as colunas pelo cabeçalho de cada página, então funciona nas
  variantes "Relatório Contrato" e "Relatório Rebanho" e aguenta pequenas
  mudanças de layout.
- Ignora dados pessoais (nome do rebanho/fornecedor).

Uso:  python leitor_tgc.py relatorio.pdf   -> imprime JSON
"""
from __future__ import annotations

import io
import json
import re
import sys
from datetime import date

import pdfplumber

# rótulos do cabeçalho, na ordem em que aparecem -> nome do campo
HEADER_MAP = [
    ("CURRAL", "curral"), ("LOTE", "lote"), ("Cab", "cab"), ("Sub. Contrato", "sub_contrato"),
    ("Rebanho", "rebanho"), ("CT", "ct"), ("Dt. Entrada", "dt_entrada"), ("Dias", "dias_conf"),
    ("MS -5", "ms_5d"), ("MN -5", "mn_5d"), ("MS -1", "ms_1d"), ("MN -1", "mn_1d"),
    ("MS", "ms_med"), ("MN", "mn_med"),
    ("Nome", "racao"), ("Dias", "racao_dias"), ("Tipo", "racao_tipo_dias"),
    ("Entrada", "peso_entrada"), ("Atual Prj.", "peso_atual_prj"),
    ("5", "ims_pv_5d"), ("1", "ims_pv_1d"), ("Med", "ims_pv_med"),
    ("Natural", "cons_dia_mn"), ("Seca", "cons_dia_ms"), ("%PV", "cons_dia_pv"),
    ("Dias Lt.", "dt_abate"), ("1", "cocho_d1"), ("2", "cocho_d2"), ("3", "cocho_d3"),
]
DUAS_PALAVRAS = {"Sub. Contrato", "Dt. Entrada", "Atual Prj.", "Dias Lt.", "MS -5", "MN -5", "MS -1", "MN -1"}
TEXTO = {"curral", "sub_contrato", "rebanho", "ct", "racao", "dt_entrada", "dt_abate"}
INTEIROS = {"lote", "cab", "dias_conf", "racao_dias", "racao_tipo_dias"}
OBRIGATORIOS = ["curral", "lote", "cab", "dias_conf", "cons_dia_ms", "cons_dia_pv", "peso_atual_prj"]
IGNORAR = {"rebanho"}  # dado pessoal


class RelatorioInvalido(Exception):
    pass


def _celulas(chars):
    grupos, atual = [], []
    for ch in chars:
        if atual and (ch["x0"] < atual[-1]["x0"] - 0.5 or ch["x0"] - atual[-1]["x1"] > 2.5
                      or abs(ch["top"] - atual[-1]["top"]) > 1.5):
            grupos.append(atual)
            atual = []
        atual.append(ch)
    if atual:
        grupos.append(atual)
    # nome cortado (ex.: ração) às vezes "encosta" no número seguinte: separa
    separados = []
    for g in grupos:
        t = "".join(c["text"] for c in g)
        m = re.search(r"(\d{1,3},\d{2})$", t)
        if m and re.search(r"[A-Za-zÀ-ú]", t[:m.start()]):
            separados += [g[:m.start()], g[m.start():]]
        else:
            separados.append(g)
    out = []
    for g in separados:
        t = "".join(c["text"] for c in g).strip()
        if t:
            out.append({"x0": g[0]["x0"], "x1": max(c["x1"] for c in g), "y": g[0]["top"], "t": t})
    return out


def _num(s: str):
    s = s.strip()
    if re.fullmatch(r"-?\d{1,3}(\.\d{3})+,\d+|-?\d+,\d+", s):
        return float(s.replace(".", "").replace(",", "."))
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    return None


def _data(s: str | None):
    if not s:
        return None
    m = re.fullmatch(r"(\d{2})/(\d{2})/(\d{2}|\d{4})", s.strip())
    if not m:
        return None
    d, mth, y = map(int, m.groups())
    if y < 100:
        y += 2000
    try:
        return date(y, mth, d).isoformat()
    except ValueError:
        return None


def _colunas(cab):
    toks = sorted(cab, key=lambda c: c["x0"])
    juntos = []
    for c in toks:
        if juntos and (juntos[-1]["t"] + " " + c["t"]) in DUAS_PALAVRAS and c["x0"] - juntos[-1]["x1"] < 6:
            juntos[-1] = {**juntos[-1], "t": juntos[-1]["t"] + " " + c["t"], "x1": c["x1"]}
        else:
            juntos.append(dict(c))
    cols, i = [], 0
    for c in juntos:
        while i < len(HEADER_MAP) and HEADER_MAP[i][0] != c["t"]:
            i += 1
        if i == len(HEADER_MAP):
            break
        cols.append((HEADER_MAP[i][1], (c["x0"] + c["x1"]) / 2, c["x0"], c["x1"]))
        i += 1
    return cols


def ler(pdf) -> tuple[dict, list[dict]]:
    """pdf: caminho ou bytes. Retorna (meta, baias)."""
    if isinstance(pdf, (bytes, bytearray)):
        pdf = io.BytesIO(pdf)
    meta: dict = {}
    baias: list[dict] = []
    with pdfplumber.open(pdf) as doc:
        for p in doc.pages:
            txt = p.extract_text() or ""
            if "data_ref" not in meta:
                m = re.search(r"Data refer[êe]ncia:\s*(\d{2}/\d{2}/\d{4})", txt)
                if m:
                    meta["data_ref"] = _data(m.group(1))
                m = re.search(r"CONFINAMENTO\s+([^\n]+)", txt)
                if m:
                    meta["confinamento"] = m.group(1).strip()
            cl = _celulas(p.chars)
            h = [c for c in cl if c["t"] == "CURRAL"]
            if not h:
                continue
            hy = h[0]["y"]
            cols = _colunas([c for c in cl if abs(c["y"] - hy) < 2])
            if len(cols) < 20:
                raise RelatorioInvalido(f"cabeçalho não reconhecido na página {p.page_number}")
            stops = [c["y"] for c in cl if c["t"].startswith(("Lotes:", "IMS/PV%", "Ajuda"))]
            fim = min([y for y in stops if y > hy] or [p.height])
            corpo = sorted([c for c in cl if hy + 4 < c["y"] < fim - 2], key=lambda c: (c["y"], c["x0"]))
            x_lote = cols[1][2]
            inicios = sorted([c for c in corpo if c["x0"] < x_lote - 2 and re.fullmatch(r"[A-Z]+[-\s]?\d+[A-Z]?", c["t"])],
                             key=lambda c: c["y"])
            so_texto = [k for k in cols if k[0] in TEXTO]
            for i, s in enumerate(inicios):
                y1 = inicios[i + 1]["y"] - 3 if i + 1 < len(inicios) else fim
                row: dict = {"curral": s["t"]}
                for c in corpo:
                    if c is s or not (s["y"] - 3 <= c["y"] < y1):
                        continue
                    cx = (c["x0"] + c["x1"]) / 2
                    eh_num = _num(c["t"]) is not None or re.fullmatch(r"\d{2}/\d{2}/\d{2,4}", c["t"])
                    campo = min(cols if eh_num else so_texto, key=lambda k: abs(k[1] - cx))[0]
                    if campo == "curral" or campo in IGNORAR:
                        continue
                    if campo in TEXTO:
                        row[campo] = (row.get(campo, "") + " " + c["t"]).strip() if campo == "racao" else c["t"]
                    elif campo not in row:
                        v = _num(c["t"])
                        if v is not None:
                            row[campo] = int(v) if campo in INTEIROS else float(v)
                baias.append(row)
    if not meta.get("data_ref"):
        raise RelatorioInvalido("não encontrei a 'Data referência' – não parece o relatório TGC")
    if not baias:
        raise RelatorioInvalido("nenhuma baia encontrada no relatório")
    for b in baias:
        b["dt_entrada"] = _data(b.get("dt_entrada"))
        b["dt_abate"] = _data(b.get("dt_abate"))
        faltando = [k for k in OBRIGATORIOS if b.get(k) is None]
        if faltando:
            raise RelatorioInvalido(f"baia {b.get('curral')}: campos não lidos {faltando}")
    # mesma baia/lote repetida (ex.: quebra de página) -> mantém a primeira
    vistos, unicas = set(), []
    for b in baias:
        k = (b["curral"], b["lote"])
        if k not in vistos:
            vistos.add(k)
            unicas.append(b)
    meta["n_baias"] = len(unicas)
    meta["n_cab"] = sum(b["cab"] for b in unicas)
    return meta, unicas


if __name__ == "__main__":
    m, b = ler(sys.argv[1])
    print(json.dumps({"meta": m, "baias": b}, ensure_ascii=False, indent=1))
