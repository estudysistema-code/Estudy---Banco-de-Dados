-- Regressões da 2ª rodada da revisão adversarial (N1, N2, A7c, R1, R3, R5, parent)
BEGIN;
INSERT INTO users (id, display_name) VALUES ('g_dona','Dona'), ('g_adm','Adm'), ('g_x','X'), ('g_bob','Bob'), ('g_ana','Ana'), ('g_e','E');
CREATE FUNCTION pg_temp.as_user(u TEXT) RETURNS VOID LANGUAGE sql AS $$ SELECT set_config('estudy.user_id', u, true) $$;

DO $$
DECLARE ws TEXT; r JSONB; inv TEXT; cd TEXT; old_m JSONB; old_i JSONB;
BEGIN
  PERFORM pg_temp.as_user('g_dona');
  ws := api.create_workspace('g_dona', 'Grupo');
  INSERT INTO memberships (id, workspace_id, user_id, role, permissions) VALUES ('gm_adm', ws, 'g_adm', 'admin', '{}'), ('gm_x', ws, 'g_x', 'member', '{}');
  SELECT id, code INTO inv, cd FROM invites WHERE workspace_id = ws;
  -- cópia que o admin tinha antes da remoção/revogação
  old_m := jsonb_build_object('v',1,'at','2026-09-30T10:00:00Z','data',jsonb_build_object('items',jsonb_build_array(
             jsonb_build_object('id','gm_x','workspaceId',ws,'userId','g_x','role','member','status','active'))));
  old_i := jsonb_build_object('v',1,'at','2026-09-30T10:00:00Z','data',jsonb_build_object('items',jsonb_build_array(
             jsonb_build_object('id',inv,'workspaceId',ws,'code',cd,'status','active'))));
  UPDATE memberships SET status = 'removed' WHERE id = 'gm_x';
  PERFORM api.revoke_invite('g_dona', inv);

  -- N1: cópia antiga não devolve acesso a removido nem reativa convite revogado
  PERFORM pg_temp.as_user('g_adm');
  r := api.ns_put('g_adm', 'memberships', old_m);
  ASSERT (SELECT status FROM memberships WHERE id = 'gm_x') = 'removed', 'removido continua removido';
  ASSERT r->'skipped'->0->>'reason' = 'removed_on_server', 'motivo reportado';
  r := api.ns_put('g_adm', 'invites', old_i);
  ASSERT (SELECT status FROM invites WHERE id = inv) = 'revoked', 'revogado continua revogado';

  -- A7c: identity parcial não apaga credenciais
  PERFORM pg_temp.as_user('g_e');
  r := api.ns_put('g_e', 'identity', '{"v":2,"at":"2026-09-30T10:00:00Z","data":{"userId":"g_e","username":"g_e_user","email":"e@x.com","passHash":"h1","provider":"email","onboarded":true}}');
  r := api.ns_put('g_e', 'identity', '{"v":2,"at":"2026-09-30T10:01:00Z","data":{"userId":"g_e"}}');
  ASSERT (SELECT username = 'g_e_user' AND email = 'e@x.com' AND pass_hash = 'h1' AND onboarded FROM identities WHERE user_id = 'g_e'),
    'identity parcial preserva credenciais';
  -- R1: e-mail já usado por outra conta → só o e-mail é descartado; senha fica
  PERFORM pg_temp.as_user('g_ana');
  r := api.ns_put('g_ana', 'identity', '{"v":2,"at":"2026-09-30T10:00:00Z","data":{"userId":"g_ana","username":"ana.ok","email":"E@X.com","passHash":"h2","provider":"email"}}');
  ASSERT (SELECT email IS NULL AND username = 'ana.ok' AND pass_hash = 'h2' FROM identities WHERE user_id = 'g_ana'),
    'e-mail repetido descartado sem perder username/senha';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'warnings') w WHERE w->>'field' = 'email'), 'aviso de e-mail em uso';
END $$;

-- N2: importação de dump antigo não corrompe workspace de outro dono já existente
SELECT set_config('estudy.user_id', 'g_bob', true);
SELECT api.ns_put('g_bob', 'workspace', '{"v":3,"at":"2026-09-30T10:00:00Z","data":{"workspaces":[{"id":"wb","name":"Do Bob","ownerId":"g_bob",
  "events":[],"files":[],"comments":[],"tasks":[{"id":"tb1","title":"nova","status":"aberta"},{"id":"tb2","title":"recente","status":"aberta"}]}]}}') \g /dev/null
SELECT api.ns_put('g_bob', 'memberships', '{"v":1,"at":"2026-09-30T10:00:00Z","data":{"items":[{"id":"mb_bob","workspaceId":"wb","userId":"g_bob","role":"owner","status":"active"},{"id":"mb_ana","workspaceId":"wb","userId":"g_ana","role":"member","status":"active"}]}}') \g /dev/null
-- (teste roda numa transação só: simula que o workspace do Bob já existia antes desta carga)
UPDATE workspaces SET inserted_at = now() - interval '1 day' WHERE id = 'wb';
DO $$
DECLARE r JSONB;
BEGIN
  r := api.ns_import('g_ana', 'workspace', '{"v":3,"at":"2026-09-30T09:00:00Z","data":{"workspaces":[{"id":"wb","name":"VELHO","ownerId":"g_bob",
    "events":[],"files":[],"comments":[],"tasks":[{"id":"tb1","title":"velha","status":"aberta"}]}]}}');
  r := api.ns_import('g_ana', 'memberships', '{"v":1,"at":"2026-09-30T09:00:00Z","data":{"items":[{"id":"mb_bob","workspaceId":"wb","userId":"g_bob","role":"viewer","status":"removed"},{"id":"mb_ana","workspaceId":"wb","userId":"g_ana","role":"owner","status":"active"}]}}');
  ASSERT (SELECT name FROM workspaces WHERE id = 'wb') = 'Do Bob', 'import não renomeia workspace alheio';
  ASSERT (SELECT deleted_at IS NULL FROM tasks WHERE id = 'tb2'), 'import não apaga tarefa alheia';
  ASSERT (SELECT role = 'owner' AND status = 'active' FROM memberships WHERE id = 'mb_bob'), 'dono intacto';
  ASSERT (SELECT role FROM memberships WHERE id = 'mb_ana') = 'member', 'ana não vira owner pelo import';

  -- R3: app não forja job de IA concluído
  SET LOCAL ROLE estudy_app;
  PERFORM set_config('estudy.user_id', 'g_ana', true);
  BEGIN
    INSERT INTO ai_jobs (user_id, kind, status, result) VALUES ('g_ana', 'plan_import', 'concluido', '{"x":1}');
    ASSERT FALSE, 'app não define status/resultado de job';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  INSERT INTO ai_jobs (user_id, kind) VALUES ('g_ana', 'plan_import');   -- enfileirar é permitido
  -- R5: updated_at não é gravável pelo app
  BEGIN
    UPDATE users SET updated_at = '9999-01-01' WHERE id = 'g_ana';
    ASSERT FALSE, 'updated_at não é gravável pelo app';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;
END $$;

-- parent: comentário que já tem resposta não vira resposta
DO $$
BEGIN
  INSERT INTO activities (id, workspace_id, author_id, body) VALUES ('pa','wb','g_bob','A'), ('pc','wb','g_bob','C');
  INSERT INTO activities (id, workspace_id, author_id, body, parent_id) VALUES ('pb','wb','g_bob','B','pa');
  BEGIN
    UPDATE activities SET parent_id = 'pc' WHERE id = 'pa';
    ASSERT FALSE, 'A tem resposta e não pode virar resposta';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'ok 06 — regressões da revisão';
END $$;
ROLLBACK;
