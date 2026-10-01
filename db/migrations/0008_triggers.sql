-- =====================================================================
-- ESTUDY · 0008 — triggers: timestamps, derivações e outbox
-- =====================================================================

-- ---------- updated_at ----------
-- Só carimba now() se quem atualizou NÃO informou updated_at. Assim a
-- migração/sincronização preserva os timestamps que vieram do app.
CREATE FUNCTION trg_touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- ajuste interno (ex.: ensure_workspace_invite) que não deve contar como edição
  IF coalesce(current_setting('estudy.keep_updated_at', TRUE), '') = 'on' THEN
    NEW.updated_at := OLD.updated_at; RETURN NEW;
  END IF;
  IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
    NEW.updated_at := now();
  END IF;
  NEW.updated_at := least(NEW.updated_at, now());   -- nunca no futuro (travaria a proteção por linha)
  RETURN NEW;
END $$;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['users','identities','terms','planner_events','week_notes','user_goals',
                           'workspaces','memberships','workspace_events','tasks','assets','activities']
  LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at()',
                   t || '_touch', t);
  END LOOP;
END $$;

-- ---------- planner: carimbo de presença ----------
CREATE FUNCTION trg_planner_attendance() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'pendente' THEN
    NEW.attendance_marked_at := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    NEW.attendance_marked_at := coalesce(NEW.attendance_marked_at, now());
  ELSIF NEW.status IS DISTINCT FROM OLD.status
        AND NEW.attendance_marked_at IS NOT DISTINCT FROM OLD.attendance_marked_at THEN
    NEW.attendance_marked_at := now();
  ELSIF NEW.attendance_marked_at IS NULL THEN
    NEW.attendance_marked_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER planner_events_attendance BEFORE INSERT OR UPDATE ON planner_events
  FOR EACH ROW EXECUTE FUNCTION trg_planner_attendance();

-- ---------- tarefas: completed_at ----------
CREATE FUNCTION trg_task_completed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'concluida' THEN
    NEW.completed_at := coalesce(NEW.completed_at, now());
  ELSE
    NEW.completed_at := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tasks_completed BEFORE INSERT OR UPDATE ON tasks
  FOR EACH ROW EXECUTE FUNCTION trg_task_completed();

-- ---------- memberships: snapshot de permissões + remoção ----------
-- setRole (L1978) e Memberships.add (L1968): o snapshot é SEMPRE permissionsFor(role).
-- O banco nunca aceita permissões vindas do cliente — quando existir granularidade
-- por membro, ela entra por uma função administrativa própria.
CREATE FUNCTION trg_membership_derive() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  NEW.permissions := permissions_for(NEW.role);
  IF NEW.status = 'removed' THEN
    NEW.removed_at := coalesce(NEW.removed_at, now());
  ELSE
    NEW.removed_at := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER memberships_derive BEFORE INSERT OR UPDATE ON memberships
  FOR EACH ROW EXECUTE FUNCTION trg_membership_derive();

-- ---------- invites: revoked_at ----------
CREATE FUNCTION trg_invite_revoked() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'revoked' THEN NEW.revoked_at := coalesce(NEW.revoked_at, now());
  ELSE NEW.revoked_at := NULL; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER invites_revoked BEFORE INSERT OR UPDATE ON invites
  FOR EACH ROW EXECUTE FUNCTION trg_invite_revoked();

-- =====================================================================
-- OUTBOX — Domain Events (catálogo em domain_event_catalog)
-- SET estudy.skip_outbox = 'on' desliga (carga em massa, testes).
-- =====================================================================
-- SECURITY DEFINER: o app não tem INSERT em domain_events (não pode forjar eventos).
-- skip_outbox só vale para quem é estudy_admin (carga em massa).
CREATE FUNCTION emit_event(p_name TEXT, p_agg_type TEXT, p_agg_id TEXT,
                           p_ws TEXT, p_user TEXT, p_payload JSONB DEFAULT '{}')
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF coalesce(current_setting('estudy.skip_outbox', TRUE), '') = 'on'
     AND pg_has_role(session_user, 'estudy_admin', 'MEMBER') THEN RETURN; END IF;
  INSERT INTO domain_events (name, aggregate_type, aggregate_id, workspace_id, user_id, payload)
  VALUES (p_name, p_agg_type, p_agg_id, p_ws, p_user, coalesce(p_payload, '{}'));
END $$;

-- helper: nome do evento para tabelas com exclusão lógica
CREATE FUNCTION crud_event_name(p_prefix TEXT, p_op TEXT, p_old_deleted TIMESTAMPTZ, p_new_deleted TIMESTAMPTZ,
                                p_created TEXT DEFAULT 'created', p_updated TEXT DEFAULT 'updated',
                                p_deleted TEXT DEFAULT 'deleted')
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT p_prefix || '.' || CASE
    WHEN p_op = 'INSERT' THEN p_created
    WHEN p_op = 'DELETE' THEN p_deleted
    WHEN p_old_deleted IS NULL AND p_new_deleted IS NOT NULL THEN p_deleted
    WHEN p_old_deleted IS NOT NULL AND p_new_deleted IS NULL THEN p_created   -- restaurado
    ELSE p_updated END
$$;

CREATE FUNCTION trg_outbox_users() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM emit_event('user.upserted', 'user', NEW.id, NULL, NEW.id, jsonb_build_object('userId', NEW.id));
  RETURN NULL;
END $$;
CREATE TRIGGER users_outbox AFTER INSERT OR UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION trg_outbox_users();

CREATE FUNCTION trg_outbox_planner() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r planner_events;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status AND NEW.deleted_at IS NULL
     AND OLD.deleted_at IS NULL THEN
    PERFORM emit_event('planner.attendance.recorded', 'planner_event', r.id, NULL, r.user_id,
      jsonb_build_object('eventId', r.id, 'date', r.date, 'status', NEW.status, 'previous', OLD.status));
    IF (NEW.title, NEW.date, NEW.start_time, NEW.end_time, NEW.type, NEW.note)
       IS NOT DISTINCT FROM (OLD.title, OLD.date, OLD.start_time, OLD.end_time, OLD.type, OLD.note) THEN
      RETURN NULL;       -- só presença mudou
    END IF;
  END IF;
  PERFORM emit_event(crud_event_name('planner.event', TG_OP,
                       CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.deleted_at END,
                       CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE NEW.deleted_at END),
                     'planner_event', r.id, NULL, r.user_id,
                     jsonb_build_object('eventId', r.id, 'date', r.date, 'origin', r.origin));
  RETURN NULL;
END $$;
CREATE TRIGGER planner_events_outbox AFTER INSERT OR UPDATE OR DELETE ON planner_events
  FOR EACH ROW EXECUTE FUNCTION trg_outbox_planner();

CREATE FUNCTION trg_outbox_terms() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.source = 'import' THEN
    PERFORM emit_event('planner.plan.imported', 'term', NEW.id, NULL, NEW.owner_user_id,
                       jsonb_build_object('termId', NEW.id));
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER terms_outbox AFTER INSERT ON terms FOR EACH ROW EXECUTE FUNCTION trg_outbox_terms();

CREATE FUNCTION trg_outbox_workspaces() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r workspaces;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  PERFORM emit_event(crud_event_name('workspace', TG_OP,
                       CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.deleted_at END,
                       CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE NEW.deleted_at END),
                     'workspace', r.id, r.id, r.owner_id, jsonb_build_object('workspaceId', r.id));
  RETURN NULL;
END $$;
CREATE TRIGGER workspaces_outbox AFTER INSERT OR UPDATE OR DELETE ON workspaces
  FOR EACH ROW EXECUTE FUNCTION trg_outbox_workspaces();

CREATE FUNCTION trg_outbox_memberships() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n TEXT;
BEGIN
  IF TG_OP = 'INSERT' THEN n := 'workspace.member.added';
  ELSIF NEW.status = 'removed' AND OLD.status = 'active' THEN n := 'workspace.member.removed';
  ELSIF NEW.status = 'active' AND OLD.status = 'removed' THEN n := 'workspace.member.added';
  ELSE n := 'workspace.member.updated'; END IF;
  PERFORM emit_event(n, 'membership', NEW.id, NEW.workspace_id, NEW.user_id,
    jsonb_build_object('workspaceId', NEW.workspace_id, 'membershipId', NEW.id, 'userId', NEW.user_id, 'role', NEW.role));
  RETURN NULL;
END $$;
CREATE TRIGGER memberships_outbox AFTER INSERT OR UPDATE ON memberships
  FOR EACH ROW EXECUTE FUNCTION trg_outbox_memberships();

CREATE FUNCTION trg_outbox_invites() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM emit_event('workspace.invite.created', 'invite', NEW.id, NEW.workspace_id, NEW.created_by,
                       jsonb_build_object('workspaceId', NEW.workspace_id, 'inviteId', NEW.id));
  ELSIF NEW.status = 'revoked' AND OLD.status <> 'revoked' THEN
    PERFORM emit_event('workspace.invite.revoked', 'invite', NEW.id, NEW.workspace_id, NULL,
                       jsonb_build_object('workspaceId', NEW.workspace_id, 'inviteId', NEW.id));
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER invites_outbox AFTER INSERT OR UPDATE ON invites
  FOR EACH ROW EXECUTE FUNCTION trg_outbox_invites();

CREATE FUNCTION trg_outbox_redemptions() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE ws TEXT;
BEGIN
  SELECT workspace_id INTO ws FROM invites WHERE id = NEW.invite_id;
  PERFORM emit_event('workspace.invite.redeemed', 'invite', NEW.invite_id, ws, NEW.user_id,
                     jsonb_build_object('workspaceId', ws, 'inviteId', NEW.invite_id, 'userId', NEW.user_id));
  RETURN NULL;
END $$;
CREATE TRIGGER invite_redemptions_outbox AFTER INSERT ON invite_redemptions
  FOR EACH ROW EXECUTE FUNCTION trg_outbox_redemptions();

-- tarefas, eventos de workspace e assets seguem o mesmo padrão CRUD
CREATE FUNCTION trg_outbox_ws_child() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  j JSONB; prefix TEXT; key TEXT; n TEXT; actor TEXT;
  c_name TEXT := 'created'; d_name TEXT := 'deleted';
BEGIN
  j := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
  CASE TG_TABLE_NAME
    WHEN 'tasks'            THEN prefix := 'workspace.task';  key := 'taskId';  actor := coalesce(j->>'updated_by', j->>'created_by');
    WHEN 'workspace_events' THEN prefix := 'workspace.event'; key := 'eventId'; actor := coalesce(j->>'updated_by', j->>'created_by');
    WHEN 'assets'           THEN prefix := 'workspace.asset'; key := 'assetId'; actor := j->>'added_by';
                                 c_name := 'uploaded'; d_name := 'removed';
                                 IF j->>'context' <> 'workspace' THEN RETURN NULL; END IF;
  END CASE;
  n := crud_event_name(prefix, TG_OP,
         CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE (to_jsonb(OLD)->>'deleted_at')::timestamptz END,
         CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE (to_jsonb(NEW)->>'deleted_at')::timestamptz END,
         c_name, 'updated', d_name);
  IF n = 'workspace.asset.updated' THEN RETURN NULL; END IF;   -- não existe no catálogo
  PERFORM emit_event(n, TG_TABLE_NAME, j->>'id', j->>'workspace_id', actor,
                     jsonb_build_object('workspaceId', j->>'workspace_id', key, j->>'id'));
  RETURN NULL;
END $$;
CREATE TRIGGER tasks_outbox AFTER INSERT OR UPDATE OR DELETE ON tasks
  FOR EACH ROW EXECUTE FUNCTION trg_outbox_ws_child();
CREATE TRIGGER workspace_events_outbox AFTER INSERT OR UPDATE OR DELETE ON workspace_events
  FOR EACH ROW EXECUTE FUNCTION trg_outbox_ws_child();
CREATE TRIGGER assets_outbox AFTER INSERT OR UPDATE OR DELETE ON assets
  FOR EACH ROW EXECUTE FUNCTION trg_outbox_ws_child();

CREATE FUNCTION trg_outbox_activities() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM emit_event('workspace.activity.created', 'activity', NEW.id, NEW.workspace_id, NEW.author_id,
    jsonb_build_object('workspaceId', NEW.workspace_id, 'activityId', NEW.id, 'type', NEW.kind,
                       'parentId', NEW.parent_id, 'taskId', NEW.task_id));
  RETURN NULL;
END $$;
CREATE TRIGGER activities_outbox AFTER INSERT ON activities
  FOR EACH ROW EXECUTE FUNCTION trg_outbox_activities();

CREATE FUNCTION trg_outbox_ai_jobs() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n TEXT;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NULL; END IF;
  n := CASE NEW.status WHEN 'processando' THEN 'ai.job.started'
                       WHEN 'concluido'   THEN 'ai.job.completed'
                       WHEN 'erro'        THEN 'ai.job.failed' END;
  IF n IS NOT NULL THEN
    PERFORM emit_event(n, 'ai_job', NEW.id, NULL, NEW.user_id, jsonb_build_object('jobId', NEW.id, 'kind', NEW.kind));
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER ai_jobs_outbox AFTER INSERT OR UPDATE ON ai_jobs
  FOR EACH ROW EXECUTE FUNCTION trg_outbox_ai_jobs();
