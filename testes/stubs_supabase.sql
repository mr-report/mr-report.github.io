-- SÓ PARA TESTE LOCAL: imita o pg_net e o Vault do Supabase.
create schema if not exists net;
create table if not exists net._http_response (id bigserial primary key, status_code int, error_msg text, timed_out bool, content text);
create table if not exists net.chamadas (id bigserial primary key, url text, body jsonb, headers jsonb);
create or replace function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000)
returns bigint language plpgsql as $$
declare i bigint;
begin
  insert into net.chamadas(url, body, headers) values (url, body, headers);
  insert into net._http_response(status_code) values (case when headers->>'Authorization' like '%ruim%' then 401 else 204 end) returning id into i;
  return i;
end $$;
create schema if not exists vault;
create table if not exists vault.segredos (name text primary key, decrypted_secret text);
create or replace view vault.decrypted_secrets as select name, decrypted_secret from vault.segredos;
