"""Teste do robô com uma caixa de e-mail simulada (sem internet)."""
import imaplib, json, os, sys, io
from email.message import EmailMessage
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "coletor"))
import coletar

# PDFs de exemplo (não versionados): defina PDF_FERNANDA e PDF_SAO_MARCELO
PDFS = {"fernanda": os.environ.get("PDF_FERNANDA", "/mnt/user-data/uploads/238df531-C.Z_16-11-26.pdf"),
        "sao-marcelo": os.environ.get("PDF_SAO_MARCELO", "/mnt/user-data/uploads/5e48d03f-TGS106.pdf")}

def msg(mid, para, pdf_path=None, nome="r.pdf", bytes_=None, remetente="tgc@fazenda.com.br"):
    m = EmailMessage(); m["From"]=remetente; m["To"]=para; m["Subject"]="Relatório diário"; m["Message-ID"]=mid
    m.set_content("segue relatório")
    data = bytes_ if bytes_ is not None else open(pdf_path,"rb").read()
    m.add_attachment(data, maintype="application", subtype="pdf", filename=nome)
    return m.as_bytes()

CAIXAS = {}
class FakeIMAP:
    def __init__(self, host, port): self.user=None
    def login(self, u, p):
        if p != "senhaapp": raise imaplib.IMAP4.error("[AUTHENTICATIONFAILED] Invalid credentials")
        self.user=u
    def list(self): return "OK", [b'(\\HasNoChildren) "/" "INBOX"', b'(\\All \\HasNoChildren) "/" "[Gmail]/Todos os e-mails"']
    def select(self, pasta, readonly=False): assert readonly; return "OK", [b"1"]
    def uid(self, cmd, *args):
        box = CAIXAS.get(self.user, [])
        if cmd == "search": return "OK", [" ".join(str(i+1) for i in range(len(box))).encode()]
        if cmd == "fetch": i=int(args[0])-1; return "OK", [(b"1 (RFC822)", box[i]), b")"]
    def logout(self): pass

imaplib.IMAP4_SSL = FakeIMAP
import psycopg
conn = psycopg.connect(os.environ["DATABASE_URL"])
with conn.cursor() as c:
    c.execute("delete from relatorios; delete from coleta_log;")
    c.execute("select definir_fazenda('fernanda','Confinamento Fernanda','fernanda'); select definir_fazenda('sao-marcelo','Confinamento São Marcelo','marcelo'); select definir_senha_adm('admin');")
conn.commit()

# PDF que não é relatório (simula um boleto)
from reportlab.pdfgen import canvas
_c = canvas.Canvas("/tmp/nao_tgc.pdf"); _c.drawString(100, 750, "Boleto bancario 123"); _c.save()
CAIXAS["fer@gmail.com"] = [msg("<a1>", "fer@gmail.com", PDFS["fernanda"], "C.Z_16-11-26.pdf"),
                           msg("<a2>", "fer@gmail.com", bytes_=open("/tmp/nao_tgc.pdf","rb").read(), nome="boleto.pdf")]
CAIXAS["sm@gmail.com"]  = [msg("<b1>", "sm@gmail.com", PDFS["sao-marcelo"], "TGS106.pdf")]
FAZ = [{"id":"fernanda","email":"fer@gmail.com","senha_app":"senha app"},
       {"id":"sao-marcelo","email":"sm@gmail.com","senha_app":"senhaapp"},
       {"id":"nova","email":"x@gmail.com","senha_app":"senhaapp"}]

print("== 1ª rodada"); e1 = coletar.coletar(conn, FAZ, 3)
print("== 2ª rodada (deve ser tudo repetido)"); e2 = coletar.coletar(conn, FAZ[:2], 3)
print("== senha errada"); e3 = coletar.coletar(conn, [{"id":"fernanda","email":"fer@gmail.com","senha_app":"errada"}], 3)
print("== reenvio corrigido do mesmo dia"); CAIXAS["sm@gmail.com"].append(msg("<b2>", "sm@gmail.com", PDFS["sao-marcelo"], "TGS106_v2.pdf"))
e4 = coletar.coletar(conn, FAZ[1:2], 3)
print("== verificar"); v = coletar.verificar(conn, FAZ[:2])
with conn.cursor() as c:
    c.execute("select fazenda_id, data_ref, n_baias, n_cab, arquivo from relatorios order by 1"); print(c.fetchall())
    c.execute("select fazenda_id, count(*), sum(cab) from baias_dia group by 1 order by 1"); print(c.fetchall())
print("erros:", e1, e2, e3, e4, "faltando:", v)
assert (e1, e2, e3, e4) == (1, 0, 1, 0)
print("OK")
