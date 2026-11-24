-- Mr. Report – 07: pessoas com nome (administradores e técnicos), acesso por fazenda e histórico dos cadastros
-- Rode uma vez no SQL Editor do Supabase (pode rodar de novo). Depois, rode a linha do final com SEU nome e usuário.
--
--  * Administrador: todas as fazendas; Cadastros, Fazendas, Pessoas; restaura versões dos cadastros.
--  * Técnico: só as fazendas marcadas; Cadastros dessas fazendas e Comparativo entre elas.
--  * Leitor: entra com a senha da fazenda (como antes): Vistoria, Análise, Baias, Inserir PDF e Atualizar.
--  * Cada salvamento dos Cadastros guarda quem salvou e quando (histórico com as versões anteriores).

-- ---------- tabelas ----------
create table if not exists public.pessoas (
  id         serial primary key,
  nome       text not null,
  usuario    text not null unique check (usuario ~ '^[a-z0-9]+(\.[a-z0-9]+)+$'),
  senha_hash text not null,
  papel      text not null check (papel in ('adm', 'tecnico')),
  ativa      boolean not null default true,
  criado_em  timestamptz not null default now()
);
create table if not exists public.pessoa_fazendas (
  pessoa_id  int  not null references public.pessoas(id) on delete cascade,
  fazenda_id text not null references public.fazendas(id) on delete cascade,
  primary key (pessoa_id, fazenda_id)
);
alter table public.sessoes add column if not exists pessoa_id int references public.pessoas(id) on delete cascade;
alter table public.config add column if not exists atualizado_por text;
create table if not exists public.config_hist (
  id         bigserial primary key,
  fazenda_id text not null references public.fazendas(id) on delete cascade,
  quando     timestamptz not null default now(),
  autor      text not null,
  acao       text not null default 'salvou',
  dados      jsonb not null
);
create index if not exists config_hist_faz on public.config_hist(fazenda_id, quando desc);
alter table public.pessoas enable row level security;
alter table public.pessoa_fazendas enable row level security;
alter table public.config_hist enable row level security;
revoke all on public.pessoas, public.pessoa_fazendas, public.config_hist from anon, authenticated;

-- ---------- vindos do 06 (repetidos aqui para o 07 funcionar mesmo sem ele) ----------
create table if not exists public.login_falhas (quando timestamptz not null default now(), ip text);
create index if not exists login_falhas_quando on public.login_falhas(quando);
alter table public.login_falhas enable row level security;
revoke all on public.login_falhas from anon, authenticated;
create or replace function public._ip()
returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.headers', true)::jsonb ->> 'cf-connecting-ip', ''),
    nullif(trim(split_part(coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', ''), ',', 1)), ''),
    'desconhecido');
$$;
create or replace function public.definir_senha_adm(p_senha text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if length(coalesce(p_senha, '')) < 8 then raise exception 'A senha do administrador precisa ter pelo menos 8 caracteres'; end if;
  insert into public.administrador(id, senha_hash) values (1, crypt(p_senha, gen_salt('bf')))
  on conflict (id) do update set senha_hash = excluded.senha_hash;
  delete from public.sessoes where fazenda_id is null and pessoa_id is null;
end $$;

-- ---------- quem é a sessão ----------
-- papel: 'adm' | 'tecnico' | 'leitor' (senha da fazenda) | null (pessoa desativada)
create or replace function public._papel(s public.sessoes)
returns text language sql stable set search_path = public as $$
  select case when s.token is null then null
              when s.fazenda_id is not null then 'leitor'
              when s.pessoa_id is null then 'adm'                       -- senha antiga de administrador
              else (select papel from public.pessoas where id = s.pessoa_id and ativa) end;
$$;
create or replace function public._acessa(s public.sessoes, p_fazenda text)
returns boolean language sql stable set search_path = public as $$
  select case public._papel(s)
           when 'adm' then true
           when 'leitor' then s.fazenda_id = p_fazenda
           when 'tecnico' then exists (select 1 from public.pessoa_fazendas where pessoa_id = s.pessoa_id and fazenda_id = p_fazenda)
           else false end;
$$;
create or replace function public._autor(s public.sessoes)
returns text language sql stable set search_path = public as $$
  select case when s.fazenda_id is not null then 'equipe da ' || coalesce((select nome from public.fazendas where id = s.fazenda_id), s.fazenda_id)
              when s.pessoa_id is null then 'Administrador'
              else (select nome from public.pessoas where id = s.pessoa_id) end;
$$;
create or replace function public._exige(p_token text, p_papeis text[], p_fazenda text default null)
returns public.sessoes language plpgsql stable set search_path = public as $$
declare s public.sessoes;
begin
  s := public._sessao(p_token);
  if s.token is null or public._papel(s) is null then raise exception 'sessao_expirada' using errcode = '28000'; end if;
  if not (public._papel(s) = any(p_papeis)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_fazenda is not null and not public._acessa(s, p_fazenda) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  return s;
end $$;

-- lista de fazendas que a pessoa enxerga
create or replace function public._fazendas_de(p_pessoa int, p_papel text)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'nome', f.nome) order by f.nome), '[]')
  from public.fazendas f
  where f.ativa and (p_papel = 'adm' or exists (select 1 from public.pessoa_fazendas pf where pf.pessoa_id = p_pessoa and pf.fazenda_id = f.id));
$$;

-- ---------- login ----------
-- Senha da fazenda (leitor). A senha antiga de administrador só vale enquanto não houver pessoa administradora.
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
  if not exists (select 1 from public.pessoas where papel = 'adm' and ativa)
     and exists (select 1 from public.administrador a where a.senha_hash = crypt(p_senha, a.senha_hash)) then
    tok := encode(gen_random_bytes(24), 'hex');
    insert into public.sessoes(token, fazenda_id) values (tok, null);
    return jsonb_build_object('token', tok, 'papel', 'adm', 'nome', 'Administrador', 'fazendas', public._fazendas_de(null, 'adm'));
  end if;
  select * into f from public.fazendas where ativa and senha_hash = crypt(p_senha, senha_hash) limit 1;
  if found then
    tok := encode(gen_random_bytes(24), 'hex');
    insert into public.sessoes(token, fazenda_id) values (tok, f.id);
    return jsonb_build_object('token', tok, 'papel', 'leitor', 'nome', null,
      'fazendas', jsonb_build_array(jsonb_build_object('id', f.id, 'nome', f.nome)));
  end if;
  insert into public.login_falhas(ip) values (v_ip);
  perform pg_sleep(1);
  return jsonb_build_object('erro', 'senha_invalida');
end $$;

-- Usuário (nome.sobrenome) + senha própria: administradores e técnicos
create or replace function public.entrar_usuario(p_usuario text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare p public.pessoas; tok text; v_ip text := public._ip();
begin
  delete from public.login_falhas where quando < now() - interval '1 day';
  if (select count(*) from public.login_falhas where ip = v_ip and quando > now() - interval '15 minutes') >= 10
     or (select count(*) from public.login_falhas where quando > now() - interval '15 minutes') >= 150 then
    return jsonb_build_object('erro', 'muitas_tentativas');
  end if;
  select * into p from public.pessoas where usuario = lower(trim(p_usuario)) and ativa;
  if p.id is null or coalesce(p_senha, '') = '' or length(p_senha) > 200 or p.senha_hash <> crypt(p_senha, p.senha_hash) then
    insert into public.login_falhas(ip) values (v_ip);
    perform pg_sleep(1);
    return jsonb_build_object('erro', 'usuario_invalido');
  end if;
  tok := encode(gen_random_bytes(24), 'hex');
  insert into public.sessoes(token, fazenda_id, pessoa_id) values (tok, null, p.id);
  return jsonb_build_object('token', tok, 'papel', p.papel, 'nome', p.nome, 'usuario', p.usuario,
                            'fazendas', public._fazendas_de(p.id, p.papel));
end $$;

-- fazendas da sessão (o app atualiza a lista ao abrir: acesso dado ou retirado vale sem sair)
create or replace function public.minhas_fazendas(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes;
begin
  s := public._exige(p_token, array['adm', 'tecnico', 'leitor']);
  if public._papel(s) = 'leitor' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome)), '[]') from public.fazendas where id = s.fazenda_id and ativa);
  end if;
  return public._fazendas_de(s.pessoa_id, public._papel(s));
end $$;

create or replace function public.trocar_senha(p_token text, p_atual text, p_nova text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessoes; p public.pessoas;
begin
  s := public._exige(p_token, array['adm', 'tecnico']);
  select * into p from public.pessoas where id = s.pessoa_id;
  if p.id is null then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p.senha_hash <> crypt(coalesce(p_atual, ''), p.senha_hash) then raise exception 'senha_atual_errada' using errcode = 'P0001'; end if;
  if length(coalesce(p_nova, '')) < 8 then raise exception 'senha_curta_pessoa' using errcode = 'P0001'; end if;
  update public.pessoas set senha_hash = crypt(p_nova, gen_salt('bf')) where id = p.id;
  delete from public.sessoes where pessoa_id = p.id and token <> p_token;    -- sai dos outros aparelhos
end $$;

-- ---------- dados e cadastros ----------
create or replace function public.dados(p_token text, p_fazenda text, p_desde date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._exige(p_token, array['adm', 'tecnico', 'leitor'], p_fazenda);
  return jsonb_build_object(
    'fazenda', (select jsonb_build_object('id', id, 'nome', nome, 'sistema', sistema) from public.fazendas where id = p_fazenda),
    'gerado_em', now(),
    'relatorios', (select coalesce(jsonb_agg(jsonb_build_object('data_ref', data_ref, 'n_baias', n_baias, 'n_cab', n_cab, 'processado_em', processado_em,
                                                                'sistema', sistema, 'janela_media', janela_media) order by data_ref), '[]')
                   from public.relatorios where fazenda_id = p_fazenda and (p_desde is null or data_ref >= p_desde)),
    'baias', (select coalesce(jsonb_agg(to_jsonb(b) - 'fazenda_id' order by b.data_ref, b.curral), '[]')
              from public.baias_dia b where b.fazenda_id = p_fazenda and (p_desde is null or b.data_ref >= p_desde)),
    'config', (select dados from public.config where fazenda_id = p_fazenda),
    'config_atualizado_em', (select atualizado_em from public.config where fazenda_id = p_fazenda),
    'config_atualizado_por', (select atualizado_por from public.config where fazenda_id = p_fazenda)
  );
end $$;

create or replace function public.salvar_config(p_token text, p_fazenda text, p_dados jsonb)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare s public.sessoes; t timestamptz := now(); quem text;
begin
  s := public._exige(p_token, array['adm', 'tecnico'], p_fazenda);
  if not exists (select 1 from public.fazendas where id = p_fazenda) then raise exception 'fazenda_inexistente' using errcode = 'P0001'; end if;
  if length(p_dados::text) > 2000000 then raise exception 'cadastro_grande' using errcode = 'P0001'; end if;
  quem := public._autor(s);
  insert into public.config(fazenda_id, dados, atualizado_em, atualizado_por) values (p_fazenda, p_dados, t, quem)
  on conflict (fazenda_id) do update set dados = excluded.dados, atualizado_em = t, atualizado_por = quem;
  insert into public.config_hist(fazenda_id, quando, autor, dados) values (p_fazenda, t, quem, p_dados);
  delete from public.config_hist where fazenda_id = p_fazenda and id not in
    (select id from public.config_hist where fazenda_id = p_fazenda order by quando desc limit 60);
  return t;
end $$;

-- histórico dos cadastros: administrador e técnico veem; só o administrador restaura
create or replace function public.historico_config(p_token text, p_fazenda text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._exige(p_token, array['adm', 'tecnico'], p_fazenda);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'quando', quando, 'autor', autor, 'acao', acao, 'dados', dados) order by quando desc), '[]')
          from (select * from public.config_hist where fazenda_id = p_fazenda order by quando desc limit 30) h);
end $$;

create or replace function public.restaurar_config(p_token text, p_fazenda text, p_id bigint)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare s public.sessoes; h public.config_hist; t timestamptz := now(); quem text;
begin
  s := public._exige(p_token, array['adm'], p_fazenda);
  select * into h from public.config_hist where id = p_id and fazenda_id = p_fazenda;
  if h.id is null then raise exception 'versao_inexistente' using errcode = 'P0001'; end if;
  quem := public._autor(s);
  update public.config set dados = h.dados, atualizado_em = t, atualizado_por = quem where fazenda_id = p_fazenda;
  insert into public.config_hist(fazenda_id, quando, autor, acao, dados)
  values (p_fazenda, t, quem, 'restaurou a versão de ' || to_char(h.quando at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (' || h.autor || ')', h.dados);
  return t;
end $$;

-- ---------- coleta: administrador vê tudo, técnico vê as fazendas dele ----------
create or replace function public.status_coleta(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes;
begin
  s := public._exige(p_token, array['adm', 'tecnico']);
  return jsonb_build_object(
    'ultimos_relatorios', (select coalesce(jsonb_agg(x), '[]') from (
        select f.id fazenda, f.nome, max(r.data_ref) ultimo, max(r.processado_em) processado_em, count(r.*) total
        from public.fazendas f left join public.relatorios r on r.fazenda_id = f.id
        where public._acessa(s, f.id) group by f.id, f.nome order by f.nome) x),
    'ultima_rodada', (select max(quando) from public.coleta_log where status = 'rodada'),
    'log', (select coalesce(jsonb_agg(l order by l.quando desc), '[]') from
            (select * from public.coleta_log where status <> 'rodada' and (fazenda_id is null or public._acessa(s, fazenda_id))
             order by quando desc limit 30) l)
  );
end $$;

-- ---------- ações só do administrador ----------
create or replace function public.adm_listar_fazendas(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public._exige(p_token, array['adm']);
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', f.id, 'nome', f.nome, 'ativa', f.ativa, 'email', f.email, 'remetente', f.remetente, 'sistema', f.sistema,
            'tem_senha_app', exists (select 1 from vault.decrypted_secrets v where v.name = 'imap:' || f.id),
            'ultimo_relatorio', (select max(r.data_ref) from public.relatorios r where r.fazenda_id = f.id),
            'ultimo_evento', (select jsonb_build_object('quando', l.quando, 'status', l.status, 'detalhe', l.detalhe)
                              from public.coleta_log l where l.fazenda_id = f.id and l.status in ('ok','erro','faltando')
                              order by l.quando desc limit 1)
          ) order by f.nome), '[]'::jsonb) from public.fazendas f);
end $$;

create or replace function public.adm_listar_pessoas(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._exige(p_token, array['adm']);
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', p.id, 'nome', p.nome, 'usuario', p.usuario, 'papel', p.papel, 'ativa', p.ativa,
            'fazendas', (select coalesce(jsonb_agg(pf.fazenda_id order by pf.fazenda_id), '[]') from public.pessoa_fazendas pf where pf.pessoa_id = p.id),
            'ultimo_acesso', (select max(criado_em) from public.sessoes x where x.pessoa_id = p.id)
          ) order by p.ativa desc, p.nome), '[]') from public.pessoas p);
end $$;

create or replace function public.adm_salvar_pessoa(p_token text, p_id int, p_nome text, p_usuario text, p_senha text,
                                                    p_papel text, p_ativa boolean, p_fazendas text[])
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessoes; v_id int; u text := lower(trim(coalesce(p_usuario, '')));
begin
  s := public._exige(p_token, array['adm']);
  if coalesce(trim(p_nome), '') = '' then raise exception 'nome_obrigatorio' using errcode = 'P0001'; end if;
  if u !~ '^[a-z0-9]+(\.[a-z0-9]+)+$' or length(u) > 60 then raise exception 'usuario_invalido_formato' using errcode = 'P0001'; end if;
  if p_papel not in ('adm', 'tecnico') then raise exception 'papel_invalido' using errcode = 'P0001'; end if;
  if exists (select 1 from public.pessoas where usuario = u and id is distinct from p_id) then raise exception 'usuario_repetido' using errcode = 'P0001'; end if;
  if coalesce(p_senha, '') <> '' and length(p_senha) < 8 then raise exception 'senha_curta_pessoa' using errcode = 'P0001'; end if;
  if p_id is not null and p_id = s.pessoa_id and (p_papel <> 'adm' or not coalesce(p_ativa, true)) then
    raise exception 'nao_pode_se_rebaixar' using errcode = 'P0001'; end if;
  if p_id is null then
    if coalesce(p_senha, '') = '' then raise exception 'senha_obrigatoria' using errcode = 'P0001'; end if;
    insert into public.pessoas(nome, usuario, senha_hash, papel, ativa)
    values (trim(p_nome), u, crypt(p_senha, gen_salt('bf')), p_papel, coalesce(p_ativa, true)) returning id into v_id;
  else
    select id into v_id from public.pessoas where id = p_id;
    if v_id is null then raise exception 'pessoa_inexistente' using errcode = 'P0001'; end if;
    update public.pessoas set nome = trim(p_nome), usuario = u, papel = p_papel, ativa = coalesce(p_ativa, true) where id = v_id;
    if coalesce(p_senha, '') <> '' then update public.pessoas set senha_hash = crypt(p_senha, gen_salt('bf')) where id = v_id; end if;
    if not exists (select 1 from public.pessoas where papel = 'adm' and ativa) then raise exception 'ultimo_adm' using errcode = 'P0001'; end if;
    if v_id is distinct from s.pessoa_id then delete from public.sessoes where pessoa_id = v_id; end if;   -- vale na hora
  end if;
  delete from public.pessoa_fazendas where pessoa_id = v_id;
  if p_papel = 'tecnico' then
    insert into public.pessoa_fazendas(pessoa_id, fazenda_id)
    select v_id, f.id from public.fazendas f where f.id = any(coalesce(p_fazendas, '{}'));
  end if;
  return jsonb_build_object('id', v_id, 'criada', p_id is null);
end $$;

-- ---------- envio de PDF, Atualizar e acompanhamento: com o nome de quem pediu ----------
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
  insert into public.uploads(fazenda_id, nome, conteudo) values (p_fazenda, left(p_nome, 200), b) returning id into i;
  insert into public.coleta_log(fazenda_id, status, detalhe)
  values (p_fazenda, 'pedido', 'relatório enviado pelo app por ' || public._autor(s) || ': ' || left(p_nome, 200));
  return i;
end $$;

create or replace function public.situacao_upload(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes;
begin
  s := public._exige(p_token, array['adm', 'tecnico', 'leitor']);
  return (select jsonb_build_object('status', status, 'detalhe', detalhe, 'data_ref', data_ref, 'processado_em', processado_em)
          from public.uploads where id = p_id and public._acessa(s, fazenda_id));
end $$;

create or replace function public.pedir_coleta(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sessoes; ult timestamptz; tok text; repo text; rid bigint; q timestamptz;
begin
  s := public._exige(p_token, array['adm', 'tecnico', 'leitor']);
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
  insert into public.coleta_log(fazenda_id, status, detalhe) values (s.fazenda_id, 'pedido', 'coleta pedida pelo botão Atualizar por ' || public._autor(s));
  return jsonb_build_object('pedido_em', q, 'repetido', false);
end $$;

create or replace function public.situacao_pedido(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.pedidos_coleta; st int; er text;
begin
  perform public._exige(p_token, array['adm', 'tecnico', 'leitor']);
  select * into p from public.pedidos_coleta order by quando desc limit 1;
  begin
    select status_code, coalesce(error_msg, case when timed_out then 'tempo esgotado' end)
      into st, er from net._http_response where id = p.request_id;
  exception when others then st := null; er := null;
  end;
  return jsonb_build_object('pedido_em', p.quando, 'github_status', st, 'github_erro', er,
    'ultima_rodada', (select max(quando) from public.coleta_log where status = 'rodada'));
end $$;

-- cadastro de fazenda (só administrador; senha da equipe com 6+ caracteres)
create or replace function public.adm_salvar_fazenda(p_token text, p_id text, p_nome text, p_senha_equipe text, p_email text, p_senha_app text, p_remetente text DEFAULT NULL::text, p_ativa boolean DEFAULT true, p_sistema text DEFAULT 'tgc'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare s public.sessoes; existe boolean; sec uuid; app text;
begin
  s := public._exige(p_token, array['adm']);

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
end $function$;


-- ---------- primeiro administrador (rode no SQL Editor; usa a senha de administrador atual) ----------
create or replace function public.definir_primeiro_adm(p_nome text, p_usuario text)
returns text language plpgsql security definer set search_path = public as $$
declare h text; u text := lower(trim(p_usuario));
begin
  select senha_hash into h from public.administrador where id = 1;
  if h is null then raise exception 'Não há senha de administrador. Rode antes: select public.definir_senha_adm(''...'');'; end if;
  if u !~ '^[a-z0-9]+(\.[a-z0-9]+)+$' then raise exception 'Usuário deve ser nome.sobrenome (minúsculas, sem acento)'; end if;
  insert into public.pessoas(nome, usuario, senha_hash, papel) values (trim(p_nome), u, h, 'adm')
  on conflict (usuario) do update set nome = excluded.nome, senha_hash = excluded.senha_hash, papel = 'adm', ativa = true;
  delete from public.sessoes where fazenda_id is null and pessoa_id is null;   -- a entrada só com a senha deixa de valer
  return 'Pronto: entre no app com o usuário ' || u || ' e a sua senha de administrador.';
end $$;

-- ---------- permissões ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.entrar(text), public.entrar_usuario(text, text), public.minhas_fazendas(text), public.trocar_senha(text, text, text),
  public.dados(text, text, date), public.salvar_config(text, text, jsonb), public.historico_config(text, text),
  public.restaurar_config(text, text, bigint), public.status_coleta(text), public.sair(text),
  public.pedir_coleta(text), public.situacao_pedido(text),
  public.adm_listar_fazendas(text), public.adm_salvar_fazenda(text, text, text, text, text, text, text, boolean, text),
  public.adm_listar_pessoas(text), public.adm_salvar_pessoa(text, int, text, text, text, text, boolean, text[]),
  public.enviar_relatorio(text, text, text, text), public.situacao_upload(text, bigint)
to anon;
notify pgrst, 'reload schema';

-- ============ DEPOIS DE RODAR TUDO ACIMA ============
-- Troque o nome e o usuário abaixo pelos seus (usuário no formato nome.sobrenome) e rode só esta linha:
-- select public.definir_primeiro_adm('Seu Nome Completo', 'nome.sobrenome');
