-- =====================================================================
-- Cadastro de fazendas pelo próprio app (área do administrador).
-- Rode DEPOIS do 01 e do 03, uma vez, no "SQL Editor" do Supabase.
-- A senha de app do Gmail de cada fazenda fica no Vault (cofre
-- criptografado do Supabase). O app só grava; nunca lê de volta.
-- =====================================================================

alter table public.fazendas add column if not exists email     text;
alter table public.fazendas add column if not exists remetente text;

-- Lista para a tela "Fazendas" do administrador (sem senhas)
create or replace function public.adm_listar_fazendas(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes;
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  if s.fazenda_id is not null then raise exception 'sem_permissao' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', f.id, 'nome', f.nome, 'ativa', f.ativa, 'email', f.email, 'remetente', f.remetente,
            'tem_senha_app', exists (select 1 from vault.decrypted_secrets v where v.name = 'imap:' || f.id),
            'ultimo_relatorio', (select max(r.data_ref) from public.relatorios r where r.fazenda_id = f.id),
            'ultimo_evento', (select jsonb_build_object('quando', l.quando, 'status', l.status, 'detalhe', l.detalhe)
                              from public.coleta_log l where l.fazenda_id = f.id and l.status in ('ok','erro','faltando')
                              order by l.quando desc limit 1)
          ) order by f.nome), '[]'::jsonb) from public.fazendas f);
end $$;

-- Cria ou altera uma fazenda. Campos de senha vazios = manter a atual.
create or replace function public.adm_salvar_fazenda(
  p_token text, p_id text, p_nome text, p_senha_equipe text, p_email text,
  p_senha_app text, p_remetente text default null, p_ativa boolean default true)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessoes; existe boolean; sec uuid; app text;
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  if s.fazenda_id is not null then raise exception 'sem_permissao' using errcode = '42501'; end if;

  p_id := lower(trim(p_id));
  if p_id !~ '^[a-z0-9][a-z0-9-]{1,39}$' then raise exception 'codigo_invalido' using errcode = 'P0001'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'nome_obrigatorio' using errcode = 'P0001'; end if;
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
    insert into public.fazendas(id, nome, senha_hash, email, remetente, ativa)
    values (p_id, trim(p_nome), crypt(p_senha_equipe, gen_salt('bf')), nullif(trim(p_email), ''), nullif(trim(p_remetente), ''), coalesce(p_ativa, true));
  else
    update public.fazendas set nome = trim(p_nome), email = nullif(trim(p_email), ''),
      remetente = nullif(trim(p_remetente), ''), ativa = coalesce(p_ativa, true) where id = p_id;
    if coalesce(p_senha_equipe, '') <> '' then
      if exists (select 1 from public.fazendas f where f.id <> p_id and f.senha_hash = crypt(p_senha_equipe, f.senha_hash))
         or exists (select 1 from public.administrador a where a.senha_hash = crypt(p_senha_equipe, a.senha_hash)) then
        raise exception 'senha_repetida' using errcode = 'P0001'; end if;
      update public.fazendas set senha_hash = crypt(p_senha_equipe, gen_salt('bf')) where id = p_id;
      delete from public.sessoes where fazenda_id = p_id;          -- quem usava a senha antiga sai
    end if;
  end if;

  if app <> '' then
    select id into sec from vault.secrets where name = 'imap:' || p_id;
    if sec is null then perform vault.create_secret(app, 'imap:' || p_id, 'senha de app do Gmail – ' || p_id);
    else perform vault.update_secret(sec, app); end if;
  end if;
  return jsonb_build_object('id', p_id, 'criada', existe is null);
end $$;

-- Lista que o ROBÔ usa (com a senha de app). Só o dono do banco executa.
create or replace function public.robo_fazendas()
returns table (id text, email text, senha_app text, remetente text)
language sql security definer set search_path = public as $$
  select f.id, f.email, v.decrypted_secret, f.remetente
  from public.fazendas f join vault.decrypted_secrets v on v.name = 'imap:' || f.id
  where f.ativa and f.email is not null;
$$;

revoke execute on function public.adm_listar_fazendas(text) from public, anon, authenticated;
revoke execute on function public.adm_salvar_fazenda(text, text, text, text, text, text, text, boolean) from public, anon, authenticated;
revoke execute on function public.robo_fazendas() from public, anon, authenticated;
grant execute on function public.adm_listar_fazendas(text) to anon;
grant execute on function public.adm_salvar_fazenda(text, text, text, text, text, text, text, boolean) to anon;
