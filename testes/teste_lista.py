"""Robô lendo as fazendas do banco (Vault) + secret FAZENDAS como complemento."""
import os, sys, json
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "coletor"))
import coletar, psycopg
conn = psycopg.connect(os.environ["DATABASE_URL"])
os.environ["FAZENDAS"] = json.dumps([{"id":"grao-para","email":"antigo@gmail.com","senha_app":"velha"},{"id":"so-secret","email":"s@gmail.com","senha_app":"x"}])
l = coletar.lista_fazendas(conn)
print([(f["id"], f["email"], f["senha_app"]) for f in l])
assert [f["id"] for f in l] == ["santa-rita","grao-para","so-secret"] or sorted(f["id"] for f in l)==["grao-para","santa-rita","so-secret"]
assert next(f for f in l if f["id"]=="grao-para")["email"] == "piloto.mr.report@gmail.com"   # o do app vence
os.environ["FAZENDAS"] = ""
print([f["id"] for f in coletar.lista_fazendas(conn)]); print("OK")
