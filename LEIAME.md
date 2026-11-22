# Mr. Report – análise diária de confinamento

Robô que lê o relatório diário do TGC (PDF por e-mail), grava num banco de dados e
alimenta um app de celular que funciona também sem internet.

```
E-mail da fazenda (Gmail)  ──►  Robô (GitHub Actions, 21:30)  ──►  Banco (Supabase)  ──►  App (GitHub Pages, celular)
```

| Pasta | O que tem |
|---|---|
| `coletor/` | `leitor_tgc.py` (lê o PDF) e `coletar.py` (busca no e-mail e grava no banco) |
| `supabase/` | `01_banco.sql` (tabelas e funções), `02_cadastrar_fazendas.sql` (senhas) e `03_botao_atualizar.sql` (botão Atualizar) |
| `app/` | o app (uma página + funcionamento offline) |
| `.github/workflows/` | agendamento da coleta, publicação do app e "manter ativo" |
| `testes/` | testes locais do robô |

Nenhum dado de fazenda e nenhuma senha ficam neste repositório. Os dados ficam no
Supabase, e as senhas ficam nos *Secrets* do GitHub e no banco (criptografadas).
O registro das execuções do robô (aba *Actions*) também é público, por isso mostra só a
situação, sem nomes, e-mails ou números. O detalhe completo fica no banco e aparece no app
para o administrador.

---

## Implantação (uma vez)

### 1. Gmail da fazenda
1. Crie um Gmail exclusivo, por exemplo `piloto.mr.report@gmail.com`.
2. Ative a **Verificação em duas etapas** (Conta Google → Segurança).
3. Crie uma **senha de app** em <https://myaccount.google.com/apppasswords>, com o nome `robo-cocho`.
   Guarde as 16 letras.
4. Faça o PDF diário do TGC chegar nesse endereço. Pode ser incluindo o endereço no envio,
   ou com encaminhamento automático a partir do e-mail que recebe hoje.
   Pode arquivar os e-mails, mas **não apague**: o robô lê também os arquivados.

### 2. Supabase (banco)
1. Crie o projeto `mr-report`, na região *South America (São Paulo)*. Guarde a senha do banco.
2. Abra **SQL Editor → New query**, cole todo o conteúdo de `supabase/01_banco.sql` e clique em **Run**.
3. Abra uma nova query com `supabase/02_cadastrar_fazendas.sql`, troque as senhas e clique em **Run**.
4. Anote três coisas:
   - **URL do projeto**: em Project Settings → Data API, no formato `https://xxxx.supabase.co`.
   - **Chave pública**: em Project Settings → API Keys, a chave *publishable* (`sb_publishable_...`) ou *anon*.
   - **Conexão do banco**: no botão **Connect** (topo da tela) → *Session pooler* → copie a URI
     e troque `[YOUR-PASSWORD]` pela senha do banco. O robô precisa do *Session pooler*,
     porque a conexão "direta" não funciona no GitHub.

### 3. GitHub
1. Crie o repositório **público** `Mr.Report`. Depois, no repositório, abra **Settings → Secrets and variables → Actions → New repository secret** e crie dois secrets:
   - `DATABASE_URL`: a URI do Session pooler, com a senha já colocada.
   - `FAZENDAS`: uma lista com o e-mail de cada fazenda, no formato abaixo.
     ```json
     [{"id": "grao-para", "email": "piloto.mr.report@gmail.com", "senha_app": "abcd efgh ijkl mnop", "remetente": ""}]
     ```
     O `id` precisa ser igual ao usado no passo 2.3. O campo `remetente` é opcional: se preenchido,
     o robô só aceita e-mails vindos desse endereço ou domínio.
2. Abra **Settings → Pages → Build and deployment → Source** e escolha **GitHub Actions**.
3. Edite `app/config.js` com a URL e a chave pública do passo 2.4. Essas duas podem ficar visíveis.
4. Abra **Actions → Coleta diária → Run workflow**. Em "dias", use `120` para importar o histórico
   que já está no e-mail. Depois de cerca de 1 minuto, deve aparecer ✅.
5. O app fica em `https://SEU-USUARIO.github.io/Mr.Report/`. No celular, abra o endereço e use
   "Adicionar à tela de início".

### 4. Botão "Atualizar" (faz o robô conferir o e-mail na hora)
Serve para quando o relatório chega fora do horário. O banco precisa de uma chave para
pedir ao GitHub que rode o robô.
1. No GitHub, abra sua foto → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**.
   - Nome: `mr-report-botao`. Em validade, escolha a mais longa disponível e anote a data para renovar.
   - Em *Repository access*, escolha **Only select repositories → Mr.Report**.
   - Em *Permissions → Repository permissions*, deixe **Actions: Read and write**. As outras ficam sem acesso.
   - Clique em **Generate token** e copie o token (começa com `github_pat_`).
2. No Supabase (SQL Editor), rode `supabase/03_botao_atualizar.sql` inteiro.
3. Ainda no SQL Editor, rode só as duas linhas de configuração do final desse arquivo, sem o `--` do começo,
   com o seu usuário do GitHub e o token.
   O token fica guardado criptografado no *Vault* do Supabase, nunca no app nem no repositório.
4. No app, toque em **Atualizar**. O robô roda em 1 a 3 minutos, e o app avisa se chegou relatório novo.
   Para evitar excesso, o banco aceita no máximo um pedido a cada 3 minutos. Quem tocar nesse
   intervalo apenas acompanha o pedido que já está em andamento.

---

## Rotina automática
- **21:30, 22:30 e 23:30**: o robô busca o PDF do dia. Ele só lê o e-mail, sem marcar como lido e sem apagar nada.
- **07:00**: última tentativa e conferência. Se faltar o relatório de ontem, a execução fica ❌ e o
  GitHub manda um e-mail para o dono do repositório.
- **Dia 1 de cada mês**: um passo grava só a data num arquivo, porque o GitHub desliga
  agendamentos de repositórios públicos sem atividade por 60 dias.
- Um relatório reenviado para o mesmo dia **substitui** o anterior, para correções.
  Um PDF que não é o relatório TGC é ignorado e aparece uma vez no registro.
- O administrador vê a situação da coleta no app, em **Cadastros → Coleta automática**,
  incluindo o horário da última execução do robô.
- Fora desses horários, qualquer usuário pode tocar em **Atualizar** no app para o robô conferir o e-mail na hora.

## Manutenção
- **Nova fazenda**: rode `definir_fazenda(...)` no Supabase e acrescente a fazenda no secret `FAZENDAS`.
- **Token do botão vencido**: o app mostra "Não consegui acionar o robô (GitHub 401)". Gere um token novo e rode
  `select vault.update_secret((select id from vault.secrets where name='github_token'), 'NOVO_TOKEN');`
- **Trocar senha**: rode `definir_fazenda(...)` ou `definir_senha_adm(...)` de novo. Quem estava logado com a senha antiga sai.
- **Importar um PDF solto** (no computador, com `DATABASE_URL` configurada):
  `python coletor/coletar.py --arquivo relatorio.pdf --fazenda grao-para`
- **Supabase gratuito**: o projeto é pausado após 7 dias sem atividade. A coleta diária grava no banco
  todos os dias, o que o mantém ativo.

## Testes locais
`testes/teste_coleta.py` simula uma caixa de e-mail com os PDFs de exemplo e confere a gravação,
a repetição, a senha errada, o reenvio corrigido e a conferência de relatório faltando.
