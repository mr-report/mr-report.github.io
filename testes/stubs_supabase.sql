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
drop view if exists vault.decrypted_secrets;
drop table if exists vault.segredos;
create table if not exists vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, secret text, description text);
create or replace view vault.decrypted_secrets as select id, name, secret as decrypted_secret from vault.secrets;
create or replace function vault.create_secret(new_secret text, new_name text default null, new_description text default '')
returns uuid language sql as $$ insert into vault.secrets(name, secret, description) values (new_name, new_secret, new_description) returning id $$;
create or replace function vault.update_secret(secret_id uuid, new_secret text default null, new_name text default null, new_description text default null)
returns void language sql as $$ update vault.secrets set secret = coalesce(new_secret, secret) where id = secret_id $$;
