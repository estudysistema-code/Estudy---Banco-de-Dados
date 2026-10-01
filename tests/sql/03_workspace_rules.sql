-- Regras do WORKSPACE (§5.4–§5.7, convites, papéis, assets, activities)
BEGIN;
INSERT INTO users (id, display_name) VALUES ('w_dona','Dona'), ('w_ana','Ana'), ('w_beto','Beto'), ('w_caio','Caio');

DO $$
DECLARE ws TEXT; cd TEXT; r JSONB; inv TEXT; t1 TEXT := 'w_task1';
BEGIN
  PERFORM set_config('estudy.user_id', 'w_dona', TRUE);
  ws := api.create_workspace('w_dona', 'Grupo CM', 'revisão', 'campo', '◆');
  ASSERT (SELECT role FROM memberships WHERE workspace_id = ws AND user_id = 'w_dona') = 'owner', 'criador vira owner';
  ASSERT (SELECT permissions = permissions_for('owner') FROM memberships WHERE workspace_id = ws AND user_id = 'w_dona'),
    'snapshot = matriz do owner';
  SELECT invite_code INTO cd FROM workspaces WHERE id = ws;
  ASSERT cd ~ '^ESTUDY-[0-9A-Z]{4}$', 'código no formato do app';
  ASSERT EXISTS (SELECT 1 FROM invites WHERE workspace_id = ws AND code = cd), 'invite_code aponta para convite real';

  -- convite: case-insensitive, entra como member, conta uso, registra resgate
  PERFORM set_config('estudy.user_id', 'w_ana', TRUE);
  r := api.redeem_invite('w_ana', lower(cd));
  ASSERT (r->>'ok')::bool AND NOT (r->>'alreadyMember')::bool, 'ana entra pelo código minúsculo';
  ASSERT (SELECT role FROM memberships WHERE workspace_id = ws AND user_id = 'w_ana' AND status = 'active') = 'member', 'entra como member';
  ASSERT (SELECT current_uses FROM invites WHERE workspace_id = ws) = 1, 'uso contado';
  ASSERT (SELECT count(*) FROM invite_redemptions) = 1, 'resgate registrado';
  r := api.redeem_invite('w_ana', cd);
  ASSERT (r->>'alreadyMember')::bool AND (SELECT current_uses FROM invites WHERE workspace_id = ws) = 1, 'já membro não consome';
  ASSERT api.redeem_invite('w_ana', 'ESTUDY-NADA')->>'reason' = 'not_found', 'not_found';
  BEGIN
    PERFORM api.redeem_invite('w_beto', cd);
    ASSERT FALSE, 'ana não resgata em nome do beto';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- maxUses → exhausted
  UPDATE invites SET max_uses = 2 WHERE workspace_id = ws;
  PERFORM set_config('estudy.user_id', 'w_beto', TRUE);
  ASSERT (api.redeem_invite('w_beto', cd)->>'ok')::bool, 'beto usa o último';
  ASSERT (SELECT status FROM invites WHERE workspace_id = ws) = 'exhausted', 'esgotou';
  PERFORM set_config('estudy.user_id', 'w_caio', TRUE);
  ASSERT api.redeem_invite('w_caio', cd)->>'reason' = 'exhausted', 'caio recusado: exhausted';
  -- expirado e revogado
  UPDATE invites SET max_uses = NULL, current_uses = 2, status = 'active', expires_at = now() - interval '1 day' WHERE workspace_id = ws;
  ASSERT api.redeem_invite('w_caio', cd)->>'reason' = 'expired', 'expired';
  SELECT id INTO inv FROM invites WHERE workspace_id = ws;
  BEGIN
    PERFORM api.revoke_invite('w_caio', inv);
    ASSERT FALSE, 'não membro não revoga';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('estudy.user_id', 'w_dona', TRUE);
  PERFORM api.revoke_invite('w_dona', inv);
  PERFORM set_config('estudy.user_id', 'w_caio', TRUE);
  ASSERT api.redeem_invite('w_caio', cd)->>'reason' = 'inactive', 'revogado → inactive';
  ASSERT (SELECT revoked_at IS NOT NULL FROM invites WHERE id = inv), 'revoked_at carimbado';
  ASSERT EXISTS (SELECT 1 FROM domain_events WHERE name = 'workspace.invite.revoked'), 'evento revoked emitido';
  BEGIN
    INSERT INTO invites (id, workspace_id, code, created_by) VALUES ('dup', ws, lower(cd), 'w_dona');
    ASSERT FALSE, 'código duplicado (case-insensitive) deveria falhar';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  -- papel: snapshot SEMPRE derivado do papel (setRole L1978), nunca do cliente
  UPDATE memberships SET role = 'viewer' WHERE workspace_id = ws AND user_id = 'w_beto';
  PERFORM set_config('estudy.user_id', 'w_beto', TRUE);
  ASSERT NOT api.has_permission('w_beto', ws, 'manageTasks'), 'viewer perde manageTasks';
  ASSERT api.has_permission('w_beto', ws, 'comment'), 'viewer comenta';
  ASSERT NOT api.has_permission('w_ana', ws, 'comment'), 'has_permission só responde pelo usuário da sessão';
  UPDATE memberships SET role = 'editor' WHERE workspace_id = ws AND user_id = 'w_beto';
  ASSERT api.has_permission('w_beto', ws, 'manageTasks'), 'editor ganha manageTasks';
  UPDATE memberships SET permissions = '{"manageWorkspace":true,"manageMembers":true,"manageInvites":true,"manageTasks":true,"manageEvents":true,"manageAssets":true,"comment":true,"view":true,"deleteWorkspace":true}'
   WHERE workspace_id = ws AND user_id = 'w_beto';
  ASSERT NOT api.has_permission('w_beto', ws, 'deleteWorkspace'), 'permissões forjadas são rederivadas do papel';
  BEGIN
    UPDATE memberships SET role = 'owner' WHERE workspace_id = ws AND user_id = 'w_beto';
    ASSERT FALSE, 'segundo owner deveria falhar';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  -- remoção lógica + reentrada (índice parcial)
  UPDATE memberships SET status = 'removed' WHERE workspace_id = ws AND user_id = 'w_ana';
  PERFORM set_config('estudy.user_id', 'w_ana', TRUE);
  ASSERT NOT api.is_member(ws, 'w_ana'), 'removida não é membro';
  ASSERT (SELECT removed_at IS NOT NULL FROM memberships WHERE workspace_id = ws AND user_id = 'w_ana'), 'removed_at';
  INSERT INTO memberships (id, workspace_id, user_id, role, permissions) VALUES ('m_ana2', ws, 'w_ana', 'member', '{}');
  ASSERT api.is_member(ws, 'w_ana'), 'pode reentrar (nova linha, como Memberships.add)';
  BEGIN
    INSERT INTO memberships (id, workspace_id, user_id, permissions) VALUES ('m_ana3', ws, 'w_ana', '{}');
    ASSERT FALSE, 'duas memberships ativas deveria falhar';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  -- tarefas e comentários (Activity com FK real)
  INSERT INTO tasks (id, workspace_id, title, assignee_id, created_by) VALUES (t1, ws, 'Resumo ICC', 'w_ana', 'w_dona');
  INSERT INTO activities (id, workspace_id, author_id, body, task_id) VALUES ('c1', ws, 'w_ana', 'feito 50%', t1);
  INSERT INTO activities (id, workspace_id, author_id, body) VALUES ('c2', ws, 'w_dona', 'bem-vindos');
  INSERT INTO activities (id, workspace_id, author_id, body, parent_id) VALUES ('c3', ws, 'w_ana', 'obrigada', 'c2');
  ASSERT (SELECT target_type = 'task' AND target_id = t1 FROM activities WHERE id = 'c1'), 'target derivado';
  BEGIN
    INSERT INTO activities (id, workspace_id, author_id, body, parent_id) VALUES ('c4', ws, 'w_ana', 'neta', 'c3');
    ASSERT FALSE, 'resposta de resposta deveria falhar (1 nível, sem ciclos)';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE tasks SET status = 'concluida' WHERE id = t1;
  ASSERT (SELECT completed_at IS NOT NULL FROM tasks WHERE id = t1), 'completed_at';
  UPDATE tasks SET status = 'andamento' WHERE id = t1;
  ASSERT (SELECT completed_at IS NULL FROM tasks WHERE id = t1), 'reabrir limpa completed_at';
  DELETE FROM tasks WHERE id = t1;
  ASSERT NOT EXISTS (SELECT 1 FROM activities WHERE id = 'c1'), 'comentário some com a tarefa (L2639)';
  DELETE FROM activities WHERE id = 'c2';
  ASSERT NOT EXISTS (SELECT 1 FROM activities WHERE id = 'c3'), 'resposta some com o pai';

  -- §5.4 assets
  INSERT INTO assets (id, workspace_id, name, size_bytes, ext, added_by) VALUES ('a1', ws, 'foto.jpg', 10, 'jpg', 'w_ana');
  ASSERT (SELECT ai_status FROM assets WHERE id = 'a1') = 'pendente', 'aiStatus nasce pendente';
  BEGIN
    INSERT INTO assets (id, workspace_id, name, size_bytes, ext, added_by) VALUES ('a2', ws, 'x.gif', 1, 'gif', 'w_ana');
    ASSERT FALSE, 'gif deveria falhar';
  EXCEPTION WHEN invalid_text_representation THEN NULL;
  END;
  BEGIN
    INSERT INTO assets (id, context, name, size_bytes, ext, added_by) VALUES ('a3', 'workspace', 'x.pdf', 1, 'pdf', 'w_ana');
    ASSERT FALSE, 'asset de workspace sem workspace deveria falhar';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO assets (id, context, owner_user_id, name, size_bytes, ext, added_by)
  VALUES ('a4', 'onboarding', 'w_ana', 'grade.pdf', 1, 'pdf', 'w_ana');
  ASSERT EXISTS (SELECT 1 FROM assets WHERE id = 'a4'), 'arquivo do onboarding sem workspace';

  -- avatar só https ou data:image (o app interpola sem escape, L2127)
  BEGIN
    UPDATE users SET avatar_url = 'x); background:url(https://evil' WHERE id = 'w_ana';
    ASSERT FALSE, 'avatar com CSS injetado deveria falhar';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- workspace_events aceita fim = início (L2595)
  INSERT INTO workspace_events (id, workspace_id, date, start_time, end_time, title, created_by)
  VALUES ('we1', ws, '2026-10-10', '23:59', '23:59', 'Entrega', 'w_dona');

  -- excluir workspace leva tudo junto (sem órfãos, ao contrário do app L2526)
  DELETE FROM workspaces WHERE id = ws;
  ASSERT NOT EXISTS (SELECT 1 FROM memberships WHERE workspace_id = ws)
     AND NOT EXISTS (SELECT 1 FROM invites WHERE workspace_id = ws)
     AND NOT EXISTS (SELECT 1 FROM tasks WHERE workspace_id = ws), 'CASCADE sem órfãos';

  -- outbox cobre o ciclo do workspace
  ASSERT (SELECT count(DISTINCT name) FROM domain_events WHERE workspace_id = ws) >= 8, 'eventos de domínio do workspace';
  RAISE NOTICE 'ok 03 — regras do workspace';
END $$;
ROLLBACK;
