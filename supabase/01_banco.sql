-- =====================================================================
-- Cocho – banco de dados (Supabase / PostgreSQL)
-- Rode este arquivo inteiro uma vez no "SQL Editor" do Supabase.
-- Pode rodar de novo sem perder dados (tudo é "if not exists"/"or replace").
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- tabelas ----------
create table if not exists public.fazendas (
  id          text primary key,                 -- ex.: 'fernanda' (sem espaços/acentos)
  nome        text not null,                    -- ex.: 'Confinamento Fernanda'
  senha_hash  text not null,                    -- senha de consulta (bcrypt)
  ativa       boolean not null default true,
  criado_em   timestamptz not null default now()
);

create table if not exists public.administrador (
  id          int primary key default 1 check (id = 1),
  senha_hash  text not null
);

create table if not exists public.relatorios (
  fazenda_id    text not null references public.fazendas(id) on delete cascade,
  data_ref      date not null,
  confinamento  text,                           -- nome que vem no PDF
  arquivo       text,                           -- nome do PDF
  message_id    text,                           -- id do e-mail de origem
  n_baias       int,
  n_cab         int,
  processado_em timestamptz not null default now(),
  primary key (fazenda_id, data_ref)
);

create table if not exists public.baias_dia (
  fazenda_id      text not null,
  data_ref        date not null,
  curral          text not null,
  lote            int  not null,
  cab             int,
  ct              text,
  sub_contrato    text,
  dt_entrada      date,
  dias_conf       int,
  ms_5d           numeric, mn_5d numeric,
  ms_1d           numeric, mn_1d numeric,
  ms_med          numeric, mn_med numeric,
  racao           text,
  racao_dias      int,
  racao_tipo_dias int,
  peso_entrada    numeric,
  peso_atual_prj  numeric,
  ims_pv_5d       numeric, ims_pv_1d numeric, ims_pv_med numeric,
  cons_dia_mn     numeric, cons_dia_ms numeric, cons_dia_pv numeric,
  dt_abate        date,
  cocho_d1        numeric, cocho_d2 numeric, cocho_d3 numeric,
  primary key (fazenda_id, data_ref, curral, lote),
  foreign key (fazenda_id, data_ref) references public.relatorios(fazenda_id, data_ref) on delete cascade
);
create index if not exists baias_dia_lote on public.baias_dia (fazenda_id, lote, data_ref);

create table if not exists public.config (
  fazenda_id     text primary key references public.fazendas(id) on delete cascade,
  dados          jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now()
);

create table if not exists public.sessoes (
  token       text primary key,
  fazenda_id  text references public.fazendas(id) on delete cascade,  -- null = administrador
  criado_em   timestamptz not null default now(),
  expira_em   timestamptz not null default now() + interval '180 days'
);

create table if not exists public.coleta_log (
  id          bigserial primary key,
  quando      timestamptz not null default now(),
  fazenda_id  text,
  status      text not null,     -- ok | ignorado | erro | faltando
  detalhe     text,
  ref         text               -- id do e-mail/anexo (evita repetir o mesmo aviso)
);
alter table public.coleta_log add column if not exists ref text;
create index if not exists coleta_log_ref on public.coleta_log (ref);

-- ---------- segurança: ninguém de fora lê as tabelas diretamente ----------
alter table public.fazendas      enable row level security;
alter table public.administrador enable row level security;
alter table public.relatorios    enable row level security;
alter table public.baias_dia     enable row level security;
alter table public.config        enable row level security;
alter table public.sessoes       enable row level security;
alter table public.coleta_log    enable row level security;
revoke all on all tables in schema public from anon, authenticated;

-- ---------- funções internas ----------
create or replace function public._sessao(p_token text)
returns public.sessoes language sql stable security definer set search_path = public as $$
  select * from public.sessoes where token = p_token and expira_em > now();
$$;

-- ---------- funções chamadas pelo app ----------

-- Login: devolve um token e o papel (fazenda ou administrador)
create or replace function public.entrar(p_senha text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare f record; tok text;
begin
  if exists (select 1 from public.administrador a where a.senha_hash = crypt(p_senha, a.senha_hash)) then
    tok := encode(gen_random_bytes(24), 'hex');
    insert into public.sessoes(token, fazenda_id) values (tok, null);
    return jsonb_build_object('token', tok, 'papel', 'adm',
      'fazendas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome), '[]') from public.fazendas where ativa));
  end if;
  select * into f from public.fazendas where ativa and senha_hash = crypt(p_senha, senha_hash) limit 1;
  if found then
    tok := encode(gen_random_bytes(24), 'hex');
    insert into public.sessoes(token, fazenda_id) values (tok, f.id);
    return jsonb_build_object('token', tok, 'papel', 'fazenda',
      'fazendas', jsonb_build_array(jsonb_build_object('id', f.id, 'nome', f.nome)));
  end if;
  perform pg_sleep(1);                     -- freia tentativas de adivinhar senha
  raise exception 'senha_invalida' using errcode = '28P01';
end $$;

-- Dados de uma fazenda a partir de uma data (para baixar só o que é novo)
create or replace function public.dados(p_token text, p_fazenda text, p_desde date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes;
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  if s.fazenda_id is not null and s.fazenda_id <> p_fazenda then raise exception 'sem_permissao' using errcode = '42501'; end if;
  return jsonb_build_object(
    'fazenda', (select jsonb_build_object('id', id, 'nome', nome) from public.fazendas where id = p_fazenda),
    'gerado_em', now(),
    'relatorios', (select coalesce(jsonb_agg(jsonb_build_object('data_ref', data_ref, 'n_baias', n_baias, 'n_cab', n_cab, 'processado_em', processado_em) order by data_ref), '[]')
                   from public.relatorios where fazenda_id = p_fazenda and (p_desde is null or data_ref >= p_desde)),
    'baias', (select coalesce(jsonb_agg(to_jsonb(b) - 'fazenda_id' order by b.data_ref, b.curral), '[]')
              from public.baias_dia b where b.fazenda_id = p_fazenda and (p_desde is null or b.data_ref >= p_desde)),
    'config', (select dados from public.config where fazenda_id = p_fazenda),
    'config_atualizado_em', (select atualizado_em from public.config where fazenda_id = p_fazenda)
  );
end $$;

-- Cadastros (curva, escore, categorias, limites) – só o administrador grava
create or replace function public.salvar_config(p_token text, p_fazenda text, p_dados jsonb)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare s public.sessoes; t timestamptz := now();
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  if s.fazenda_id is not null then raise exception 'sem_permissao' using errcode = '42501'; end if;
  insert into public.config(fazenda_id, dados, atualizado_em) values (p_fazenda, p_dados, t)
  on conflict (fazenda_id) do update set dados = excluded.dados, atualizado_em = t;
  return t;
end $$;

-- Situação da coleta (para o administrador ver se o robô está rodando)
create or replace function public.status_coleta(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes;
begin
  s := public._sessao(p_token);
  if s.token is null or s.fazenda_id is not null then raise exception 'sem_permissao' using errcode = '42501'; end if;
  return jsonb_build_object(
    'ultimos_relatorios', (select coalesce(jsonb_agg(x), '[]') from (
        select f.id fazenda, f.nome, max(r.data_ref) ultimo, max(r.processado_em) processado_em, count(r.*) total
        from public.fazendas f left join public.relatorios r on r.fazenda_id = f.id group by f.id, f.nome order by f.nome) x),
    'ultima_rodada', (select max(quando) from public.coleta_log where status = 'rodada'),
    'log', (select coalesce(jsonb_agg(l order by l.quando desc), '[]') from
            (select * from public.coleta_log where status <> 'rodada' order by quando desc limit 30) l)
  );
end $$;

create or replace function public.sair(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from public.sessoes where token = p_token;
$$;

-- ---------- funções de manutenção (rodar no SQL Editor) ----------

-- Cadastrar ou alterar uma fazenda e sua senha de consulta
create or replace function public.definir_fazenda(p_id text, p_nome text, p_senha text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into public.fazendas(id, nome, senha_hash) values (p_id, p_nome, crypt(p_senha, gen_salt('bf')))
  on conflict (id) do update set nome = excluded.nome, senha_hash = excluded.senha_hash;
  delete from public.sessoes where fazenda_id = p_id;        -- troca de senha derruba quem estava logado
end $$;

-- Definir a senha do administrador
create or replace function public.definir_senha_adm(p_senha text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into public.administrador(id, senha_hash) values (1, crypt(p_senha, gen_salt('bf')))
  on conflict (id) do update set senha_hash = excluded.senha_hash;
  delete from public.sessoes where fazenda_id is null;
end $$;

-- ---------- permissões das funções ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.entrar(text)                   to anon;
grant execute on function public.dados(text, text, date)        to anon;
grant execute on function public.salvar_config(text, text, jsonb) to anon;
grant execute on function public.status_coleta(text)            to anon;
grant execute on function public.sair(text)                     to anon;
