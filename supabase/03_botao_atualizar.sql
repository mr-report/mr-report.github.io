-- =====================================================================
-- Botão "Atualizar" do app: faz o robô conferir o e-mail na hora.
-- Rode DEPOIS do 01_banco.sql, no "SQL Editor" do Supabase.
-- Antes, siga as instruções do LEIAME (criar o token do GitHub) e
-- troque os dois textos marcados com TROQUE no final deste arquivo.
-- =====================================================================

-- pg_net: permite ao banco chamar o GitHub. Já vem disponível no Supabase.
do $$ begin
  create extension if not exists pg_net;
exception when others then raise notice 'pg_net indisponível neste banco: %', sqlerrm;
end $$;

create table if not exists public.parametros (
  chave  text primary key,
  valor  text not null
);
create table if not exists public.pedidos_coleta (
  id          bigserial primary key,
  quando      timestamptz not null default now(),
  fazenda_id  text,            -- null = administrador
  request_id  bigint           -- id da chamada ao GitHub (pg_net)
);
alter table public.parametros     enable row level security;
alter table public.pedidos_coleta enable row level security;
revoke all on public.parametros, public.pedidos_coleta from anon, authenticated;

-- Pede ao GitHub para rodar a coleta agora (no máximo uma vez a cada 3 minutos)
create or replace function public.pedir_coleta(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessoes; ult timestamptz; tok text; repo text; rid bigint; q timestamptz;
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  select quando into ult from public.pedidos_coleta order by quando desc limit 1;
  if ult is not null and ult > now() - interval '3 minutes' then
    return jsonb_build_object('pedido_em', ult, 'repetido', true);   -- alguém acabou de pedir: só acompanha
  end if;
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'github_token';
  select valor into repo from public.parametros where chave = 'github_repo';
  if tok is null or repo is null then raise exception 'botao_nao_configurado' using errcode = 'P0001'; end if;
  rid := net.http_post(
    url     := 'https://api.github.com/repos/' || repo || '/actions/workflows/coleta.yml/dispatches',
    body    := '{"ref":"main","inputs":{"dias":"3"}}'::jsonb,
    headers := jsonb_build_object('Authorization', 'Bearer ' || tok, 'Accept', 'application/vnd.github+json',
                                 'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'mr-report', 'Content-Type', 'application/json'));
  insert into public.pedidos_coleta(fazenda_id, request_id) values (s.fazenda_id, rid) returning quando into q;
  insert into public.coleta_log(fazenda_id, status, detalhe) values (s.fazenda_id, 'pedido', 'coleta pedida pelo botão Atualizar');
  return jsonb_build_object('pedido_em', q, 'repetido', false);
end $$;

-- Acompanha o pedido: o GitHub aceitou? o robô já terminou a rodada?
create or replace function public.situacao_pedido(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes; p public.pedidos_coleta; st int; er text;
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  select * into p from public.pedidos_coleta order by quando desc limit 1;
  begin
    select status_code, coalesce(error_msg, case when timed_out then 'tempo esgotado' end)
      into st, er from net._http_response where id = p.request_id;
  exception when others then st := null; er := null;
  end;
  return jsonb_build_object(
    'pedido_em', p.quando,
    'github_status', st,          -- 204 = GitHub aceitou; null = ainda enviando
    'github_erro', er,
    'ultima_rodada', (select max(quando) from public.coleta_log where status = 'rodada'));
end $$;

revoke execute on function public.pedir_coleta(text), public.situacao_pedido(text) from public, anon, authenticated;
grant execute on function public.pedir_coleta(text)    to anon;
grant execute on function public.situacao_pedido(text) to anon;

-- =====================================================================
-- CONFIGURAÇÃO – troque os dois valores e rode só estas linhas.
-- (Para trocar o token depois: select vault.update_secret(
--    (select id from vault.secrets where name = 'github_token'), 'NOVO_TOKEN');)
-- =====================================================================
-- insert into public.parametros(chave, valor) values ('github_repo', 'TROQUE-PELO-USUARIO/Mr.Report')
--   on conflict (chave) do update set valor = excluded.valor;
-- select vault.create_secret('TROQUE-PELO-TOKEN-DO-GITHUB', 'github_token');
