"""Escolhe o leitor certo para cada relatório e padroniza o resultado.

Sistemas: "tgc" (TGC), "feedmanager" (Feed Manager) e "farmtell" (FarmTell).
Cada leitor devolve (meta, baias) no mesmo formato; meta sempre traz "sistema" e
"janela_media" (quantos dias tem a média curta: 5 no TGC, 3 no Feed Manager).
"""
from __future__ import annotations

import io
import signal
from datetime import date, timedelta

import pdfplumber

import leitor_farmtell
import leitor_feedmanager
import leitor_tgc

NOMES = {"tgc": "TGC", "feedmanager": "Feed Manager", "farmtell": "FarmTell"}


class RelatorioInvalido(Exception):
    pass


class SistemaErrado(Exception):
    pass


def detectar(conteudo: bytes) -> str | None:
    """Reconhece o sistema pela 'assinatura' da primeira página."""
    try:
        with pdfplumber.open(io.BytesIO(conteudo)) as doc:
            txt = (doc.pages[0].extract_text() or "") if doc.pages else ""
    except Exception:
        return None
    if "Data refer" in txt and "CURRAL" in txt:
        return "tgc"
    if "Controle de Lotes Ativos" in txt and "Posição em" in txt:
        return "feedmanager"
    if "LOTES ATIVOS" in txt and "Dia Anterior" in txt and "Escore" in txt:
        return "farmtell"
    return None


MAX_BYTES = 15 * 1024 * 1024
MAX_PAGINAS = 60
MAX_SEGUNDOS = 90


class _Demorou(Exception):
    pass


def _limite_tempo(signum, frame):
    raise _Demorou()


def ler(conteudo: bytes, sistema_esperado: str | None = None) -> tuple[dict, list[dict]]:
    """Lê o PDF com limites de tamanho, páginas e tempo (um arquivo estranho não trava o robô)."""
    if len(conteudo) > MAX_BYTES:
        raise RelatorioInvalido("arquivo maior que 15 MB")
    usa_alarme = hasattr(signal, "SIGALRM")
    if usa_alarme:
        anterior = signal.signal(signal.SIGALRM, _limite_tempo)
        signal.alarm(MAX_SEGUNDOS)
    try:
        return _ler(conteudo, sistema_esperado)
    except _Demorou:
        raise RelatorioInvalido(f"a leitura passou de {MAX_SEGUNDOS} s – o arquivo não parece um relatório normal") from None
    finally:
        if usa_alarme:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, anterior)


def _ler(conteudo: bytes, sistema_esperado: str | None) -> tuple[dict, list[dict]]:
    try:
        with pdfplumber.open(io.BytesIO(conteudo)) as doc:
            n = len(doc.pages)
    except Exception:
        raise RelatorioInvalido("não consegui abrir o PDF (arquivo corrompido ou protegido)") from None
    if n == 0 or n > MAX_PAGINAS:
        raise RelatorioInvalido(f"o PDF tem {n} páginas – um relatório diário tem até {MAX_PAGINAS}")
    sist = detectar(conteudo)
    if sist is None:
        raise RelatorioInvalido("não é um relatório reconhecido (TGC, Feed Manager ou FarmTell)")
    if sistema_esperado and sist != sistema_esperado:
        raise SistemaErrado(f"o arquivo é um relatório do {NOMES[sist]}, mas a fazenda está cadastrada como "
                            f"{NOMES.get(sistema_esperado, sistema_esperado)}. Confira o cadastro ou o arquivo.")
    try:
        if sist == "tgc":
            meta, baias = leitor_tgc.ler(conteudo)
            meta.update(sistema="tgc", janela_media=5)
        elif sist == "feedmanager":
            meta, baias = leitor_feedmanager.ler(conteudo)
        else:
            meta, baias = leitor_farmtell.ler(conteudo)
    except (leitor_tgc.RelatorioInvalido, leitor_feedmanager.RelatorioInvalido, leitor_farmtell.RelatorioInvalido) as e:
        raise RelatorioInvalido(str(e)) from None
    # data do relatório: não aceita datas no futuro nem muito antigas (arquivo errado ou adulterado)
    dref = date.fromisoformat(meta["data_ref"])
    if dref > date.today() + timedelta(days=2) or dref < date(2020, 1, 1):
        raise RelatorioInvalido(f"data do relatório fora do esperado ({dref.strftime('%d/%m/%Y')})")
    if len(baias) > 2000:
        raise RelatorioInvalido("relatório com baias demais – não parece um relatório normal")
    for b in baias:                       # lote pode ter letras (Feed Manager): guarda sempre como texto
        b["lote"] = str(b["lote"]) if b.get("lote") is not None else None
    return meta, baias
