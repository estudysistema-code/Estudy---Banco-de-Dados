-- =====================================================================
-- ESTUDY · 0006 — WORKSPACE (domínio COLABORATIVO)
-- ---------------------------------------------------------------------
-- Grupos de estudo, TCC, monitoria. Calendário próprio que NUNCA escreve
-- no planner pessoal (regra §5.1).
-- =====================================================================

CREATE TABLE workspaces (
  id          TEXT PRIMARY KEY CHECK (id ~ '^\S{1,80}$'),
  name        TEXT NOT NULL CHECK (length(btrim(name)) > 0),          -- L2532
  description TEXT NOT NULL DEFAULT '',
  color       TEXT NOT NULL DEFAULT 'estudo' REFERENCES workspace_colors(token),
  icon        TEXT NOT NULL DEFAULT '◍'      REFERENCES workspace_icons(icon),
  owner_id    TEXT NOT NULL REFERENCES users(id),
  -- Cópia de exibição do código do convite principal (w.inviteCode, L2323).
  -- A verdade é a tabela invites; api.ensure_workspace_invite() garante que
  -- todo invite_code tenha um convite real (corrige o bug da migração v3, L2104).
  invite_code TEXT,
  is_mock     BOOLEAN NOT NULL DEFAULT FALSE,  -- wsSeed() L2155 — "substituíveis pelo backend"
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(), -- relógio do servidor (created_at vem do aparelho)
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ
);
CREATE INDEX idx_workspaces_owner ON workspaces (owner_id) WHERE deleted_at IS NULL;

CREATE TABLE invites (
  id           TEXT PRIMARY KEY CHECK (id ~ '^\S{1,80}$'),
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  code         TEXT NOT NULL CHECK (code ~ '^[A-Za-z0-9-]{4,32}$'),   -- 'ESTUDY-XXXX' (L2000)
  created_by   TEXT NOT NULL REFERENCES users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at   TIMESTAMPTZ,
  max_uses     INT CHECK (max_uses IS NULL OR max_uses > 0),
  current_uses INT NOT NULL DEFAULT 0 CHECK (current_uses >= 0),
  status       invite_status NOT NULL DEFAULT 'active',
  revoked_at   TIMESTAMPTZ,
  CONSTRAINT invites_uses_le_max CHECK (max_uses IS NULL OR current_uses <= max_uses)
);
-- findByCode compara sem diferenciar maiúsculas (L2014): unicidade global em upper()
CREATE UNIQUE INDEX invites_code_uq ON invites (upper(code));
CREATE INDEX idx_invites_ws ON invites (workspace_id);

CREATE TABLE memberships (
  id             TEXT PRIMARY KEY CHECK (id ~ '^\S{1,80}$'),
  workspace_id   TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id        TEXT NOT NULL REFERENCES users(id),
  role           member_role NOT NULL DEFAULT 'member',
  responsibility TEXT NOT NULL DEFAULT '',          -- "Estatística", "Resumos"
  joined_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  status         membership_status NOT NULL DEFAULT 'active',
  removed_at     TIMESTAMPTZ,
  invite_id      TEXT REFERENCES invites(id) ON UPDATE CASCADE ON DELETE SET NULL,
  -- snapshot derivado do papel (regra §5.7) — é o que canOn() lê (L2135).
  -- Trigger mantém permissions = permissions_for(role) quando o papel muda.
  permissions    JSONB NOT NULL,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT memberships_removed_at CHECK ((status = 'removed') = (removed_at IS NOT NULL)),
  CONSTRAINT memberships_perm_keys CHECK (permissions ?& ARRAY['manageWorkspace','manageMembers','manageInvites',
      'manageTasks','manageEvents','manageAssets','comment','view','deleteWorkspace'])
);
-- Correção: UNIQUE(workspace_id,user_id) impedia reentrar após remoção (add() cria nova linha, L1966).
CREATE UNIQUE INDEX memberships_one_active ON memberships (workspace_id, user_id) WHERE status = 'active';
CREATE INDEX idx_memberships_user ON memberships (user_id) WHERE status = 'active';
-- um único owner ativo por workspace (ninguém promove a owner, L2662)
CREATE UNIQUE INDEX memberships_one_owner ON memberships (workspace_id) WHERE role = 'owner' AND status = 'active';

CREATE TABLE invite_redemptions (
  id           BIGSERIAL PRIMARY KEY,
  invite_id    TEXT NOT NULL REFERENCES invites(id) ON UPDATE CASCADE ON DELETE CASCADE,
  user_id      TEXT NOT NULL REFERENCES users(id),
  membership_id TEXT REFERENCES memberships(id) ON DELETE SET NULL,
  redeemed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_redemptions_invite ON invite_redemptions (invite_id);

CREATE TABLE workspace_events (
  id           TEXT PRIMARY KEY CHECK (id ~ '^\S{1,80}$'),
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  date         DATE NOT NULL,
  start_time   TIME NOT NULL,
  end_time     TIME NOT NULL,
  title        TEXT NOT NULL DEFAULT 'Sem título',
  note         TEXT NOT NULL DEFAULT '',
  created_by   TEXT NOT NULL REFERENCES users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by   TEXT REFERENCES users(id),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at   TIMESTAMPTZ,
  -- diferente do planner: o workspace aceita fim IGUAL ao início (L2595)
  CONSTRAINT workspace_events_time CHECK (end_time >= start_time)
);
CREATE INDEX idx_wsevents ON workspace_events (workspace_id, date) WHERE deleted_at IS NULL;

CREATE TABLE tasks (
  id           TEXT PRIMARY KEY CHECK (id ~ '^\S{1,80}$'),
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  title        TEXT NOT NULL CHECK (length(btrim(title)) > 0),
  description  TEXT NOT NULL DEFAULT '',            -- 'desc' no app
  assignee_id  TEXT REFERENCES users(id) ON DELETE SET NULL,
  due_date     DATE,
  status       task_status NOT NULL DEFAULT 'aberta',
  completed_at TIMESTAMPTZ,
  created_by   TEXT NOT NULL REFERENCES users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by   TEXT REFERENCES users(id),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at   TIMESTAMPTZ,
  CONSTRAINT tasks_completed_at CHECK ((status = 'concluida') = (completed_at IS NOT NULL))
);
CREATE INDEX idx_tasks ON tasks (workspace_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_assignee ON tasks (assignee_id) WHERE deleted_at IS NULL;

-- Regra §5.4: todo arquivo é um Asset com ciclo de vida próprio (aiStatus desde o nascimento).
-- Correção: os arquivos do onboarding (identity.files, L3115) também são Assets,
-- sem workspace — por isso workspace_id é opcional e existe `context`.
CREATE TABLE assets (
  id            TEXT PRIMARY KEY CHECK (id ~ '^\S{1,80}$'),
  context       asset_context NOT NULL DEFAULT 'workspace',
  workspace_id  TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
  owner_user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  size_bytes    BIGINT NOT NULL CHECK (size_bytes >= 0),
  ext           asset_ext NOT NULL,
  mime_type     TEXT,
  sha256        TEXT CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'),
  added_by      TEXT NOT NULL REFERENCES users(id),
  added_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  ai_status     ai_status NOT NULL DEFAULT 'pendente',
  stored        BOOLEAN NOT NULL DEFAULT FALSE,     -- false = só metadados; binário não subiu
  storage_key   TEXT,                               -- chave no bucket quando o binário subir
  storage_url   TEXT,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at    TIMESTAMPTZ,
  CONSTRAINT assets_context_owner CHECK (
       (context = 'workspace'  AND workspace_id IS NOT NULL)
    OR (context = 'onboarding' AND workspace_id IS NULL AND owner_user_id IS NOT NULL)),
  CONSTRAINT assets_stored_has_key CHECK (NOT stored OR storage_key IS NOT NULL OR storage_url IS NOT NULL)
);
CREATE INDEX idx_assets_ws ON assets (workspace_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_assets_owner ON assets (owner_user_id) WHERE context = 'onboarding';
CREATE INDEX idx_assets_ai_queue ON assets (ai_status) WHERE ai_status IN ('pendente','processando') AND deleted_at IS NULL;

-- Regra §5.5: comentário é um tipo de Activity. Mural E comentários de
-- tarefa vivem aqui. task_id é FK real (CASCADE) — excluir a tarefa leva
-- os comentários junto, como no app (L2639). target_type/target_id são
-- derivados, mantendo os nomes da §7.
CREATE TABLE activities (
  id           TEXT PRIMARY KEY CHECK (id ~ '^\S{1,80}$'),
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL DEFAULT 'comment' CHECK (kind IN ('comment')),
  author_id    TEXT NOT NULL REFERENCES users(id),
  body         TEXT NOT NULL CHECK (length(btrim(body)) > 0),
  parent_id    TEXT REFERENCES activities(id) ON DELETE CASCADE,   -- thread (1 nível na UI, L2470)
  task_id      TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  target_type  TEXT GENERATED ALWAYS AS (CASE WHEN task_id IS NOT NULL THEN 'task' END) STORED,
  target_id    TEXT GENERATED ALWAYS AS (task_id) STORED,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at   TIMESTAMPTZ,
  CONSTRAINT activities_no_self_parent CHECK (parent_id IS NULL OR parent_id <> id),
  CONSTRAINT activities_task_no_thread CHECK (task_id IS NULL OR parent_id IS NULL)
);
-- threads de 1 nível (L2470): o pai é um comentário raiz do mural do MESMO workspace (impede ciclos)
CREATE FUNCTION trg_activity_parent() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.parent_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM activities p WHERE p.id = NEW.parent_id AND p.workspace_id = NEW.workspace_id
         AND p.task_id IS NULL AND p.parent_id IS NULL) THEN
    RAISE EXCEPTION 'parent_id % inválido: precisa ser comentário raiz do mesmo workspace', NEW.parent_id
      USING ERRCODE = '23514';
  END IF;
  -- quem já tem respostas não pode virar resposta (a resposta viraria neta e sumiria da UI)
  IF NEW.parent_id IS NOT NULL AND TG_OP = 'UPDATE' AND EXISTS (SELECT 1 FROM activities c WHERE c.parent_id = NEW.id) THEN
    RAISE EXCEPTION 'comentário % tem respostas e não pode virar resposta', NEW.id USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER activities_parent BEFORE INSERT OR UPDATE OF parent_id, workspace_id ON activities
  FOR EACH ROW EXECUTE FUNCTION trg_activity_parent();

CREATE INDEX idx_activities ON activities (workspace_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_activities_target ON activities (task_id) WHERE task_id IS NOT NULL;
CREATE INDEX idx_activities_parent ON activities (parent_id) WHERE parent_id IS NOT NULL;
