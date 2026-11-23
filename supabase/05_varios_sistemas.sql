-- =====================================================================
-- Vários sistemas de relatório (TGC, Feed Manager, FarmTell) e envio
-- manual de PDF pelo app. Rode DEPOIS do 01, 03 e 04, uma vez, no
-- "SQL Editor" do Supabase. Pode rodar de novo sem perder dados.
-- =====================================================================

-- ---------- qual sistema gera o relatório de cada fazenda ----------
alter table public.fazendas add column if not exists sistema text not null default 'tgc';
alter table public.fazendas drop constraint if exists fazendas_sistema_chk;
alter table public.fazendas add constraint fazendas_sistema_chk check (sistema in ('tgc', 'feedmanager', 'farmtell'));

-- ---------- de onde veio cada relatório e qual a janela da "média curta" ----------
alter table public.relatorios add column if not exists sistema      text not null default 'tgc';
alter table public.relatorios add column if not exists janela_media int  not null default 5;   -- TGC 5 dias; Feed Manager e FarmTell 3
alter table public.relatorios add column if not exists n_sem_trato  int;

-- ---------- baias: lote com letras e campos que só alguns sistemas trazem ----------
alter table public.baias_dia alter column lote type text using lote::text;
alter table public.baias_dia add column if not exists setor           text;     -- "Linha" no Feed Manager
alter table public.baias_dia add column if not exists raca            text;
alter table public.baias_dia add column if not exists mortes          int;
alter table public.baias_dia add column if not exists dias_trato      int;
alter table public.baias_dia add column if not exists peso_abate_prev numeric;
alter table public.baias_dia add column if not exists gpd             numeric;

-- ---------- PDFs enviados pelo app (o robô processa na próxima rodada) ----------
create table if not exists public.uploads (
  id            bigserial primary key,
  quando        timestamptz not null default now(),
  fazenda_id    text not null references public.fazendas(id) on delete cascade,
  nome          text,
  conteudo      bytea,
  status        text not null default 'pendente',   -- pendente | ok | erro
  detalhe       text,
  data_ref      date,
  processado_em timestamptz
);
alter table public.uploads enable row level security;
revoke all on public.uploads from anon, authenticated;

-- ---------- funções do app ----------
create or replace function public.dados(p_token text, p_fazenda text, p_desde date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes;
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  if s.fazenda_id is not null and s.fazenda_id <> p_fazenda then raise exception 'sem_permissao' using errcode = '42501'; end if;
  return jsonb_build_object(
    'fazenda', (select jsonb_build_object('id', id, 'nome', nome, 'sistema', sistema) from public.fazendas where id = p_fazenda),
    'gerado_em', now(),
    'relatorios', (select coalesce(jsonb_agg(jsonb_build_object('data_ref', data_ref, 'n_baias', n_baias, 'n_cab', n_cab, 'processado_em', processado_em,
                                                                'sistema', sistema, 'janela_media', janela_media) order by data_ref), '[]')
                   from public.relatorios where fazenda_id = p_fazenda and (p_desde is null or data_ref >= p_desde)),
    'baias', (select coalesce(jsonb_agg(to_jsonb(b) - 'fazenda_id' order by b.data_ref, b.curral), '[]')
              from public.baias_dia b where b.fazenda_id = p_fazenda and (p_desde is null or b.data_ref >= p_desde)),
    'config', (select dados from public.config where fazenda_id = p_fazenda),
    'config_atualizado_em', (select atualizado_em from public.config where fazenda_id = p_fazenda)
  );
end $$;

create or replace function public.adm_listar_fazendas(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes;
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  if s.fazenda_id is not null then raise exception 'sem_permissao' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', f.id, 'nome', f.nome, 'ativa', f.ativa, 'email', f.email, 'remetente', f.remetente, 'sistema', f.sistema,
            'tem_senha_app', exists (select 1 from vault.decrypted_secrets v where v.name = 'imap:' || f.id),
            'ultimo_relatorio', (select max(r.data_ref) from public.relatorios r where r.fazenda_id = f.id),
            'ultimo_evento', (select jsonb_build_object('quando', l.quando, 'status', l.status, 'detalhe', l.detalhe)
                              from public.coleta_log l where l.fazenda_id = f.id and l.status in ('ok','erro','faltando')
                              order by l.quando desc limit 1)
          ) order by f.nome), '[]'::jsonb) from public.fazendas f);
end $$;

drop function if exists public.adm_salvar_fazenda(text, text, text, text, text, text, text, boolean);
create or replace function public.adm_salvar_fazenda(
  p_token text, p_id text, p_nome text, p_senha_equipe text, p_email text,
  p_senha_app text, p_remetente text default null, p_ativa boolean default true, p_sistema text default 'tgc')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessoes; existe boolean; sec uuid; app text;
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  if s.fazenda_id is not null then raise exception 'sem_permissao' using errcode = '42501'; end if;

  p_id := lower(trim(p_id));
  if p_id !~ '^[a-z0-9][a-z0-9-]{1,39}$' then raise exception 'codigo_invalido' using errcode = 'P0001'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'nome_obrigatorio' using errcode = 'P0001'; end if;
  if coalesce(p_sistema, 'tgc') not in ('tgc', 'feedmanager', 'farmtell') then raise exception 'sistema_invalido' using errcode = 'P0001'; end if;
  if coalesce(trim(p_email), '') <> '' and trim(p_email) !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'email_invalido' using errcode = 'P0001'; end if;
  app := lower(regexp_replace(coalesce(p_senha_app, ''), '\s', '', 'g'));
  if app <> '' and app !~ '^[a-z]{16}$' then raise exception 'senha_app_invalida' using errcode = 'P0001'; end if;

  select true into existe from public.fazendas where id = p_id;
  if existe is null then
    if coalesce(p_senha_equipe, '') = '' then raise exception 'senha_equipe_obrigatoria' using errcode = 'P0001'; end if;
    if exists (select 1 from public.fazendas f where f.senha_hash = crypt(p_senha_equipe, f.senha_hash))
       or exists (select 1 from public.administrador a where a.senha_hash = crypt(p_senha_equipe, a.senha_hash)) then
      raise exception 'senha_repetida' using errcode = 'P0001'; end if;
    insert into public.fazendas(id, nome, senha_hash, email, remetente, ativa, sistema)
    values (p_id, trim(p_nome), crypt(p_senha_equipe, gen_salt('bf')), nullif(trim(p_email), ''), nullif(trim(p_remetente), ''),
            coalesce(p_ativa, true), coalesce(p_sistema, 'tgc'));
  else
    update public.fazendas set nome = trim(p_nome), email = nullif(trim(p_email), ''), remetente = nullif(trim(p_remetente), ''),
      ativa = coalesce(p_ativa, true), sistema = coalesce(p_sistema, sistema) where id = p_id;
    if coalesce(p_senha_equipe, '') <> '' then
      if exists (select 1 from public.fazendas f where f.id <> p_id and f.senha_hash = crypt(p_senha_equipe, f.senha_hash))
         or exists (select 1 from public.administrador a where a.senha_hash = crypt(p_senha_equipe, a.senha_hash)) then
        raise exception 'senha_repetida' using errcode = 'P0001'; end if;
      update public.fazendas set senha_hash = crypt(p_senha_equipe, gen_salt('bf')) where id = p_id;
      delete from public.sessoes where fazenda_id = p_id;
    end if;
  end if;

  if app <> '' then
    select id into sec from vault.secrets where name = 'imap:' || p_id;
    if sec is null then perform vault.create_secret(app, 'imap:' || p_id, 'senha de app do Gmail – ' || p_id);
    else perform vault.update_secret(sec, app); end if;
  end if;
  return jsonb_build_object('id', p_id, 'criada', existe is null);
end $$;

drop function if exists public.robo_fazendas();
create or replace function public.robo_fazendas()
returns table (id text, email text, senha_app text, remetente text, sistema text)
language sql security definer set search_path = public as $$
  select f.id, f.email, v.decrypted_secret, f.remetente, f.sistema
  from public.fazendas f join vault.decrypted_secrets v on v.name = 'imap:' || f.id
  where f.ativa and f.email is not null;
$$;

-- Envio manual de relatório (PDF em base64). Só o administrador.
create or replace function public.enviar_relatorio(p_token text, p_fazenda text, p_nome text, p_base64 text)
returns bigint language plpgsql security definer set search_path = public as $$
declare s public.sessoes; i bigint; b bytea;
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  if s.fazenda_id is not null then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not exists (select 1 from public.fazendas where id = p_fazenda) then raise exception 'fazenda_inexistente' using errcode = 'P0001'; end if;
  b := decode(p_base64, 'base64');
  if length(b) > 15 * 1024 * 1024 then raise exception 'arquivo_grande' using errcode = 'P0001'; end if;
  if substring(b from 1 for 4) <> '\x25504446'::bytea then raise exception 'nao_e_pdf' using errcode = 'P0001'; end if;   -- "%PDF"
  insert into public.uploads(fazenda_id, nome, conteudo) values (p_fazenda, left(p_nome, 200), b) returning id into i;
  insert into public.coleta_log(fazenda_id, status, detalhe) values (p_fazenda, 'pedido', 'relatório enviado pelo app: ' || left(p_nome, 200));
  return i;
end $$;

create or replace function public.situacao_upload(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes;
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  if s.fazenda_id is not null then raise exception 'sem_permissao' using errcode = '42501'; end if;
  return (select jsonb_build_object('status', status, 'detalhe', detalhe, 'data_ref', data_ref, 'processado_em', processado_em)
          from public.uploads where id = p_id);
end $$;

revoke execute on function public.adm_salvar_fazenda(text, text, text, text, text, text, text, boolean, text) from public, anon, authenticated;
revoke execute on function public.robo_fazendas() from public, anon, authenticated;
revoke execute on function public.enviar_relatorio(text, text, text, text), public.situacao_upload(text, bigint) from public, anon, authenticated;
grant execute on function public.adm_salvar_fazenda(text, text, text, text, text, text, text, boolean, text) to anon;
grant execute on function public.enviar_relatorio(text, text, text, text) to anon;
grant execute on function public.situacao_upload(text, bigint) to anon;
grant execute on function public.dados(text, text, date) to anon;
grant execute on function public.adm_listar_fazendas(text) to anon;
notify pgrst, 'reload schema';
