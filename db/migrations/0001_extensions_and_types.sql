-- =====================================================================
-- ESTUDY · 0001 — extensões, schemas e tipos enumerados
-- ---------------------------------------------------------------------
-- Fonte: planner_aluno026.html (TYPES L686, ST/CYCLE L699-705,
-- TSTATUS L2137, ROLES L1946, OKEXT L2855) + ESTUDY-DATABASE.md §4.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS citext;     -- e-mail/username sem diferenciar maiúsculas (login L2970)
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), digest()

-- `api` = funções chamáveis pelo backend (RPC). Tabelas ficam em `public`.
CREATE SCHEMA IF NOT EXISTS api;

-- Papéis:
--   estudy_app   → o backend em runtime (RLS + só as funções api.* liberadas em 0011)
--   estudy_admin → importação do localStorage, manutenção (api.ns_import, api.purge_mocks)
-- Em produção o servidor faz LOGIN com um papel que é membro APENAS de estudy_app.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'estudy_app')   THEN CREATE ROLE estudy_app   NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'estudy_admin') THEN CREATE ROLE estudy_admin NOLOGIN; END IF;
END $$;

-- Nenhuma função nasce executável por PUBLIC: 0011 libera uma lista explícita.
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
-- tabela temporária permitiria sombrear tabelas em funções SECURITY DEFINER
DO $$ BEGIN EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC', current_database()); END $$;

-- ---------- Planner ----------
CREATE TYPE activity_type AS ENUM (
  'CAMPO','TEORIA','PROVA','SIMULACAO','MEDWAY','ACOLHIMENTO','ACADEMIA','ESTUDO','PESSOAL'
);

-- ciclo de presença: pendente → presente → falta → justificada → pendente (CYCLE L705)
CREATE TYPE presence_status AS ENUM ('pendente','presente','falta','justificada');

-- origem do evento no planner (substitui a heurística note='sugestão automática')
--   grade    = veio da grade oficial do ciclo (custom:false)
--   import   = veio de um plano importado pelo aluno via IA (custom:false)
--   manual   = criado pelo aluno no editor (custom:true)
--   sugestao = aceito do motor de janelas livres (custom:true)
CREATE TYPE event_origin AS ENUM ('grade','import','manual','sugestao');

-- de onde veio a grade de um ciclo (terms)
CREATE TYPE plan_source AS ENUM ('seed','import');

-- ---------- Identidade ----------
CREATE TYPE auth_provider AS ENUM ('email','apple','google');

-- ---------- Workspace ----------
CREATE TYPE task_status       AS ENUM ('aberta','andamento','concluida');
CREATE TYPE member_role       AS ENUM ('owner','admin','editor','member','viewer');
CREATE TYPE membership_status AS ENUM ('active','removed');            -- remoção é lógica (L1991)
CREATE TYPE invite_status     AS ENUM ('active','exhausted','revoked'); -- L2019-2037

-- o app aceita e grava 'jpg' E 'jpeg' (OKEXT L2855 · extOf L2854)
CREATE TYPE asset_ext     AS ENUM ('pdf','docx','jpg','jpeg','png');
CREATE TYPE asset_context AS ENUM ('workspace','onboarding');

-- pipeline de IA: o app só usa 'pendente' hoje; o enum nasce completo
CREATE TYPE ai_status AS ENUM ('pendente','processando','concluido','erro');
CREATE TYPE ai_job_kind AS ENUM ('plan_import','asset_summary','asset_flashcards','asset_embeddings');
