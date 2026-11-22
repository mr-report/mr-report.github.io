"""Robô de coleta: lê o e-mail de cada fazenda, extrai o relatório TGC em PDF
e grava no banco (Supabase/PostgreSQL).

Variáveis de ambiente (ficam nos "Secrets" do GitHub, nunca no código):
  DATABASE_URL  – conexão do Supabase (Connect → Session pooler)
  FAZENDAS      – JSON com o e-mail de cada fazenda, ex.:
                  [{"id": "fernanda", "email": "cocho.fernanda@gmail.com",
                    "senha_app": "abcd efgh ijkl mnop", "remetente": ""}]
                  "remetente" é opcional: só aceita e-mails desse endereço/domínio.

Uso:
  python coletar.py                 # coleta dos últimos 3 dias (rodada normal)
  python coletar.py --dias 120      # carga do histórico que já está no e-mail
  python coletar.py --verificar     # só confere se o relatório de ontem chegou;
                                    # termina com erro (e o GitHub avisa por e-mail) se faltar
  python coletar.py --arquivo X.pdf --fazenda fernanda   # importa um PDF solto
"""
from __future__ import annotations

import argparse
import email
import email.policy
import imaplib
import json
import os
import re
import sys
from datetime import date, datetime, timedelta
from email.header import decode_header, make_header
from zoneinfo import ZoneInfo

import psycopg

from leitor_tgc import RelatorioInvalido, ler

TZ = ZoneInfo("America/Sao_Paulo")
COLUNAS = ["curral", "lote", "cab", "ct", "sub_contrato", "dt_entrada", "dias_conf",
           "ms_5d", "mn_5d", "ms_1d", "mn_1d", "ms_med", "mn_med",
           "racao", "racao_dias", "racao_tipo_dias", "peso_entrada", "peso_atual_prj",
           "ims_pv_5d", "ims_pv_1d", "ims_pv_med", "cons_dia_mn", "cons_dia_ms", "cons_dia_pv",
           "dt_abate", "cocho_d1", "cocho_d2", "cocho_d3"]


def hoje() -> date:
    return datetime.now(TZ).date()


# O registro de execução do GitHub é público em repositório público: na tela só aparece
# a situação, sem nomes, e-mails ou números. O detalhe completo vai só para o banco
# (o administrador vê no app, em Cadastros → Coleta automática).
_PUBLICO = os.environ.get("LOG_DETALHADO") != "1"


def log(conn, fazenda, status, detalhe, ref=None):
    print(f"[{status.upper():8}] " + ("(detalhes no app)" if _PUBLICO else f"{fazenda or '-'}: {detalhe}"), flush=True)
    with conn.cursor() as cur:
        cur.execute("insert into public.coleta_log(fazenda_id, status, detalhe, ref) values (%s,%s,%s,%s)",
                    (fazenda, status, detalhe[:2000], ref))
    conn.commit()


def ja_ignorado(conn, ref) -> bool:
    with conn.cursor() as cur:
        cur.execute("select 1 from public.coleta_log where ref=%s and status in ('ignorado','erro') limit 1", (ref,))
        return cur.fetchone() is not None


# ---------------------------------------------------------------- banco
def gravar(conn, fazenda_id: str, meta: dict, baias: list[dict], arquivo: str, message_id: str | None) -> str:
    """Grava (ou substitui) o relatório do dia. Retorna 'novo', 'atualizado' ou 'repetido'."""
    with conn.transaction(), conn.cursor() as cur:
        cur.execute("select message_id from public.relatorios where fazenda_id=%s and data_ref=%s for update",
                    (fazenda_id, meta["data_ref"]))
        atual = cur.fetchone()
        if atual and message_id and atual[0] == message_id:
            return "repetido"
        cur.execute("""
            insert into public.relatorios(fazenda_id, data_ref, confinamento, arquivo, message_id, n_baias, n_cab, processado_em)
            values (%s,%s,%s,%s,%s,%s,%s, now())
            on conflict (fazenda_id, data_ref) do update set confinamento=excluded.confinamento, arquivo=excluded.arquivo,
              message_id=excluded.message_id, n_baias=excluded.n_baias, n_cab=excluded.n_cab, processado_em=now()""",
                    (fazenda_id, meta["data_ref"], meta.get("confinamento"), arquivo, message_id,
                     meta["n_baias"], meta["n_cab"]))
        cur.execute("delete from public.baias_dia where fazenda_id=%s and data_ref=%s", (fazenda_id, meta["data_ref"]))
        cols = ["fazenda_id", "data_ref"] + COLUNAS
        sql = f"insert into public.baias_dia({','.join(cols)}) values ({','.join(['%s'] * len(cols))})"
        cur.executemany(sql, [[fazenda_id, meta["data_ref"]] + [b.get(c) for c in COLUNAS] for b in baias])
    return "atualizado" if atual else "novo"


def fazendas_cadastradas(conn) -> dict:
    with conn.cursor() as cur:
        cur.execute("select id, nome from public.fazendas where ativa")
        return dict(cur.fetchall())


# ---------------------------------------------------------------- e-mail
def _texto(h):
    try:
        return str(make_header(decode_header(h or "")))
    except Exception:
        return h or ""


def _pasta_todos(imap) -> str:
    """Usa a pasta 'Todos os e-mails' do Gmail (pega até e-mail arquivado); senão INBOX."""
    typ, pastas = imap.list()
    for linha in pastas or []:
        s = linha.decode(errors="ignore")
        if "\\All" in s:
            m = re.search(r'"([^"]+)"\s*$', s) or re.search(r"(\S+)\s*$", s)
            if m:
                return '"' + m.group(1) + '"'
    return "INBOX"


def pdfs_do_email(f: dict, desde: date):
    """Gera (message_id, nome_arquivo, bytes, remetente, assunto) dos PDFs recebidos desde a data."""
    imap = imaplib.IMAP4_SSL(f.get("servidor", "imap.gmail.com"), 993)
    imap.login(f["email"], f["senha_app"].replace(" ", ""))
    try:
        imap.select(_pasta_todos(imap), readonly=True)   # só leitura: não marca nada como lido
        typ, data = imap.uid("search", None, "SINCE", desde.strftime("%d-%b-%Y"))
        uids = data[0].split() if data and data[0] else []
        for uid in uids:
            typ, msg_data = imap.uid("fetch", uid, "(RFC822)")
            if not msg_data or not isinstance(msg_data[0], tuple):
                continue
            msg = email.message_from_bytes(msg_data[0][1], policy=email.policy.default)
            remetente = _texto(msg.get("From"))
            if f.get("remetente") and f["remetente"].lower() not in remetente.lower():
                continue
            mid = (msg.get("Message-ID") or f"uid-{uid.decode()}").strip()
            for parte in msg.walk():
                nome = parte.get_filename() or ""
                tipo = parte.get_content_type()
                if tipo == "application/pdf" or nome.lower().endswith(".pdf"):
                    conteudo = parte.get_payload(decode=True)
                    if conteudo:
                        yield f"{mid}#{nome}", _texto(nome) or "relatorio.pdf", conteudo, remetente, _texto(msg.get("Subject"))
    finally:
        try:
            imap.logout()
        except Exception:
            pass


# ---------------------------------------------------------------- rotinas
def coletar(conn, fazendas: list[dict], dias: int) -> int:
    cadastradas = fazendas_cadastradas(conn)
    desde = hoje() - timedelta(days=dias)
    erros = 0
    for f in fazendas:
        fid = f["id"]
        if fid not in cadastradas:
            log(conn, fid, "erro", "fazenda não cadastrada no banco (rode definir_fazenda no Supabase)")
            erros += 1
            continue
        try:
            n = {"novo": 0, "atualizado": 0, "repetido": 0, "ignorado": 0}
            for mid, nome, conteudo, remetente, assunto in pdfs_do_email(f, desde):
                if ja_ignorado(conn, mid):      # PDF que não é relatório: avisa uma vez só
                    n["ignorado"] += 1
                    continue
                try:
                    meta, baias = ler(conteudo)
                except RelatorioInvalido as e:
                    n["ignorado"] += 1
                    log(conn, fid, "ignorado", f"PDF '{nome}' de {remetente} não é um relatório válido: {e}", ref=mid)
                    continue
                except Exception as e:  # PDF corrompido etc.
                    n["ignorado"] += 1
                    log(conn, fid, "erro", f"falha ao ler '{nome}': {type(e).__name__}: {e}", ref=mid)
                    continue
                r = gravar(conn, fid, meta, baias, nome, mid)
                n[r] += 1
                if r != "repetido":
                    log(conn, fid, "ok", f"relatório de {meta['data_ref']} ({r}): {meta['n_baias']} baias, "
                                         f"{meta['n_cab']} cab – '{nome}'")
            print(f"fazenda {fazendas.index(f) + 1}: {n}" if _PUBLICO else f"{fid}: {n}")
        except imaplib.IMAP4.error as e:
            erros += 1
            log(conn, fid, "erro", f"não consegui entrar no e-mail {f.get('email')}: {e}. Confira a senha de app.")
        except Exception as e:
            erros += 1
            log(conn, fid, "erro", f"{type(e).__name__}: {e}")
    return erros


def verificar(conn, fazendas: list[dict]) -> int:
    """Confere se cada fazenda tem relatório de ontem ou de hoje."""
    faltando = 0
    limite = hoje() - timedelta(days=1)
    with conn.cursor() as cur:
        for f in fazendas:
            cur.execute("select max(data_ref) from public.relatorios where fazenda_id=%s", (f["id"],))
            ultimo = cur.fetchone()[0]
            if ultimo is None or ultimo < limite:
                faltando += 1
                log(conn, f["id"], "faltando", f"sem relatório de {limite.strftime('%d/%m')} (último: "
                                               f"{ultimo.strftime('%d/%m/%Y') if ultimo else 'nenhum'})")
            else:
                print("relatório em dia" if _PUBLICO else f"{f['id']}: último relatório {ultimo}")
    return faltando


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dias", type=int, default=3)
    ap.add_argument("--verificar", action="store_true")
    ap.add_argument("--arquivo")
    ap.add_argument("--fazenda")
    a = ap.parse_args()

    url = os.environ.get("DATABASE_URL")
    if not url:
        sys.exit("Falta a variável DATABASE_URL")
    with psycopg.connect(url, connect_timeout=20, prepare_threshold=None) as conn:
        if a.arquivo:
            with open(a.arquivo, "rb") as fh:
                meta, baias = ler(fh.read())
            r = gravar(conn, a.fazenda, meta, baias, os.path.basename(a.arquivo), f"arquivo:{os.path.basename(a.arquivo)}")
            log(conn, a.fazenda, "ok", f"importado manualmente {meta['data_ref']} ({r}): {meta['n_baias']} baias")
            return
        try:
            fazendas = json.loads(os.environ.get("FAZENDAS") or "[]")
        except json.JSONDecodeError as e:
            sys.exit(f"O secret FAZENDAS não é um JSON válido: {e}")
        if not fazendas:
            sys.exit("O secret FAZENDAS está vazio")
        if a.verificar:
            sys.exit(1 if verificar(conn, fazendas) else 0)
        erros = coletar(conn, fazendas, a.dias)
        # marca o fim da rodada: o botão "Atualizar" do app espera por este registro
        log(conn, None, "rodada", f"fim da rodada ({erros} erro(s))")
        sys.exit(1 if erros else 0)


if __name__ == "__main__":
    main()
