-- =====================================================================
-- ESTUDY · 0003 — identidade
-- ---------------------------------------------------------------------
-- users      = perfil público (contrato UserRef). Namespace estudy:users.
--              Inclui "participantes sem conta" adicionados à mão no
--              workspace (L2693) — por isso identities é opcional (0..1).
-- identities = credenciais/sessão/onboarding. Namespace estudy:identity.
-- =====================================================================

CREATE TABLE users (
  id           TEXT PRIMARY KEY,                 -- uuid (identity) | 'e'+base36 (uid) | 'demo_*'
  display_name TEXT NOT NULL DEFAULT '',
  avatar_url   TEXT,                             -- hoje pode ser data URI base64 (L2674); mover p/ storage
  course       TEXT NOT NULL DEFAULT '',
  institution  TEXT NOT NULL DEFAULT '',
  is_mock      BOOLEAN NOT NULL DEFAULT FALSE,   -- usuários demo_* do wsSeed (L2206) — nunca em produção
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT users_id_not_u_me CHECK (id <> 'u_me'),  -- regra §5.8: 'u_me' está proibido
  CONSTRAINT users_id_format CHECK (id ~ '^[A-Za-z0-9_.:-]{1,80}$'),
  -- o app interpola avatarUrl sem escape em style="url(...)" (L2127): só https ou data:image base64
  CONSTRAINT users_avatar_safe CHECK (avatar_url IS NULL
    OR avatar_url ~ '^https://[^\s"''()<>\\]+$'
    OR avatar_url ~ '^data:image/(png|jpeg|jpg|webp|gif);base64,[A-Za-z0-9+/=]+$')
);

CREATE TABLE identities (
  user_id          TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  username         CITEXT,                        -- '' do app vira NULL
  email            CITEXT,                        -- '' do app vira NULL (OAuth grava '')
  full_name        TEXT NOT NULL DEFAULT '',      -- identity.name (fonte do displayName no boot)
  period           TEXT NOT NULL DEFAULT '',      -- '1º'..'12º' | 'Internato' (PERIODS L2846)
  provider         auth_provider,
  provider_subject TEXT,                          -- id do usuário no Apple/Google (OAuth real)
  pass_hash        TEXT,
  -- 'sha256-client' = SHA-256 hex sem salt calculado no navegador (L2852).
  -- NÃO é credencial segura: re-hash no servidor (argon2id) no 1º login.
  pass_algo        TEXT CHECK (pass_algo IN ('sha256-client','argon2id','bcrypt')),
  onboarded        BOOLEAN NOT NULL DEFAULT FALSE,
  onboarded_at     TIMESTAMPTZ,
  signed_in        BOOLEAN NOT NULL DEFAULT FALSE, -- espelho do flag do app; em produção derive da sessão
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT identities_username_min CHECK (username IS NULL OR length(username) >= 3),        -- L2962
  CONSTRAINT identities_email_format CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'), -- L2963
  CONSTRAINT identities_hash_needs_algo CHECK (pass_hash IS NULL OR pass_algo IS NOT NULL),
  CONSTRAINT identities_subject_needs_provider CHECK (provider_subject IS NULL OR provider IN ('apple','google'))
);
-- OAuth do app grava o literal 'usuario.google'/'usuario.apple' para todos (L2947):
-- username só é único entre contas de e-mail.
CREATE UNIQUE INDEX identities_username_uq ON identities (username) WHERE username IS NOT NULL AND provider = 'email';
CREATE UNIQUE INDEX identities_email_uq    ON identities (email)    WHERE email    IS NOT NULL;
CREATE UNIQUE INDEX identities_oauth_uq    ON identities (provider, provider_subject) WHERE provider_subject IS NOT NULL;
