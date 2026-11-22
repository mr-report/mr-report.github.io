-- =====================================================================
-- Cadastro de senhas e fazendas. Rode no "SQL Editor" do Supabase.
-- Troque os textos entre aspas antes de rodar. Pode rodar de novo
-- sempre que quiser trocar uma senha (quem estava logado sai).
-- =====================================================================

-- 1) Senha do administrador (vê todas as fazendas e edita os cadastros)
select public.definir_senha_adm('TROQUE-PELA-SENHA-DO-ADM');

-- 2) Uma linha por fazenda: (id, nome que aparece no app, senha de consulta)
--    O id é curto, sem espaços nem acentos, e precisa ser IGUAL ao "id" usado no secret FAZENDAS do GitHub.
select public.definir_fazenda('grao-para', 'Fazenda Grão Pará', 'TROQUE-PELA-SENHA-DA-FAZENDA');
-- select public.definir_fazenda('sao-marcelo', 'Confinamento São Marcelo', 'OUTRA-SENHA');

-- Conferir:
select id, nome, ativa, criado_em from public.fazendas order by nome;

-- Desativar uma fazenda (some do app, dados continuam guardados):
-- update public.fazendas set ativa = false where id = 'sao-marcelo';
