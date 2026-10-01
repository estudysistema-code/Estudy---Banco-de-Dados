-- =====================================================================
-- ESTUDY · 0002 — dados de referência (constantes do código)
-- ---------------------------------------------------------------------
-- São constantes do produto, não dados do usuário: nascem na migration
-- para que o banco nunca exista sem elas.
-- =====================================================================

-- ---------- Tipos de atividade (TYPES L686-696 · cores :root L15-23) ----------
CREATE TABLE activity_type_meta (
  type        activity_type PRIMARY KEY,
  label       TEXT    NOT NULL,
  color       TEXT    NOT NULL CHECK (color ~ '^#[0-9a-f]{6}$'),
  bg          TEXT    NOT NULL CHECK (bg    ~ '^#[0-9a-f]{6}$'),
  css_token   TEXT    NOT NULL,          -- var(--<css_token>) no HTML
  -- isAcad L977: tudo que não é ACADEMIA/ESTUDO/PESSOAL conta para presença
  is_academic BOOLEAN NOT NULL,
  sort_order  SMALLINT NOT NULL UNIQUE
);

INSERT INTO activity_type_meta (type, label, color, bg, css_token, is_academic, sort_order) VALUES
  ('CAMPO',       'Campo',       '#0f9d6e', '#eafaf3', 'campo',       TRUE,  1),
  ('TEORIA',      'Teoria',      '#2f6fed', '#eef3ff', 'teoria',      TRUE,  2),
  ('PROVA',       'Prova',       '#e0396b', '#fdeef3', 'prova',       TRUE,  3),
  ('SIMULACAO',   'Simulação',   '#7c4dea', '#f3eeff', 'simulacao',   TRUE,  4),
  ('MEDWAY',      'Medway',      '#d99400', '#fff6e3', 'medway',      TRUE,  5),
  ('ACOLHIMENTO', 'Acolhimento', '#0aa5b5', '#e6f9fb', 'acolhimento', TRUE,  6),
  ('ACADEMIA',    'Academia',    '#e2621c', '#fff0e6', 'academia',    FALSE, 7),
  ('ESTUDO',      'Estudo',      '#4b52d4', '#eeeffd', 'estudo',      FALSE, 8),
  ('PESSOAL',     'Pessoal',     '#6b7280', '#f3f4f6', 'pessoal',     FALSE, 9);

-- Imutável (não lê tabela) para poder ser usada em índices/colunas geradas.
-- Espelha exatamente isAcad (L977). Se a tabela acima mudar, mude aqui também;
-- o teste 01_reference.sql garante que os dois concordam.
CREATE FUNCTION is_academic(t activity_type) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT t NOT IN ('ACADEMIA','ESTUDO','PESSOAL') $$;

-- ---------- Status de presença (ST L699-704) ----------
CREATE TABLE presence_status_meta (
  status     presence_status PRIMARY KEY,
  label      TEXT NOT NULL,
  mark       TEXT NOT NULL,
  next       presence_status NOT NULL,     -- ciclo de 4 estados
  counts_as_present BOOLEAN NOT NULL,      -- stats L1054: presente + justificada
  sort_order SMALLINT NOT NULL UNIQUE
);
INSERT INTO presence_status_meta VALUES
  ('pendente',    'Pendente',    '',  'presente',    FALSE, 1),
  ('presente',    'Presente',    '✓', 'falta',       TRUE,  2),
  ('falta',       'Falta',       '✕', 'justificada', FALSE, 3),
  ('justificada', 'Justificada', '!', 'pendente',    TRUE,  4);

-- ---------- Status de tarefa (TSTATUS L2137) ----------
CREATE TABLE task_status_meta (
  status     task_status PRIMARY KEY,
  label      TEXT NOT NULL,
  css_token  TEXT NOT NULL,
  sort_order SMALLINT NOT NULL UNIQUE
);
INSERT INTO task_status_meta VALUES
  ('aberta',    'Aberta',       'ink-3',  1),
  ('andamento', 'Em andamento', 'medway', 2),
  ('concluida', 'Concluída',    'campo',  3);

-- ---------- Papéis × permissões (ROLE_PERMISSIONS L1951-1957) ----------
CREATE TABLE role_permissions (
  role        member_role PRIMARY KEY,
  label       TEXT  NOT NULL,              -- ROLE_LABEL L1947
  permissions JSONB NOT NULL,
  sort_order  SMALLINT NOT NULL UNIQUE
);
INSERT INTO role_permissions (role, label, sort_order, permissions) VALUES
  ('owner',  'Proprietário',  1, '{"manageWorkspace":true, "manageMembers":true, "manageInvites":true, "manageTasks":true, "manageEvents":true, "manageAssets":true, "comment":true,"view":true,"deleteWorkspace":true}'),
  ('admin',  'Administrador', 2, '{"manageWorkspace":true, "manageMembers":true, "manageInvites":true, "manageTasks":true, "manageEvents":true, "manageAssets":true, "comment":true,"view":true,"deleteWorkspace":false}'),
  ('editor', 'Editor',        3, '{"manageWorkspace":false,"manageMembers":false,"manageInvites":false,"manageTasks":true, "manageEvents":true, "manageAssets":true, "comment":true,"view":true,"deleteWorkspace":false}'),
  ('member', 'Membro',        4, '{"manageWorkspace":false,"manageMembers":false,"manageInvites":false,"manageTasks":true, "manageEvents":true, "manageAssets":true, "comment":true,"view":true,"deleteWorkspace":false}'),
  ('viewer', 'Visualizador',  5, '{"manageWorkspace":false,"manageMembers":false,"manageInvites":false,"manageTasks":false,"manageEvents":false,"manageAssets":false,"comment":true,"view":true,"deleteWorkspace":false}');

-- permissionsFor(role) L1958 — papel desconhecido cai em 'member'
CREATE FUNCTION permissions_for(r member_role) RETURNS JSONB
LANGUAGE sql STABLE PARALLEL SAFE
AS $$ SELECT coalesce((SELECT permissions FROM role_permissions WHERE role = r),
                      (SELECT permissions FROM role_permissions WHERE role = 'member')) $$;

-- ---------- Módulos do semestre (MOD_NAME L684) ----------
CREATE TABLE modules (
  code TEXT PRIMARY KEY,
  name TEXT NOT NULL
);
INSERT INTO modules VALUES
  ('SMI',   'Saúde da Mulher e da Criança'),
  ('SA',    'Saúde do Adulto'),
  ('GERAL', 'Plano importado');

-- ---------- Identidade visual do workspace (WSCOLORS L2138 · WSICONS L2139) ----------
-- O app grava a cor como 'var(--estudo)'; o banco guarda só o token 'estudo'.
CREATE TABLE workspace_colors (
  token      TEXT PRIMARY KEY,
  hex        TEXT NOT NULL CHECK (hex ~ '^#[0-9a-f]{6}$'),
  sort_order SMALLINT NOT NULL UNIQUE
);
INSERT INTO workspace_colors VALUES
  ('estudo','#4b52d4',1), ('campo','#0f9d6e',2), ('prova','#e0396b',3), ('simulacao','#7c4dea',4),
  ('medway','#d99400',5), ('acolhimento','#0aa5b5',6), ('academia','#e2621c',7), ('teoria','#2f6fed',8);

CREATE TABLE workspace_icons (
  icon       TEXT PRIMARY KEY,
  sort_order SMALLINT NOT NULL UNIQUE
);
INSERT INTO workspace_icons VALUES ('◍',1),('◆',2),('●',3),('▲',4),('■',5),('✦',6),('⬢',7),('◈',8);

-- ---------- Extensões de arquivo aceitas (OKEXT L2855) ----------
CREATE TABLE asset_ext_meta (
  ext   asset_ext PRIMARY KEY,
  color TEXT NOT NULL,
  mime  TEXT NOT NULL
);
INSERT INTO asset_ext_meta VALUES
  ('pdf',  '#e0396b', 'application/pdf'),
  ('docx', '#2f6fed', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'),
  ('jpg',  '#0f9d6e', 'image/jpeg'),
  ('jpeg', '#0f9d6e', 'image/jpeg'),
  ('png',  '#7c4dea', 'image/png');

-- ---------- Catálogo de Domain Events do Bus (L507-521) ----------
CREATE TABLE domain_event_catalog (
  name        TEXT PRIMARY KEY,
  emitted_by_app BOOLEAN NOT NULL,   -- FALSE = declarado no Bus, ainda sem emissor
  description TEXT NOT NULL DEFAULT ''
);
INSERT INTO domain_event_catalog (name, emitted_by_app) VALUES
  ('identity.session.started',TRUE), ('identity.session.ended',TRUE), ('identity.profile.updated',TRUE),
  ('user.upserted',TRUE),
  ('planner.event.created',TRUE), ('planner.event.updated',TRUE), ('planner.event.deleted',TRUE),
  ('planner.attendance.recorded',TRUE), ('planner.plan.imported',TRUE),
  ('workspace.created',TRUE), ('workspace.updated',TRUE), ('workspace.deleted',TRUE), ('workspace.opened',TRUE),
  ('workspace.member.added',TRUE), ('workspace.member.updated',TRUE), ('workspace.member.removed',TRUE),
  ('workspace.invite.created',TRUE), ('workspace.invite.redeemed',TRUE), ('workspace.invite.revoked',TRUE),
  ('workspace.task.created',TRUE), ('workspace.task.updated',TRUE), ('workspace.task.deleted',TRUE),
  ('workspace.event.created',TRUE), ('workspace.event.updated',TRUE), ('workspace.event.deleted',TRUE),
  ('workspace.asset.uploaded',TRUE), ('workspace.asset.removed',TRUE), ('workspace.activity.created',TRUE),
  ('ai.job.completed',TRUE), ('notification.created',TRUE),
  ('asset.processed',FALSE), ('ai.job.started',FALSE), ('ai.job.failed',FALSE), ('sync.requested',FALSE);
