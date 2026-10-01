-- =====================================================================
-- ESTUDY · 0004 — estrutura do semestre e grade oficial
-- ---------------------------------------------------------------------
-- Correção em relação à §7 original: no app as semanas NÃO são globais.
-- Um plano importado por IA recria WEEKS (S01..S60, mod 'GERAL', L3092-3101)
-- e grava state.weeks + state.baseline no namespace planner. Por isso:
--   terms          = um ciclo com sua própria grade. Oficial (owner NULL,
--                    source 'seed') ou pessoal (owner = aluno, source 'import')
--   rotations      = rodízios do ciclo (Rod1/SMI, Rod2/SA)
--   weeks          = semanas do ciclo, id '<term>:<Sxx>'
--   schedule_items = a grade original ("baseline"): base de
--                    "Restaurar agenda original" (L1804) e da reimportação
--                    da grade sem destruir o que o aluno criou (regra §5.9)
--   enrollments    = aluno × ciclo (student_code 'ALUNO_026' mora aqui)
-- =====================================================================

CREATE TABLE terms (
  id            TEXT PRIMARY KEY,                    -- '2026.2' | 'import:<user_id>'
  label         TEXT NOT NULL,                       -- 'Agenda 9P 2026.2'
  source        plan_source NOT NULL,
  owner_user_id TEXT REFERENCES users(id) ON DELETE CASCADE,  -- NULL = grade oficial
  course        TEXT NOT NULL DEFAULT '',
  institution   TEXT NOT NULL DEFAULT '',
  start_date    DATE,
  end_date      DATE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT terms_owner_by_source CHECK ((source = 'import') = (owner_user_id IS NOT NULL)),
  CONSTRAINT terms_dates CHECK (end_date IS NULL OR start_date IS NULL OR end_date >= start_date)
);
-- no máximo um plano importado ativo por aluno
CREATE UNIQUE INDEX terms_one_import_per_user ON terms (owner_user_id) WHERE source = 'import';

CREATE TABLE rotations (
  id          TEXT PRIMARY KEY,                      -- '2026.2:Rod1'
  term_id     TEXT NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
  code        TEXT NOT NULL,                         -- 'Rod1'
  label       TEXT NOT NULL,                         -- 'Rodízio 1' (w.rod, exibido na UI L1400)
  module      TEXT NOT NULL REFERENCES modules(code),
  name        TEXT NOT NULL,                         -- 'Saúde da Mulher e da Criança'
  sort_order  SMALLINT NOT NULL DEFAULT 0,
  UNIQUE (term_id, code)
);

CREATE TABLE weeks (
  id          TEXT PRIMARY KEY,                      -- '2026.2:S02'
  term_id     TEXT NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
  code        TEXT NOT NULL CHECK (code ~ '^S[0-9]{2}$'),   -- 'S01'..'S60'
  rotation_id TEXT REFERENCES rotations(id) ON DELETE SET NULL,
  rod_label   TEXT NOT NULL,                         -- 'Rodízio 1' | 'Plano importado'
  module      TEXT NOT NULL REFERENCES modules(code),-- 'SMI' | 'SA' | 'GERAL'
  start_date  DATE NOT NULL,
  end_date    DATE GENERATED ALWAYS AS (start_date + 6) STORED,   -- L911
  UNIQUE (term_id, code),
  -- adiável: reimportar um plano desloca as datas das semanas no meio do upsert
  CONSTRAINT weeks_term_start_uq UNIQUE (term_id, start_date) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT weeks_start_is_monday CHECK (extract(isodow FROM start_date) = 1)
);
CREATE INDEX weeks_term_dates ON weeks (term_id, start_date);

CREATE TABLE schedule_items (
  id          TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  term_id     TEXT NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
  position    INT  NOT NULL,                         -- ordem na grade original
  date        DATE NOT NULL,
  start_time  TIME NOT NULL,
  end_time    TIME NOT NULL,
  type        activity_type NOT NULL,
  title       TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  UNIQUE (term_id, position),
  CONSTRAINT schedule_items_time CHECK (end_time > start_time)
);
CREATE INDEX schedule_items_term_date ON schedule_items (term_id, date);

CREATE TABLE enrollments (
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  term_id      TEXT NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
  student_code TEXT,                                 -- 'ALUNO_026'
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  enrolled_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, term_id)
);
-- o planner mostra um ciclo por vez: um único ativo por aluno
CREATE UNIQUE INDEX enrollments_one_active ON enrollments (user_id) WHERE is_active;
