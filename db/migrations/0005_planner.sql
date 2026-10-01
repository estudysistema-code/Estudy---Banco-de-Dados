-- =====================================================================
-- ESTUDY · 0005 — PLANNER (domínio PESSOAL)
-- ---------------------------------------------------------------------
-- Regra §5.1: nenhuma FK daqui aponta para workspace, e vice-versa.
-- A única ponte entre os domínios é users.id.
-- =====================================================================

-- subjectOf (L708): tira "(…)", tira "— Tema…", colapsa espaços.
-- Presença por matéria agrupa por este valor.
CREATE FUNCTION subject_of(title TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT btrim(regexp_replace(
           regexp_replace(
             regexp_replace(coalesce(title,''), '\s*\([^)]*\)', '', 'g'),
           '\s*—\s*Tema.*$', '', 'i'),
         '\s+', ' ', 'g'))
$$;

CREATE TABLE planner_events (
  id                   TEXT PRIMARY KEY CHECK (id ~ '^\S{1,80}$'),  -- ids curtos do app ('e'+base36) preservados
  user_id              TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  term_id              TEXT REFERENCES terms(id) ON DELETE SET NULL,
  source_item_id       TEXT REFERENCES schedule_items(id) ON DELETE SET NULL, -- linha da grade de origem
  date                 DATE NOT NULL,
  start_time           TIME NOT NULL,
  end_time             TIME NOT NULL,
  type                 activity_type   NOT NULL,
  title                TEXT NOT NULL DEFAULT 'Sem título',    -- L1641
  subject              TEXT GENERATED ALWAYS AS (subject_of(title)) STORED,
  note                 TEXT NOT NULL DEFAULT '',
  status               presence_status NOT NULL DEFAULT 'pendente',  -- regra §5.2: nunca booleano
  origin               event_origin    NOT NULL DEFAULT 'manual',
  -- regra §5.9: custom=false veio da grade; true = criado pelo aluno
  custom               BOOLEAN GENERATED ALWAYS AS (origin IN ('manual','sugestao')) STORED,
  attendance_marked_at TIMESTAMPTZ,                 -- quando o check-in foi feito (registro retroativo)
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at           TIMESTAMPTZ,                 -- exclusão lógica (sync não "ressuscita")
  CONSTRAINT planner_events_time CHECK (end_time > start_time),   -- L1644
  CONSTRAINT planner_events_marked CHECK (status = 'pendente' OR attendance_marked_at IS NOT NULL)
);
CREATE INDEX idx_planner_user_date ON planner_events (user_id, date) WHERE deleted_at IS NULL;
CREATE INDEX idx_planner_user_subject ON planner_events (user_id, subject) WHERE deleted_at IS NULL;
CREATE INDEX idx_planner_pending ON planner_events (user_id, date) WHERE deleted_at IS NULL AND status = 'pendente';

CREATE TABLE week_notes (
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  week_id    TEXT NOT NULL REFERENCES weeks(id) ON DELETE CASCADE,
  body       TEXT NOT NULL DEFAULT '',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, week_id)
);

-- Correção §3.3/§5.10: 'study' é HORAS de ESTUDO por semana (L1471, rótulo
-- "Estudo (h)" L1499), não blocos. 'gym' é a CONTAGEM de eventos ACADEMIA.
CREATE TABLE user_goals (
  user_id              TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  gym_per_week         SMALLINT     NOT NULL DEFAULT 4  CHECK (gym_per_week BETWEEN 0 AND 7),
  study_hours_per_week NUMERIC(4,1) NOT NULL DEFAULT 10 CHECK (study_hours_per_week BETWEEN 0 AND 40),
  updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now()
);
