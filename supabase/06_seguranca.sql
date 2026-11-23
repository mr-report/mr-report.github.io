-- Mr. Report – 06: reforço de segurança (rode uma vez no SQL Editor do Supabase; pode rodar de novo)
--  * login: depois de 10 senhas erradas em 15 min o mesmo endereço fica travado por 15 min; com 150 erradas
--    no total em 15 min, ninguém novo entra por 15 min (quem já está logado continua). Limpa sessões vencidas
--  * senhas: mínimo de 6 caracteres para a equipe e 8 para o administrador
--  * envio de PDF pelo app: limite de arquivos esperando leitura e por dia, para ninguém lotar o banco

-- ---------- tentativas de login ----------
create table if not exists public.login_falhas (
  quando timestamptz not null default now(),
  ip     text
);
create index if not exists login_falhas_quando on public.login_falhas(quando);
alter table public.login_falhas enable row level security;
revoke all on public.login_falhas from anon, authenticated;

create or replace function public._ip()
returns text language sql stable as $$
  -- endereço de quem chamou, como o Supabase repassa (cf-connecting-ip não pode ser falsificado pelo aparelho)
  select coalesce(
    nullif(current_setting('request.headers', true)::jsonb ->> 'cf-connecting-ip', ''),
    nullif(trim(split_part(coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', ''), ',', 1)), ''),
    'desconhecido');
$$;

-- Login. Senha errada agora volta como {"erro": ...} (e não como exceção) para a tentativa ficar registrada.
create or replace function public.entrar(p_senha text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare f record; tok text; v_ip text := public._ip();
begin
  delete from public.login_falhas where quando < now() - interval '1 day';
  delete from public.sessoes where expira_em < now();
  if (select count(*) from public.login_falhas where ip = v_ip and quando > now() - interval '15 minutes') >= 10
     or (select count(*) from public.login_falhas where quando > now() - interval '15 minutes') >= 150 then
    return jsonb_build_object('erro', 'muitas_tentativas');
  end if;
  if coalesce(p_senha, '') = '' or length(p_senha) > 200 then
    insert into public.login_falhas(ip) values (v_ip);
    return jsonb_build_object('erro', 'senha_invalida');
  end if;
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
  insert into public.login_falhas(ip) values (v_ip);
  perform pg_sleep(1);
  return jsonb_build_object('erro', 'senha_invalida');
end $$;

-- Senha do administrador: mínimo de 8 caracteres
create or replace function public.definir_senha_adm(p_senha text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if length(coalesce(p_senha, '')) < 8 then raise exception 'A senha do administrador precisa ter pelo menos 8 caracteres'; end if;
  insert into public.administrador(id, senha_hash) values (1, crypt(p_senha, gen_salt('bf')))
  on conflict (id) do update set senha_hash = excluded.senha_hash;
  delete from public.sessoes where fazenda_id is null;
end $$;

-- Cadastro de fazenda pelo app: senha da equipe com pelo menos 6 caracteres
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

  if coalesce(p_senha_equipe, '') <> '' and length(p_senha_equipe) < 6 then raise exception 'senha_curta' using errcode = 'P0001'; end if;
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

-- ---------- envio de PDF pelo app: limites ----------
create or replace function public.enviar_relatorio(p_token text, p_fazenda text, p_nome text, p_base64 text)
returns bigint language plpgsql security definer set search_path = public as $$
declare s public.sessoes; i bigint; b bytea;
begin
  s := public._sessao(p_token);
  if s.token is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  -- a equipe da fazenda envia só para a própria fazenda; o administrador, para qualquer uma
  if s.fazenda_id is not null and s.fazenda_id <> p_fazenda then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not exists (select 1 from public.fazendas where id = p_fazenda) then raise exception 'fazenda_inexistente' using errcode = 'P0001'; end if;
  if (select count(*) from public.uploads where fazenda_id = p_fazenda and status in ('pendente', 'lendo')) >= 40
     or (select count(*) from public.uploads where fazenda_id = p_fazenda and quando > now() - interval '1 day') >= 120 then
    raise exception 'limite_envios' using errcode = 'P0001'; end if;
  if length(p_base64) > 21 * 1024 * 1024 then raise exception 'arquivo_grande' using errcode = 'P0001'; end if;
  b := decode(p_base64, 'base64');
  if length(b) > 15 * 1024 * 1024 then raise exception 'arquivo_grande' using errcode = 'P0001'; end if;
  if substring(b from 1 for 4) <> '\x25504446'::bytea then raise exception 'nao_e_pdf' using errcode = 'P0001'; end if;   -- "%PDF"
  insert into public.uploads(fazenda_id, nome, conteudo) values (p_fazenda, left(p_nome, 200), b) returning id into i;
  insert into public.coleta_log(fazenda_id, status, detalhe) values (p_fazenda, 'pedido', 'relatório enviado pelo app: ' || left(p_nome, 200));
  return i;
end $$;

-- os PDFs já lidos não precisam ficar guardados (o robô passa a apagar; isto limpa os antigos)
update public.uploads set conteudo = null where status not in ('pendente', 'lendo') and conteudo is not null;

revoke execute on function public._ip() from public, anon, authenticated;
revoke execute on function public.entrar(text), public.definir_senha_adm(text),
  public.adm_salvar_fazenda(text, text, text, text, text, text, text, boolean, text),
  public.enviar_relatorio(text, text, text, text) from public, anon, authenticated;
grant execute on function public.entrar(text) to anon;
grant execute on function public.adm_salvar_fazenda(text, text, text, text, text, text, text, boolean, text) to anon;
grant execute on function public.enviar_relatorio(text, text, text, text) to anon;
notify pgrst, 'reload schema';
