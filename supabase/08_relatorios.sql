-- Mr. Report – 08: aba "Relatórios" (PDFs originais)
-- Rode uma vez no SQL Editor do Supabase, depois do 07 (pode rodar de novo).
--
--  * Os últimos 30 dias de PDFs ficam no banco e abrem na hora.
--  * Os mais antigos ficam só no Gmail da fazenda: o botão "Buscar no e-mail" pede ao robô, que traz o PDF em 1 a 3 min.
--  * Os PDFs enviados pelo app são gravados pelo robô no Gmail da fazenda, na pasta "Mr Report".
--  * Todos com acesso à fazenda (inclusive a equipe) veem a aba.

do $$ begin
  if to_regprocedure('public._exige(text,text[],text)') is null then
    raise exception 'Rode antes o 07_pessoas.sql';
  end if;
end $$;

create table if not exists public.arquivos (
  id             bigserial primary key,
  fazenda_id     text not null references public.fazendas(id) on delete cascade,
  data_ref       date,
  nome           text not null,
  origem         text not null check (origem in ('email', 'app')),
  enviado_por    text,
  recebido_em    timestamptz not null default now(),
  sistema        text,
  tamanho        int,
  chave          text not null,          -- a mesma de relatorios.message_id (diz se é o PDF em uso naquele dia)
  email_id       text,                   -- Message-ID no Gmail (para buscar de volta)
  no_email       boolean not null default false,
  conteudo       bytea,                  -- o PDF; apagado depois de guardar_ate
  guardar_ate    timestamptz,
  pedido_status  text check (pedido_status in ('pendente', 'pronto', 'erro')),
  pedido_detalhe text,
  pedido_em      timestamptz,
  unique (fazenda_id, chave)
);
create index if not exists arquivos_faz_data on public.arquivos(fazenda_id, data_ref desc);
alter table public.arquivos enable row level security;
revoke all on public.arquivos from anon, authenticated;
alter table public.uploads add column if not exists enviado_por text;

-- relatórios já gravados antes desta versão: entram na lista (os do e-mail podem ser buscados no Gmail)
insert into public.arquivos(fazenda_id, data_ref, nome, origem, recebido_em, sistema, chave, email_id, no_email)
select r.fazenda_id, r.data_ref, coalesce(r.arquivo, 'relatorio.pdf'),
       case when r.message_id like 'upload:%' or r.message_id like 'arquivo:%' then 'app' else 'email' end,
       r.processado_em, r.sistema, r.message_id,
       case when r.message_id like 'upload:%' or r.message_id like 'arquivo:%' then null
            else regexp_replace(r.message_id, '#[^#]*$', '') end,
       not (r.message_id like 'upload:%' or r.message_id like 'arquivo:%')
from public.relatorios r
where r.message_id is not null
on conflict (fazenda_id, chave) do nothing;

-- ---------- lista, baixar e pedir ao robô ----------
create or replace function public.listar_arquivos(p_token text, p_fazenda text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._exige(p_token, array['adm', 'tecnico', 'leitor'], p_fazenda);
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', a.id, 'data_ref', a.data_ref, 'nome', a.nome, 'origem', a.origem, 'enviado_por', a.enviado_por,
            'recebido_em', a.recebido_em, 'sistema', a.sistema, 'tamanho', a.tamanho,
            'disponivel', a.conteudo is not null, 'no_email', a.no_email, 'guardar_ate', a.guardar_ate,
            'pedido_status', a.pedido_status, 'pedido_detalhe', a.pedido_detalhe,
            'em_uso', exists (select 1 from public.relatorios r where r.fazenda_id = a.fazenda_id and r.data_ref = a.data_ref and r.message_id = a.chave)
          ) order by a.data_ref desc nulls last, a.recebido_em desc), '[]')
          from (select * from public.arquivos where fazenda_id = p_fazenda order by data_ref desc nulls last, recebido_em desc limit 400) a);
end $$;

create or replace function public.baixar_arquivo(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes; a public.arquivos;
begin
  s := public._exige(p_token, array['adm', 'tecnico', 'leitor']);
  select * into a from public.arquivos where id = p_id;
  if a.id is null or not public._acessa(s, a.fazenda_id) then raise exception 'arquivo_inexistente' using errcode = 'P0001'; end if;
  if a.conteudo is null then raise exception 'arquivo_fora_do_banco' using errcode = 'P0001'; end if;
  return jsonb_build_object('nome', a.nome, 'base64', encode(a.conteudo, 'base64'));
end $$;

create or replace function public.pedir_arquivo(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes; a public.arquivos;
begin
  s := public._exige(p_token, array['adm', 'tecnico', 'leitor']);
  select * into a from public.arquivos where id = p_id;
  if a.id is null or not public._acessa(s, a.fazenda_id) then raise exception 'arquivo_inexistente' using errcode = 'P0001'; end if;
  if a.conteudo is not null then return jsonb_build_object('status', 'pronto'); end if;
  if not a.no_email then raise exception 'arquivo_sem_email' using errcode = 'P0001'; end if;
  if a.pedido_status = 'pendente' and a.pedido_em > now() - interval '15 minutes' then return jsonb_build_object('status', 'pendente'); end if;
  if (select count(*) from public.arquivos where fazenda_id = a.fazenda_id and pedido_status = 'pendente') >= 15 then
    raise exception 'limite_pedidos' using errcode = 'P0001'; end if;
  update public.arquivos set pedido_status = 'pendente', pedido_detalhe = null, pedido_em = now() where id = a.id;
  return jsonb_build_object('status', 'pendente');
end $$;

create or replace function public.situacao_arquivo(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes;
begin
  s := public._exige(p_token, array['adm', 'tecnico', 'leitor']);
  return (select jsonb_build_object('status', pedido_status, 'detalhe', pedido_detalhe, 'disponivel', conteudo is not null)
          from public.arquivos where id = p_id and public._acessa(s, fazenda_id));
end $$;

-- envio pelo app: agora guarda quem enviou (vai junto para o arquivo)
create or replace function public.enviar_relatorio(p_token text, p_fazenda text, p_nome text, p_base64 text)
returns bigint language plpgsql security definer set search_path = public as $$
declare s public.sessoes; i bigint; b bytea;
begin
  s := public._exige(p_token, array['adm', 'tecnico', 'leitor'], p_fazenda);
  if not exists (select 1 from public.fazendas where id = p_fazenda) then raise exception 'fazenda_inexistente' using errcode = 'P0001'; end if;
  if (select count(*) from public.uploads where fazenda_id = p_fazenda and status in ('pendente', 'lendo')) >= 40
     or (select count(*) from public.uploads where fazenda_id = p_fazenda and quando > now() - interval '1 day') >= 120 then
    raise exception 'limite_envios' using errcode = 'P0001'; end if;
  if length(p_base64) > 21 * 1024 * 1024 then raise exception 'arquivo_grande' using errcode = 'P0001'; end if;
  b := decode(p_base64, 'base64');
  if length(b) > 15 * 1024 * 1024 then raise exception 'arquivo_grande' using errcode = 'P0001'; end if;
  if substring(b from 1 for 4) <> '\x25504446'::bytea then raise exception 'nao_e_pdf' using errcode = 'P0001'; end if;   -- "%PDF"
  insert into public.uploads(fazenda_id, nome, conteudo, enviado_por) values (p_fazenda, left(p_nome, 200), b, public._autor(s)) returning id into i;
  insert into public.coleta_log(fazenda_id, status, detalhe)
  values (p_fazenda, 'pedido', 'relatório enviado pelo app por ' || public._autor(s) || ': ' || left(p_nome, 200));
  return i;
end $$;

revoke execute on function public.listar_arquivos(text, text), public.baixar_arquivo(text, bigint),
  public.pedir_arquivo(text, bigint), public.situacao_arquivo(text, bigint),
  public.enviar_relatorio(text, text, text, text) from public, anon, authenticated;
grant execute on function public.listar_arquivos(text, text), public.baixar_arquivo(text, bigint),
  public.pedir_arquivo(text, bigint), public.situacao_arquivo(text, bigint),
  public.enviar_relatorio(text, text, text, text) to anon;
notify pgrst, 'reload schema';
