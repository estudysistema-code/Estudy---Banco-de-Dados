-- =====================================================================
-- ESTUDY · 0011 — privilégios e Row Level Security
-- ---------------------------------------------------------------------
-- O backend faz LOGIN com um papel membro de `estudy_app` e, a cada requisição:
--     BEGIN; SELECT set_config('estudy.user_id', '<id autenticado>', true); ...; COMMIT;
-- Planner: só o dono vê/escreve (regra §5.1 — pessoal).
-- Workspace: membros ativos veem; escrita segue a matriz §4.4.
-- Nenhuma função é executável por PUBLIC (ALTER DEFAULT PRIVILEGES em 0001);
-- aqui se libera só o que o app precisa. UPDATE é concedido por coluna, para
-- que ninguém troque dono, workspace ou autor de uma linha.
-- =====================================================================

-- atalho usado nas policies
CREATE FUNCTION me() RETURNS TEXT LANGUAGE sql STABLE AS $$ SELECT api.current_user_id() $$;

DO $$ BEGIN
  IF NOT pg_has_role('estudy_admin', 'estudy_app', 'MEMBER') THEN GRANT estudy_app TO estudy_admin; END IF;
END $$;
GRANT USAGE ON SCHEMA public, api TO estudy_app, estudy_admin;

-- ---------- funções liberadas ao app ----------
GRANT EXECUTE ON FUNCTION
  api.current_user_id(), api.is_member(TEXT, TEXT), api.has_permission(TEXT, TEXT, TEXT),
  api.shares_workspace(TEXT), api.visible_workspaces(TEXT), api.next_status(presence_status),
  api.cycle_attendance(TEXT, TEXT), api.set_attendance(TEXT, TEXT, presence_status),
  api.mark_day_present(TEXT, DATE, BOOLEAN),
  api.attendance_stats(TEXT, TEXT, DATE, DATE), api.attendance_by_subject(TEXT, TEXT),
  api.pending_checkins(TEXT, DATE), api.day_overview(TEXT, DATE, DATE), api.empty_days_remaining(TEXT, DATE),
  api.weekly_goal_progress(TEXT, TEXT), api.enroll_user(TEXT, TEXT, TEXT), api.restore_baseline(TEXT),
  api.create_workspace(TEXT, TEXT, TEXT, TEXT, TEXT), api.redeem_invite(TEXT, TEXT), api.revoke_invite(TEXT, TEXT),
  api.set_my_responsibility(TEXT, TEXT, TEXT),
  api.ns_get(TEXT, TEXT), api.ns_put(TEXT, TEXT, JSONB, BOOLEAN),
  -- utilitários puros usados em views, colunas geradas e funções INVOKER
  me(), assert_acting_as(TEXT), is_academic(activity_type), subject_of(TEXT), permissions_for(member_role),
  hours_between(TIME, TIME), iso_ts(TIMESTAMPTZ), hhmm(TIME), short_id(), gen_invite_code()
TO estudy_app;

-- só administração: importação que confia no aparelho, limpeza de mocks
GRANT EXECUTE ON FUNCTION api.ns_import(TEXT, TEXT, JSONB, BOOLEAN), api.purge_mocks() TO estudy_admin;

-- ---------- tabelas ----------
GRANT SELECT ON activity_type_meta, presence_status_meta, task_status_meta, role_permissions, modules,
                workspace_colors, workspace_icons, asset_ext_meta, domain_event_catalog TO estudy_app;
GRANT SELECT ON v_planner_events TO estudy_app;

-- planner (pessoal): o dono mexe em tudo que é dele
GRANT SELECT, INSERT, UPDATE, DELETE ON planner_events, week_notes, user_goals, enrollments TO estudy_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON terms, rotations, weeks, schedule_items TO estudy_app;  -- RLS: só planos próprios
GRANT SELECT, INSERT, UPDATE, DELETE ON identities TO estudy_app;
GRANT SELECT ON sync_state, invite_redemptions, ai_jobs TO estudy_app;
-- o app só enfileira jobs; status/resultado são do worker (senão forjaria ai.job.completed)
GRANT INSERT (user_id, kind, asset_ids) ON ai_jobs TO estudy_app;

GRANT SELECT ON users TO estudy_app;
GRANT INSERT (id, display_name, avatar_url, course, institution) ON users TO estudy_app;
GRANT UPDATE (display_name, avatar_url, course, institution) ON users TO estudy_app;

GRANT SELECT, DELETE ON workspaces TO estudy_app;
GRANT INSERT (id, name, description, color, icon, owner_id, invite_code, created_at) ON workspaces TO estudy_app;
GRANT UPDATE (name, description, color, icon, deleted_at) ON workspaces TO estudy_app;

GRANT SELECT ON memberships TO estudy_app;
GRANT INSERT (id, workspace_id, user_id, role, responsibility, joined_at, status, permissions) ON memberships TO estudy_app;
GRANT UPDATE (role, responsibility, status) ON memberships TO estudy_app;

GRANT SELECT, DELETE ON invites TO estudy_app;
GRANT INSERT (id, workspace_id, code, created_by, created_at, expires_at, max_uses, status) ON invites TO estudy_app;
GRANT UPDATE (expires_at, max_uses, status) ON invites TO estudy_app;

GRANT SELECT, DELETE ON workspace_events, tasks, assets TO estudy_app;
GRANT INSERT (id, workspace_id, date, start_time, end_time, title, note, created_by, created_at, updated_by) ON workspace_events TO estudy_app;
GRANT UPDATE (date, start_time, end_time, title, note, updated_by, deleted_at) ON workspace_events TO estudy_app;
GRANT INSERT (id, workspace_id, title, description, assignee_id, due_date, status, created_by, created_at, updated_by) ON tasks TO estudy_app;
GRANT UPDATE (title, description, assignee_id, due_date, status, updated_by, deleted_at) ON tasks TO estudy_app;
GRANT INSERT (id, context, workspace_id, owner_user_id, name, size_bytes, ext, mime_type, sha256, added_by, added_at) ON assets TO estudy_app;
GRANT UPDATE (name, deleted_at) ON assets TO estudy_app;

GRANT SELECT ON activities TO estudy_app;
GRANT INSERT (id, workspace_id, kind, author_id, body, parent_id, task_id, created_at) ON activities TO estudy_app;
GRANT UPDATE (body, deleted_at) ON activities TO estudy_app;
-- domain_events (outbox): sem acesso do app — lido pelo worker de publicação, escrito só pelos triggers

-- ---------- identidade ----------
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
-- perfis visíveis: o próprio e quem divide algum workspace (contrato UserRef)
CREATE POLICY users_read   ON users FOR SELECT TO estudy_app USING (id = me() OR api.shares_workspace(id));
-- criar: a si mesmo ou participante sem conta (L2693)
CREATE POLICY users_insert ON users FOR INSERT TO estudy_app WITH CHECK (me() IS NOT NULL);
-- editar: a si mesmo, ou participante sem conta de um workspace onde se tem manageMembers
CREATE POLICY users_update ON users FOR UPDATE TO estudy_app USING (
  id = me() OR (NOT EXISTS (SELECT 1 FROM identities i WHERE i.user_id = users.id)
                AND EXISTS (SELECT 1 FROM memberships m WHERE m.user_id = users.id
                              AND api.has_permission(me(), m.workspace_id, 'manageMembers'))));

ALTER TABLE identities ENABLE ROW LEVEL SECURITY;
CREATE POLICY identities_own ON identities FOR ALL TO estudy_app USING (user_id = me()) WITH CHECK (user_id = me());

-- ---------- semestre ----------
ALTER TABLE terms ENABLE ROW LEVEL SECURITY;
CREATE POLICY terms_read  ON terms FOR SELECT TO estudy_app USING (owner_user_id IS NULL OR owner_user_id = me());
CREATE POLICY terms_write ON terms FOR ALL    TO estudy_app USING (owner_user_id = me()) WITH CHECK (owner_user_id = me());

ALTER TABLE rotations ENABLE ROW LEVEL SECURITY;
ALTER TABLE weeks ENABLE ROW LEVEL SECURITY;
ALTER TABLE schedule_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY rotations_read ON rotations FOR SELECT TO estudy_app
  USING (EXISTS (SELECT 1 FROM terms t WHERE t.id = term_id AND (t.owner_user_id IS NULL OR t.owner_user_id = me())));
CREATE POLICY rotations_write ON rotations FOR ALL TO estudy_app
  USING (EXISTS (SELECT 1 FROM terms t WHERE t.id = term_id AND t.owner_user_id = me()))
  WITH CHECK (EXISTS (SELECT 1 FROM terms t WHERE t.id = term_id AND t.owner_user_id = me()));
CREATE POLICY weeks_read ON weeks FOR SELECT TO estudy_app
  USING (EXISTS (SELECT 1 FROM terms t WHERE t.id = term_id AND (t.owner_user_id IS NULL OR t.owner_user_id = me())));
CREATE POLICY weeks_write ON weeks FOR ALL TO estudy_app
  USING (EXISTS (SELECT 1 FROM terms t WHERE t.id = term_id AND t.owner_user_id = me()))
  WITH CHECK (EXISTS (SELECT 1 FROM terms t WHERE t.id = term_id AND t.owner_user_id = me()));
CREATE POLICY schedule_read ON schedule_items FOR SELECT TO estudy_app
  USING (EXISTS (SELECT 1 FROM terms t WHERE t.id = term_id AND (t.owner_user_id IS NULL OR t.owner_user_id = me())));
CREATE POLICY schedule_write ON schedule_items FOR ALL TO estudy_app
  USING (EXISTS (SELECT 1 FROM terms t WHERE t.id = term_id AND t.owner_user_id = me()))
  WITH CHECK (EXISTS (SELECT 1 FROM terms t WHERE t.id = term_id AND t.owner_user_id = me()));

ALTER TABLE enrollments ENABLE ROW LEVEL SECURITY;
CREATE POLICY enrollments_own ON enrollments FOR ALL TO estudy_app USING (user_id = me()) WITH CHECK (user_id = me());

-- ---------- planner (PESSOAL) ----------
ALTER TABLE planner_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY planner_own ON planner_events FOR ALL TO estudy_app USING (user_id = me()) WITH CHECK (user_id = me());
ALTER TABLE week_notes ENABLE ROW LEVEL SECURITY;
CREATE POLICY notes_own ON week_notes FOR ALL TO estudy_app USING (user_id = me()) WITH CHECK (user_id = me());
ALTER TABLE user_goals ENABLE ROW LEVEL SECURITY;
CREATE POLICY goals_own ON user_goals FOR ALL TO estudy_app USING (user_id = me()) WITH CHECK (user_id = me());
ALTER TABLE sync_state ENABLE ROW LEVEL SECURITY;
CREATE POLICY sync_own ON sync_state FOR SELECT TO estudy_app USING (user_id = me());
ALTER TABLE ai_jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY ai_jobs_read ON ai_jobs FOR SELECT TO estudy_app USING (user_id = me());
CREATE POLICY ai_jobs_insert ON ai_jobs FOR INSERT TO estudy_app WITH CHECK (user_id = me() AND status = 'pendente' AND result IS NULL);

-- ---------- workspace (COLABORATIVO) ----------
ALTER TABLE workspaces ENABLE ROW LEVEL SECURITY;
CREATE POLICY ws_read   ON workspaces FOR SELECT TO estudy_app
  USING (deleted_at IS NULL AND (owner_id = me() OR api.is_member(id, me())));
CREATE POLICY ws_insert ON workspaces FOR INSERT TO estudy_app WITH CHECK (owner_id = me());
CREATE POLICY ws_update ON workspaces FOR UPDATE TO estudy_app
  USING (api.has_permission(me(), id, 'manageWorkspace') OR api.has_permission(me(), id, 'deleteWorkspace'))
  WITH CHECK (deleted_at IS NULL OR api.has_permission(me(), id, 'deleteWorkspace'));  -- soft delete só com deleteWorkspace
CREATE POLICY ws_delete ON workspaces FOR DELETE TO estudy_app USING (api.has_permission(me(), id, 'deleteWorkspace'));

ALTER TABLE memberships ENABLE ROW LEVEL SECURITY;
CREATE POLICY mem_read   ON memberships FOR SELECT TO estudy_app USING (api.is_member(workspace_id, me()) OR user_id = me());
CREATE POLICY mem_insert ON memberships FOR INSERT TO estudy_app WITH CHECK (
  (api.has_permission(me(), workspace_id, 'manageMembers') AND role <> 'owner')
  -- o dono cria a própria membership owner logo após criar o workspace
  OR (user_id = me() AND role = 'owner' AND EXISTS (SELECT 1 FROM workspaces w WHERE w.id = workspace_id AND w.owner_id = me())));
-- a linha do owner é intocável pelo app; ninguém vira owner por UPDATE (L2661-2666).
-- A própria responsabilidade sem manageMembers: api.set_my_responsibility().
CREATE POLICY mem_update ON memberships FOR UPDATE TO estudy_app
  USING (api.has_permission(me(), workspace_id, 'manageMembers') AND role <> 'owner')
  WITH CHECK (api.has_permission(me(), workspace_id, 'manageMembers') AND role <> 'owner');

ALTER TABLE invites ENABLE ROW LEVEL SECURITY;
CREATE POLICY inv_read   ON invites FOR SELECT TO estudy_app USING (api.is_member(workspace_id, me()));
CREATE POLICY inv_insert ON invites FOR INSERT TO estudy_app WITH CHECK (created_by = me() AND
  (api.has_permission(me(), workspace_id, 'manageInvites') OR EXISTS (SELECT 1 FROM workspaces w WHERE w.id = workspace_id AND w.owner_id = me())));
CREATE POLICY inv_update ON invites FOR UPDATE TO estudy_app
  USING (api.has_permission(me(), workspace_id, 'manageInvites')) WITH CHECK (api.has_permission(me(), workspace_id, 'manageInvites'));
CREATE POLICY inv_delete ON invites FOR DELETE TO estudy_app USING (api.has_permission(me(), workspace_id, 'manageInvites'));

ALTER TABLE invite_redemptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY red_read ON invite_redemptions FOR SELECT TO estudy_app
  USING (user_id = me() OR EXISTS (SELECT 1 FROM invites i WHERE i.id = invite_id
                                     AND api.has_permission(me(), i.workspace_id, 'manageInvites')));

-- filhos do workspace: ler = membro; escrever = permissão específica; autor = quem escreve
ALTER TABLE workspace_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY wse_read   ON workspace_events FOR SELECT TO estudy_app USING (api.is_member(workspace_id, me()));
CREATE POLICY wse_insert ON workspace_events FOR INSERT TO estudy_app
  WITH CHECK (created_by = me() AND api.has_permission(me(), workspace_id, 'manageEvents'));
CREATE POLICY wse_update ON workspace_events FOR UPDATE TO estudy_app
  USING (api.has_permission(me(), workspace_id, 'manageEvents'))
  WITH CHECK (api.has_permission(me(), workspace_id, 'manageEvents') AND updated_by = me());
CREATE POLICY wse_delete ON workspace_events FOR DELETE TO estudy_app USING (api.has_permission(me(), workspace_id, 'manageEvents'));

ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
CREATE POLICY tasks_read   ON tasks FOR SELECT TO estudy_app USING (api.is_member(workspace_id, me()));
CREATE POLICY tasks_insert ON tasks FOR INSERT TO estudy_app
  WITH CHECK (created_by = me() AND api.has_permission(me(), workspace_id, 'manageTasks'));
CREATE POLICY tasks_update ON tasks FOR UPDATE TO estudy_app
  USING (api.has_permission(me(), workspace_id, 'manageTasks'))
  WITH CHECK (api.has_permission(me(), workspace_id, 'manageTasks') AND updated_by = me());
CREATE POLICY tasks_delete ON tasks FOR DELETE TO estudy_app USING (api.has_permission(me(), workspace_id, 'manageTasks'));

ALTER TABLE assets ENABLE ROW LEVEL SECURITY;
CREATE POLICY assets_read ON assets FOR SELECT TO estudy_app USING (
  (context = 'workspace' AND api.is_member(workspace_id, me()))
  OR (context = 'onboarding' AND owner_user_id = me()));
CREATE POLICY assets_insert ON assets FOR INSERT TO estudy_app WITH CHECK (added_by = me() AND (
  (context = 'workspace' AND api.has_permission(me(), workspace_id, 'manageAssets'))
  OR (context = 'onboarding' AND owner_user_id = me())));
CREATE POLICY assets_update ON assets FOR UPDATE TO estudy_app USING (
  (context = 'workspace' AND api.has_permission(me(), workspace_id, 'manageAssets'))
  OR (context = 'onboarding' AND owner_user_id = me()));
CREATE POLICY assets_delete ON assets FOR DELETE TO estudy_app USING (
  (context = 'workspace' AND api.has_permission(me(), workspace_id, 'manageAssets'))
  OR (context = 'onboarding' AND owner_user_id = me()));

ALTER TABLE activities ENABLE ROW LEVEL SECURITY;
CREATE POLICY act_read   ON activities FOR SELECT TO estudy_app USING (api.is_member(workspace_id, me()));
CREATE POLICY act_insert ON activities FOR INSERT TO estudy_app
  WITH CHECK (author_id = me() AND api.has_permission(me(), workspace_id, 'comment'));
CREATE POLICY act_update ON activities FOR UPDATE TO estudy_app USING (author_id = me()) WITH CHECK (author_id = me());
