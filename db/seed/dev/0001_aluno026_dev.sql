-- =====================================================================
-- SEED DE DESENVOLVIMENTO — NÃO rodar em produção.
-- Cria um aluno de teste matriculado no ciclo 2026.2 com os 160 eventos
-- da grade (status 'pendente', custom=false) e metas padrão (4 / 10h).
-- Em produção o aluno real entra pela importação do localStorage
-- (scripts/import-localstorage.mjs), que traz o uuid e as presenças dele.
-- =====================================================================
SET LOCAL estudy.skip_outbox = 'on';

INSERT INTO users (id, display_name, course, institution)
VALUES ('00000000-0000-4000-8000-000000000026', 'Aluno_026', 'Medicina', '')
ON CONFLICT (id) DO NOTHING;

INSERT INTO identities (user_id, username, full_name, period, provider, onboarded, onboarded_at, signed_in)
VALUES ('00000000-0000-4000-8000-000000000026', 'aluno026.dev', 'Aluno_026', 'Internato', 'email', TRUE, now(), TRUE)
ON CONFLICT (user_id) DO NOTHING;

SELECT set_config('estudy.user_id', '00000000-0000-4000-8000-000000000026', true);
SELECT api.enroll_user('00000000-0000-4000-8000-000000000026', '2026.2', 'ALUNO_026') AS eventos_criados;
