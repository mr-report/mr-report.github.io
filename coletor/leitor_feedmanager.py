"""Leitor do relatório Feed Manager "Controle de Lotes Ativos".

Colunas (por baia): Lote, Curral, Raça, Categoria, Tipo de Entrada, Qtde Anm, Morte,
Data Entrada, Dias Pré-Conf, Dias Conf, Dias Trato, Peso Entr, Cons Médio (MO MS %PV),
Cons ult 1 dia (MO MS %PV), Cons ult 3 dia (MO MS %PV), Dieta Atual,
Dias de Dieta (Atual Adap Term Recr Cres), Peso Abate Prev, Peso Estim Hoje,
GPD Ajust, Data Estim Abate.

- As colunas de texto (lote, curral, raça, categoria, tipo) são separadas pela posição
  dos títulos no cabeçalho de cada página; a parte numérica, por uma expressão regular.
- "MO" (matéria original) = MN.
- Baias sem trato no dia (consumo do último dia = 0 e sem dieta) não entram.

Uso:  python leitor_feedmanager.py relatorio.pdf   -> imprime JSON
"""
from __future__ import annotations

import io
import json
import re
import sys
from datetime import date

import pdfplumber

SISTEMA = "feedmanager"
JANELA_MEDIA = 3          # o relatório traz a média dos últimos 3 dias


class RelatorioInvalido(Exception):
    pass


NUM = r"-?[\d.]*\d,\d+|-?\d+"
CAUDA = re.compile(
    rf"^(?P<qtde>\d+)\s+(?P<morte>\d+)\s+(?P<dt_entrada>\d{{2}}/\d{{2}}/\d{{2,4}})\s+(?P<pre>\d+)\s+(?P<conf>\d+)\s+(?P<trato>\d+)\s+"
    rf"(?P<peso>{NUM})\s+"
    rf"(?P<med_mo>{NUM})\s+(?P<med_ms>{NUM})\s+(?P<med_pv>{NUM})\s+"
    rf"(?P<d1_mo>{NUM})\s+(?P<d1_ms>{NUM})\s+(?P<d1_pv>{NUM})\s+"
    rf"(?P<d3_mo>{NUM})\s+(?P<d3_ms>{NUM})\s+(?P<d3_pv>{NUM})\s*"
    rf"(?P<dieta>.*?)\s*"
    rf"(?P<d_atual>\d+)\s+(?P<d_adap>\d+)\s+(?P<d_term>\d+)\s+(?P<d_recr>\d+)\s+(?P<d_cres>\d+)\s+"
    rf"(?P<p_abate>{NUM})\s+(?P<p_hoje>{NUM})(?:\s+(?P<gpd>{NUM}))?(?:\s+(?P<dt_abate>\d{{2}}/\d{{2}}/\d{{2,4}}))?\s*$")
CURRAL = re.compile(r"^[A-ZÀ-Ú]{1,5}-?\d+[A-Z]?$")


def _num(s):
    if s is None or s == "":
        return None
    s = s.strip()
    if "," in s:
        return float(s.replace(".", "").replace(",", "."))
    return int(s)


def _data(s):
    if not s:
        return None
    m = re.fullmatch(r"(\d{2})/(\d{2})/(\d{2}|\d{4})", s.strip())
    if not m:
        return None
    d, mth, y = map(int, m.groups())
    y += 2000 if y < 100 else 0
    try:
        return date(y, mth, d).isoformat()
    except ValueError:
        return None


def _linhas(page):
    """Agrupa as palavras da página em linhas (pela altura)."""
    ws = sorted(page.extract_words(x_tolerance=1.5, keep_blank_chars=False), key=lambda w: (round(w["top"]), w["x0"]))
    linhas, atual, topo = [], [], None
    for w in ws:
        if topo is None or abs(w["top"] - topo) > 2.5:
            if atual:
                linhas.append(sorted(atual, key=lambda w: w["x0"]))
            atual, topo = [w], w["top"]
        else:
            atual.append(w)
    if atual:
        linhas.append(sorted(atual, key=lambda w: w["x0"]))
    return linhas


def ler(pdf) -> tuple[dict, list[dict]]:
    if isinstance(pdf, (bytes, bytearray)):
        pdf = io.BytesIO(pdf)
    meta: dict = {"sistema": SISTEMA, "janela_media": JANELA_MEDIA}
    baias: list[dict] = []
    sem_trato = 0
    with pdfplumber.open(pdf) as doc:
        for p in doc.pages:
            txt = p.extract_text() or ""
            if "data_ref" not in meta:
                m = re.search(r"Posição em\s*(\d{2}/\d{2}/\d{4})", txt)
                if m:
                    meta["data_ref"] = _data(m.group(1))
            linhas = _linhas(p)
            # cabeçalho da página: posições das colunas de texto
            cab = next((l for l in linhas if [w["text"] for w in l[:2]] == ["Lote", "Curral"]), None)
            if not cab:
                continue
            pos = {}
            for w in cab:
                if w["text"] in ("Curral", "Raça", "Categoria", "Tipo", "Qtde") and w["text"] not in pos:
                    pos[w["text"]] = w["x0"]
            if len(pos) < 5:
                raise RelatorioInvalido(f"cabeçalho do Feed Manager não reconhecido na página {p.page_number}")
            y_cab = cab[0]["top"]
            setor = None
            for l in linhas:
                if l[0]["top"] <= y_cab + 20:
                    continue
                texto = " ".join(w["text"] for w in l)
                if texto.startswith("Linha:"):
                    setor = texto.split(":", 1)[1].strip()
                    continue
                if texto.startswith(("Resumo do Confinamento", "Page ", "Piquetes")):
                    break
                def col(a, b):
                    return " ".join(w["text"] for w in l if a - 3 <= w["x0"] < b - 3).strip()
                curral = col(pos["Curral"], pos["Raça"])
                if not CURRAL.match(curral):
                    continue
                cauda = " ".join(w["text"] for w in l if w["x0"] >= pos["Qtde"] - 3)
                m = CAUDA.match(cauda)
                if not m:
                    raise RelatorioInvalido(f"linha do curral {curral} fora do formato esperado")
                g = m.groupdict()
                d1_ms = _num(g["d1_ms"])
                dieta = (g["dieta"] or "").strip()
                if not d1_ms and not dieta:
                    sem_trato += 1
                    continue
                baias.append({
                    "curral": curral, "lote": col(0, pos["Curral"]), "setor": setor,
                    "raca": col(pos["Raça"], pos["Categoria"]) or None, "ct": col(pos["Categoria"], pos["Tipo"]) or None,
                    "cab": int(g["qtde"]), "mortes": int(g["morte"]), "dt_entrada": _data(g["dt_entrada"]),
                    "dias_conf": int(g["conf"]), "dias_trato": int(g["trato"]), "peso_entrada": _num(g["peso"]),
                    "mn_med": _num(g["med_mo"]), "ms_med": _num(g["med_ms"]), "ims_pv_med": _num(g["med_pv"]),
                    "cons_dia_mn": _num(g["d1_mo"]), "cons_dia_ms": d1_ms, "cons_dia_pv": _num(g["d1_pv"]),
                    # média curta: aqui são 3 dias (no TGC, 5); vai nas mesmas colunas, com a janela no relatório
                    "mn_5d": _num(g["d3_mo"]), "ms_5d": _num(g["d3_ms"]), "ims_pv_5d": _num(g["d3_pv"]),
                    "racao": dieta or None, "racao_dias": int(g["d_atual"]),
                    "peso_abate_prev": _num(g["p_abate"]), "peso_atual_prj": _num(g["p_hoje"]), "gpd": _num(g["gpd"]),
                    "dt_abate": _data(g["dt_abate"]),
                })
    if not meta.get("data_ref"):
        raise RelatorioInvalido("não encontrei a data 'Posição em' – não parece o relatório do Feed Manager")
    if not baias:
        raise RelatorioInvalido("nenhuma baia encontrada no relatório")
    vistos, unicas = set(), []
    for b in baias:
        k = (b["curral"], b["lote"])
        if k not in vistos:
            vistos.add(k)
            unicas.append(b)
    meta.update(n_baias=len(unicas), n_cab=sum(b["cab"] for b in unicas), sem_trato=sem_trato)
    return meta, unicas


if __name__ == "__main__":
    m, b = ler(sys.argv[1])
    print(json.dumps({"meta": m, "baias": b}, ensure_ascii=False, indent=1))
