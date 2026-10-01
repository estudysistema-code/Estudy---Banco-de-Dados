-- Privilégios + Row Level Security: planner pessoal isolado; workspace por membership + matriz.
-- Roda como estudy_app COM o outbox ligado (as escritas passam pelos triggers de verdade).
BEGIN;
INSERT INTO users (id, display_name) VALUES ('r_ana','Ana'), ('r_bia','Bia'), ('r_vic','Vic'), ('r_adm','Adm'), ('r_out','Fora');
SELECT set_config('estudy.user_id', 'r_ana', true);
SELECT api.enroll_user('r_ana', '2026.2');
SELECT api.create_workspace('r_ana', 'TCC') AS ws \gset
SELECT set_config('estudy.user_id', 'r_bia', true);
SELECT api.enroll_user('r_bia', '2026.2');
INSERT INTO memberships (id, workspace_id, user_id, role, permissions) VALUES
  ('rm_bia', :'ws', 'r_bia', 'member', '{}'), ('rm_vic', :'ws', 'r_vic', 'viewer', '{}'), ('rm_adm', :'ws', 'r_adm', 'admin', '{}');
INSERT INTO tasks (id, workspace_id, title, created_by) VALUES ('rt1', :'ws', 'Projeto', 'r_ana');
SELECT invite_code AS code FROM workspaces WHERE name = 'TCC' \gset
SELECT set_config('estudy.test_code', :'code', true);
SELECT set_config('estudy.test_ws', :'ws', true);

SET LOCAL ROLE estudy_app;

-- sem usuário na sessão: nada funciona (C4)
SELECT set_config('estudy.user_id', '', true);
DO $$ BEGIN
  BEGIN PERFORM api.ns_get('r_ana', 'planner'); ASSERT FALSE, 'ns_get sem GUC';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM api.ns_import('r_ana', 'planner', '{"v":2,"data":{"events":[]}}'); ASSERT FALSE, 'app não chama ns_import';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM api.purge_mocks(); ASSERT FALSE, 'app não chama purge_mocks';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM emit_event('user.upserted','user','x',NULL,NULL,'{}'); ASSERT FALSE, 'app não forja eventos';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN CREATE TEMP TABLE memberships (x int); ASSERT FALSE, 'sem tabela temporária (search_path hijack)';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;

-- Ana (owner)
SELECT set_config('estudy.user_id', 'r_ana', true);
DO $$
DECLARE e TEXT;
BEGIN
  ASSERT (SELECT count(*) FROM planner_events) = 160, 'ana vê só os 160 dela';
  ASSERT (SELECT count(DISTINCT user_id) FROM v_planner_events) = 1, 'view respeita RLS (security_invoker)';
  ASSERT (SELECT count(*) FROM workspaces) = 1, 'ana vê o TCC';
  -- escrita direta no planner pelo app passa pelos triggers + outbox
  SELECT id INTO e FROM planner_events ORDER BY date LIMIT 1;
  UPDATE planner_events SET status = 'presente' WHERE id = e;
  ASSERT api.cycle_attendance('r_ana', e) = 'falta', 'ciclo como estudy_app';
  BEGIN UPDATE workspaces SET owner_id = 'r_bia'; ASSERT FALSE, 'owner_id não é atualizável';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;

-- Bia (member)
SELECT set_config('estudy.user_id', 'r_bia', true);
DO $$
DECLARE n INT;
BEGIN
  ASSERT (SELECT count(*) FROM planner_events WHERE user_id = 'r_ana') = 0, 'bia não vê planner da ana';
  ASSERT (SELECT count(*) FROM v_planner_events WHERE user_id = 'r_ana') = 0, 'nem pela view';
  UPDATE planner_events SET status = 'falta' WHERE user_id = 'r_ana';
  GET DIAGNOSTICS n = ROW_COUNT; ASSERT n = 0, 'bia não altera planner da ana';
  INSERT INTO tasks (id, workspace_id, title, created_by, updated_by)
  SELECT 'rt2', id, 'Estatística', 'r_bia', 'r_bia' FROM workspaces;
  ASSERT (SELECT count(*) FROM tasks) = 2, 'member cria tarefa';
  BEGIN
    INSERT INTO tasks (id, workspace_id, title, created_by) SELECT 'rt2b', id, 'x', 'r_ana' FROM workspaces;
    ASSERT FALSE, 'não cria tarefa em nome de outro';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  UPDATE workspaces SET name = 'hack';
  GET DIAGNOSTICS n = ROW_COUNT; ASSERT n = 0, 'member não edita workspace';
  DELETE FROM workspaces;
  GET DIAGNOSTICS n = ROW_COUNT; ASSERT n = 0, 'member não apaga workspace';
  UPDATE memberships SET role = 'admin' WHERE user_id = 'r_bia';
  GET DIAGNOSTICS n = ROW_COUNT; ASSERT n = 0, 'member não se promove (C6)';
  BEGIN UPDATE memberships SET workspace_id = 'outro' WHERE user_id = 'r_bia'; ASSERT FALSE, 'workspace_id não é atualizável';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  ASSERT api.set_my_responsibility('r_bia', 'rm_bia', 'Estatística'), 'edita a própria responsabilidade';
  INSERT INTO activities (id, workspace_id, author_id, body) SELECT 'ra1', id, 'r_bia', 'oi' FROM workspaces;
END $$;

-- Adm (admin): gerencia membros, mas nunca o owner
SELECT set_config('estudy.user_id', 'r_adm', true);
DO $$
DECLARE n INT;
BEGIN
  UPDATE memberships SET role = 'editor' WHERE user_id = 'r_bia';
  GET DIAGNOSTICS n = ROW_COUNT; ASSERT n = 1, 'admin muda papel de member';
  ASSERT (SELECT (permissions->>'manageTasks')::bool FROM memberships WHERE user_id = 'r_bia'), 'snapshot rederivado';
  UPDATE memberships SET role = 'member' WHERE user_id = 'r_ana';
  GET DIAGNOSTICS n = ROW_COUNT; ASSERT n = 0, 'admin não rebaixa o owner';
  BEGIN UPDATE memberships SET role = 'owner' WHERE user_id = 'r_bia'; ASSERT FALSE, 'ninguém vira owner';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    UPDATE workspaces SET deleted_at = now();
    ASSERT FALSE, 'admin não deveria conseguir apagar (sem deleteWorkspace)';
  EXCEPTION WHEN insufficient_privilege THEN NULL;   -- WITH CHECK recusou o soft delete
  END;
END $$;

-- Vic (viewer): lê e comenta, não cria tarefa
SELECT set_config('estudy.user_id', 'r_vic', true);
DO $$
DECLARE n INT;
BEGIN
  ASSERT (SELECT count(*) FROM tasks) = 2, 'viewer lê tarefas';
  BEGIN
    INSERT INTO tasks (id, workspace_id, title, created_by) SELECT 'rt3', id, 'x', 'r_vic' FROM workspaces;
    ASSERT FALSE, 'viewer não deveria criar tarefa';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  UPDATE tasks SET title = 'mudei';
  GET DIAGNOSTICS n = ROW_COUNT; ASSERT n = 0, 'viewer não edita tarefa (o app deixa — L2780)';
  INSERT INTO activities (id, workspace_id, author_id, body) SELECT 'ra2', id, 'r_vic', 'boa!' FROM workspaces;
  BEGIN
    INSERT INTO activities (id, workspace_id, author_id, body) SELECT 'ra3', id, 'r_ana', 'falsificado' FROM workspaces;
    ASSERT FALSE, 'não pode comentar como outra pessoa';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

-- Fora: não é membro, não vê nada do workspace nem perfis alheios; entra só por código
SELECT set_config('estudy.user_id', 'r_out', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM workspaces) = 0, 'não membro não vê workspace';
  ASSERT (SELECT count(*) FROM tasks) = 0, 'não membro não vê tarefas';
  ASSERT (SELECT count(*) FROM invites) = 0, 'não membro não vê convites';
  ASSERT (SELECT count(*) FROM users) = 1, 'só o próprio perfil (não divide workspace)';
  ASSERT NOT api.has_permission('r_ana', current_setting('estudy.test_ws'), 'view'), 'não sonda permissões alheias';
  ASSERT (api.redeem_invite('r_out', current_setting('estudy.test_code'))->>'ok')::bool, 'entra pelo código via função';
  ASSERT (SELECT count(*) FROM workspaces) = 1, 'agora vê o workspace';
  ASSERT (SELECT count(*) FROM users) = 5, 'e os perfis de quem divide o workspace';
  ASSERT (SELECT count(*) FROM planner_events WHERE user_id <> 'r_out') = 0, 'mas continua sem ver planner alheio';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM domain_events WHERE name = 'planner.attendance.recorded' AND user_id = 'r_ana'),
    'outbox gravou evento disparado por estudy_app';
  RAISE NOTICE 'ok 04 — privilégios e RLS';
END $$;
ROLLBACK;
