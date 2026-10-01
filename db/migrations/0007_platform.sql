-- =====================================================================
-- ESTUDY · 0007 — plataforma: sync, outbox de eventos, jobs de IA
-- =====================================================================

-- Envelope {v, at, data} por namespace (Store §2.1). Base do
-- last-write-wins por namespace da §8.4.
CREATE TABLE sync_state (
  user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  namespace      TEXT NOT NULL CHECK (namespace IN ('identity','users','planner','workspace','memberships','invites')),
  schema_version SMALLINT NOT NULL,
  client_at      TIMESTAMPTZ,              -- `at` do último envelope aceito (LWW)
  server_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- último GET deste namespace: base da proteção por linha no workspace (o que
  -- outro membro criou/alterou depois do seu GET não é apagado nem sobrescrito)
  pulled_at      TIMESTAMPTZ,
  PRIMARY KEY (user_id, namespace)
);

-- Outbox: alimentado por triggers (0008), não pelo Bus do cliente — o Bus
-- não emite em "marcar tudo presente" (L1760) nem em "aplicar sugestões"
-- (L1772), então o banco é a fonte confiável dos Domain Events.
CREATE TABLE domain_events (
  id             BIGSERIAL PRIMARY KEY,
  name           TEXT NOT NULL REFERENCES domain_event_catalog(name),
  aggregate_type TEXT NOT NULL,
  aggregate_id   TEXT NOT NULL,
  workspace_id   TEXT,              -- preenchido para eventos colaborativos
  user_id        TEXT,              -- dono (planner) ou ator (workspace)
  payload        JSONB NOT NULL DEFAULT '{}',
  occurred_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  published_at   TIMESTAMPTZ        -- NULL = ainda não entregue ao consumidor
);
CREATE INDEX idx_domain_events_unpublished ON domain_events (id) WHERE published_at IS NULL;
CREATE INDEX idx_domain_events_aggregate ON domain_events (aggregate_type, aggregate_id);

-- Jobs de IA: importação do plano no onboarding (L3055-3105, hoje direto
-- do navegador) e o ciclo futuro dos assets (resumo/flashcards/embeddings).
CREATE TABLE ai_jobs (
  id           TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind         ai_job_kind NOT NULL,
  status       ai_status NOT NULL DEFAULT 'pendente',
  asset_ids    TEXT[] NOT NULL DEFAULT '{}',
  model        TEXT,
  result       JSONB,
  error        TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at   TIMESTAMPTZ,
  finished_at  TIMESTAMPTZ,
  CONSTRAINT ai_jobs_error CHECK (status <> 'erro' OR error IS NOT NULL)
);
CREATE INDEX idx_ai_jobs_queue ON ai_jobs (status, created_at) WHERE status IN ('pendente','processando');
