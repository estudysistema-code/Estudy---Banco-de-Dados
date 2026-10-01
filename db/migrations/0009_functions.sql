-- =====================================================================
-- ESTUDY · 0009 — funções utilitárias e regras de negócio (schema api)
-- ---------------------------------------------------------------------
-- Cada função reproduz uma regra do planner_aluno026.html; a linha de
-- origem vai no comentário. O backend chama estas funções em vez de
-- reimplementar a regra.
-- =====================================================================

-- ---------- utilitários ----------
-- timestamp no formato do app: new Date().toISOString() → '2026-09-30T13:26:00.000Z'
CREATE FUNCTION iso_ts(t TIMESTAMPTZ) RETURNS TEXT
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT to_char(t AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') $$;

CREATE FUNCTION hhmm(t TIME) RETURNS TEXT
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT to_char(t, 'HH24:MI') $$;

CREATE FUNCTION hours_between(s TIME, e TIME) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT round(extract(epoch FROM (e - s)) / 3600.0, 4) $$;

-- uid() L907: 'e' + até 7 caracteres base36
CREATE FUNCTION short_id() RETURNS TEXT
LANGUAGE sql VOLATILE AS $$
  SELECT 'e' || string_agg(substr('0123456789abcdefghijklmnopqrstuvwxyz', (floor(random()*36))::int + 1, 1), '')
  FROM generate_series(1, 7)
$$;

-- genInviteCode L2000: 'ESTUDY-' + 4 caracteres [0-9A-Z]. Aqui com retentativa
-- (o app não checa colisão — o banco garante a unicidade).
CREATE FUNCTION gen_invite_code() RETURNS TEXT
LANGUAGE plpgsql VOLATILE AS $$
DECLARE c TEXT; i INT := 0;
BEGIN
  LOOP
    SELECT 'ESTUDY-' || string_agg(substr('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ', (floor(random()*36))::int + 1, 1), '')
      INTO c FROM generate_series(1, 4);
    EXIT WHEN NOT EXISTS (SELECT 1 FROM invites WHERE upper(code) = c);
    i := i + 1;
    IF i > 50 THEN  -- espaço de 36^4 ≈ 1,68 mi: amplia para 6 caracteres
      c := 'ESTUDY-' || upper(substr(md5(random()::text), 1, 6));
      EXIT WHEN NOT EXISTS (SELECT 1 FROM invites WHERE upper(code) = c);
    END IF;
  END LOOP;
  RETURN c;
END $$;

-- usuário da requisição (definido pelo backend: SET LOCAL estudy.user_id = '<id>')
CREATE FUNCTION api.current_user_id() RETURNS TEXT
LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('estudy.user_id', TRUE), '') $$;

-- barreira usada pelas funções SECURITY DEFINER: se há usuário na sessão,
-- ele só pode agir em nome de si mesmo.
-- Estrito: sem usuário na sessão, nenhuma função age em nome de ninguém.
-- (tarefas administrativas usam api.ns_import / funções de estudy_admin)
CREATE FUNCTION assert_acting_as(p_user TEXT) RETURNS VOID
LANGUAGE plpgsql STABLE AS $$
DECLARE cur TEXT := api.current_user_id();
BEGIN
  IF cur IS NULL THEN
    RAISE EXCEPTION 'estudy.user_id não definido na sessão' USING ERRCODE = '42501';
  END IF;
  IF cur <> p_user THEN
    RAISE EXCEPTION 'usuário % não pode agir em nome de %', cur, p_user USING ERRCODE = '42501';
  END IF;
END $$;

-- ---------- permissões (L2135 canOn lê o snapshot da membership) ----------
-- Só respondem sobre o usuário da própria sessão (evita enumerar workspaces alheios).
CREATE FUNCTION api.is_member(p_workspace TEXT, p_user TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT p_user = api.current_user_id() AND EXISTS (SELECT 1 FROM memberships
                 WHERE workspace_id = p_workspace AND user_id = p_user AND status = 'active')
$$;

CREATE FUNCTION api.has_permission(p_user TEXT, p_workspace TEXT, p_perm TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT p_user = api.current_user_id() AND coalesce((SELECT (permissions ->> p_perm)::boolean FROM memberships
                   WHERE workspace_id = p_workspace AND user_id = p_user AND status = 'active'), FALSE)
$$;

-- a e b dividem algum workspace ativo? (visibilidade de perfis, RLS de users)
CREATE FUNCTION api.shares_workspace(p_other TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM memberships a JOIN memberships b ON b.workspace_id = a.workspace_id
                 JOIN workspaces w ON w.id = a.workspace_id AND w.deleted_at IS NULL
                 WHERE a.user_id = api.current_user_id() AND a.status = 'active' AND b.status = 'active' AND b.user_id = p_other)
$$;

-- =====================================================================
-- PLANNER
-- =====================================================================

-- ciclo de 4 estados (L1826 / CYCLE L705)
CREATE FUNCTION api.next_status(s presence_status) RETURNS presence_status
LANGUAGE sql STABLE AS $$ SELECT next FROM presence_status_meta WHERE status = s $$;

CREATE FUNCTION api.cycle_attendance(p_user TEXT, p_event TEXT) RETURNS presence_status
LANGUAGE plpgsql AS $$
DECLARE s presence_status;
BEGIN
  PERFORM assert_acting_as(p_user);
  UPDATE planner_events SET status = api.next_status(status)
   WHERE id = p_event AND user_id = p_user AND deleted_at IS NULL
  RETURNING status INTO s;
  IF s IS NULL THEN RAISE EXCEPTION 'evento % não encontrado', p_event USING ERRCODE = 'P0002'; END IF;
  RETURN s;
END $$;

-- marcação idempotente (regra §5.2): marcar duas vezes o mesmo status não muda nada
CREATE FUNCTION api.set_attendance(p_user TEXT, p_event TEXT, p_status presence_status) RETURNS presence_status
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM assert_acting_as(p_user);
  UPDATE planner_events SET status = p_status
   WHERE id = p_event AND user_id = p_user AND deleted_at IS NULL AND status IS DISTINCT FROM p_status;
  IF NOT EXISTS (SELECT 1 FROM planner_events WHERE id = p_event AND user_id = p_user AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'evento % não encontrado', p_event USING ERRCODE = 'P0002';
  END IF;
  RETURN p_status;
END $$;

-- "Marcar tudo como presente" (L1760): o app marca TODOS os eventos do dia,
-- inclusive ACADEMIA/ESTUDO/PESSOAL. p_academic_only=true é a versão estrita.
CREATE FUNCTION api.mark_day_present(p_user TEXT, p_date DATE, p_academic_only BOOLEAN DEFAULT FALSE)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
  PERFORM assert_acting_as(p_user);
  UPDATE planner_events SET status = 'presente'
   WHERE user_id = p_user AND date = p_date AND deleted_at IS NULL AND status <> 'presente'
     AND (NOT p_academic_only OR is_academic(type));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- eventos vivos do aluno com a semana/módulo do ciclo ativo
CREATE VIEW v_planner_events WITH (security_invoker = true) AS
SELECT e.*, is_academic(e.type) AS is_academic, hours_between(e.start_time, e.end_time) AS hours,
       w.id AS week_id, w.code AS week_code, w.module
FROM planner_events e
LEFT JOIN enrollments en ON en.user_id = e.user_id AND en.is_active
LEFT JOIN weeks w ON w.term_id = coalesce(e.term_id, en.term_id) AND e.date BETWEEN w.start_date AND w.end_date
WHERE e.deleted_at IS NULL;

-- stats() L1050-1057 sobre eventos ACADÊMICOS (isAcad), opcionalmente por módulo/intervalo.
-- pct = (presente + justificada) / registrados; pendente fica fora; NULL se nada registrado.
CREATE FUNCTION api.attendance_stats(p_user TEXT, p_module TEXT DEFAULT NULL,
                                     p_from DATE DEFAULT NULL, p_to DATE DEFAULT NULL)
RETURNS TABLE (total INT, presente INT, falta INT, justificada INT, pendente INT,
               registrados INT, pct INT, horas_falta NUMERIC, em_risco BOOLEAN)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
BEGIN
  PERFORM assert_acting_as(p_user);
  RETURN QUERY
  WITH s AS (
    SELECT count(*)::int AS total,
           count(*) FILTER (WHERE status = 'presente')::int    AS presente,
           count(*) FILTER (WHERE status = 'falta')::int       AS falta,
           count(*) FILTER (WHERE status = 'justificada')::int AS justificada,
           count(*) FILTER (WHERE status = 'pendente')::int    AS pendente,
           coalesce(sum(hours) FILTER (WHERE status = 'falta'), 0) AS horas_falta
    FROM v_planner_events
    WHERE user_id = p_user AND is_academic
      AND (p_module IS NULL OR module = p_module)
      AND (p_from IS NULL OR date >= p_from) AND (p_to IS NULL OR date <= p_to))
  SELECT total, presente, falta, justificada, pendente,
         presente + falta + justificada,
         CASE WHEN presente + falta + justificada > 0
              THEN round((presente + justificada) * 100.0 / (presente + falta + justificada))::int END,
         round(horas_falta, 2),
         CASE WHEN presente + falta + justificada > 0
              THEN round((presente + justificada) * 100.0 / (presente + falta + justificada)) < 75 ELSE FALSE END
  FROM s;
END $$;

-- bySubject L1058-1066 · risco = pct < 75 (MIN_PCT L1048)
CREATE FUNCTION api.attendance_by_subject(p_user TEXT, p_module TEXT DEFAULT NULL)
RETURNS TABLE (subject TEXT, type activity_type, total INT, presente INT, falta INT, justificada INT,
               pendente INT, registrados INT, pct INT, horas_falta NUMERIC, em_risco BOOLEAN)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
BEGIN
  PERFORM assert_acting_as(p_user);
  RETURN QUERY
  WITH g AS (
    SELECT subject,
           (array_agg(type ORDER BY date, start_time))[1] AS type,
           count(*)::int AS total,
           count(*) FILTER (WHERE status = 'presente')::int    AS presente,
           count(*) FILTER (WHERE status = 'falta')::int       AS falta,
           count(*) FILTER (WHERE status = 'justificada')::int AS justificada,
           count(*) FILTER (WHERE status = 'pendente')::int    AS pendente,
           coalesce(sum(hours) FILTER (WHERE status = 'falta'), 0) AS horas_falta
    FROM v_planner_events
    WHERE user_id = p_user AND is_academic AND (p_module IS NULL OR module = p_module)
    GROUP BY subject)
  SELECT subject, type, total, presente, falta, justificada, pendente,
         presente + falta + justificada,
         CASE WHEN presente + falta + justificada > 0
              THEN round((presente + justificada) * 100.0 / (presente + falta + justificada))::int END,
         round(horas_falta, 2),
         coalesce(round((presente + justificada) * 100.0 / nullif(presente + falta + justificada, 0)) < 75, FALSE)
  FROM g ORDER BY subject;
END $$;

-- pendingBefore L1069: acadêmicos já passados ainda sem registro
CREATE FUNCTION api.pending_checkins(p_user TEXT, p_before DATE DEFAULT current_date)
RETURNS SETOF planner_events LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
BEGIN
  PERFORM assert_acting_as(p_user);
  RETURN QUERY
  SELECT * FROM planner_events
  WHERE user_id = p_user AND deleted_at IS NULL AND is_academic(type)
    AND date < p_before AND status = 'pendente'
  ORDER BY date DESC, start_time;
END $$;

-- Regra §5.3 CORRIGIDA — há duas noções de "dia livre" no código:
--   is_empty_day             → zero eventos de qualquer tipo
--                              (card do dia L1110, "Dias sem evento" L1394,
--                               "dias sem atividade oficial restantes" L1342)
--   is_free_of_official      → nenhum evento acadêmico (isAcad)
--                              (check-in L1174/L1198, "dia livre" em Janelas
--                               livres L1510, motor de sugestões L1011)
-- MEDWAY/SIMULACAO/ACOLHIMENTO SÃO acadêmicos: Sáb 03/10 (só Medway) NÃO é livre.
CREATE FUNCTION api.day_overview(p_user TEXT, p_from DATE, p_to DATE)
RETURNS TABLE (date DATE, total_events INT, academic_events INT, academic_hours NUMERIC,
               is_empty_day BOOLEAN, is_free_of_official BOOLEAN)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
BEGIN
  PERFORM assert_acting_as(p_user);
  RETURN QUERY
  SELECT d::date,
         count(e.id)::int,
         count(e.id) FILTER (WHERE is_academic(e.type))::int,
         coalesce(sum(hours_between(e.start_time, e.end_time)) FILTER (WHERE is_academic(e.type)), 0),
         count(e.id) = 0,
         count(e.id) FILTER (WHERE is_academic(e.type)) = 0
  FROM generate_series(p_from, p_to, interval '1 day') d
  LEFT JOIN planner_events e ON e.user_id = p_user AND e.date = d::date AND e.deleted_at IS NULL
  GROUP BY d ORDER BY d;
END $$;

-- Card da Visão geral (L1342): dias do ciclo ativo, a partir de hoje, sem NENHUM evento
CREATE FUNCTION api.empty_days_remaining(p_user TEXT, p_today DATE DEFAULT current_date)
RETURNS INT LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
BEGIN
  PERFORM assert_acting_as(p_user);
  RETURN (SELECT count(*)::int FROM (
    SELECT gs::date AS d FROM enrollments en
    JOIN weeks w ON w.term_id = en.term_id
    CROSS JOIN LATERAL generate_series(w.start_date, w.end_date, interval '1 day') gs
    WHERE en.user_id = p_user AND en.is_active) days
  WHERE d >= p_today
    AND NOT EXISTS (SELECT 1 FROM planner_events e WHERE e.user_id = p_user AND e.date = days.d AND e.deleted_at IS NULL));
END $$;

-- Metas L1470-1472: gym = nº de eventos ACADEMIA na semana (qualquer status);
-- study = soma de HORAS de eventos ESTUDO na semana. Barras: min(x/meta, 100%).
CREATE FUNCTION api.weekly_goal_progress(p_user TEXT, p_week_id TEXT)
RETURNS TABLE (week_id TEXT, gym_done INT, gym_goal SMALLINT, gym_pct INT,
               study_hours_done NUMERIC, study_goal NUMERIC, study_pct INT)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
BEGIN
  PERFORM assert_acting_as(p_user);
  RETURN QUERY
  WITH w AS (SELECT * FROM weeks WHERE id = p_week_id),
       g AS (SELECT coalesce((SELECT gym_per_week FROM user_goals WHERE user_id = p_user), 4::smallint) AS gym,
                    coalesce((SELECT study_hours_per_week FROM user_goals WHERE user_id = p_user), 10) AS study),
       x AS (SELECT count(*) FILTER (WHERE e.type = 'ACADEMIA')::int AS gym_done,
                    coalesce(sum(hours_between(e.start_time, e.end_time)) FILTER (WHERE e.type = 'ESTUDO'), 0) AS study_done
             FROM w JOIN planner_events e ON e.user_id = p_user AND e.deleted_at IS NULL
                                         AND e.date BETWEEN w.start_date AND w.end_date)
  SELECT (SELECT id FROM w), x.gym_done, g.gym,
         CASE WHEN g.gym > 0 THEN least(round(x.gym_done * 100.0 / g.gym), 100)::int ELSE 100 END,
         round(x.study_done, 2), g.study,
         CASE WHEN g.study > 0 THEN least(round(x.study_done * 100.0 / g.study), 100)::int ELSE 100 END
  FROM x, g;
END $$;

-- Materializa a grade do ciclo no planner do aluno (seedState L959).
-- Idempotente: só cria o que ainda não existe (source_item_id).
CREATE FUNCTION api.enroll_user(p_user TEXT, p_term TEXT, p_student_code TEXT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE n INT; src plan_source;
BEGIN
  PERFORM assert_acting_as(p_user);
  SELECT source INTO src FROM terms WHERE id = p_term;
  IF src IS NULL THEN RAISE EXCEPTION 'ciclo % não existe', p_term USING ERRCODE = 'P0002'; END IF;
  UPDATE enrollments SET is_active = FALSE WHERE user_id = p_user AND term_id <> p_term AND is_active;
  INSERT INTO enrollments (user_id, term_id, student_code, is_active)
  VALUES (p_user, p_term, p_student_code, TRUE)
  ON CONFLICT (user_id, term_id) DO UPDATE SET is_active = TRUE,
    student_code = coalesce(EXCLUDED.student_code, enrollments.student_code);
  INSERT INTO user_goals (user_id) VALUES (p_user) ON CONFLICT DO NOTHING;
  INSERT INTO planner_events (id, user_id, term_id, source_item_id, date, start_time, end_time, type, title, origin)
  SELECT short_id(), p_user, p_term, si.id, si.date, si.start_time, si.end_time, si.type, si.title,
         CASE WHEN src = 'import' THEN 'import'::event_origin ELSE 'grade'::event_origin END
  FROM schedule_items si
  WHERE si.term_id = p_term
    AND NOT EXISTS (SELECT 1 FROM planner_events e
                    WHERE e.user_id = p_user AND e.source_item_id = si.id AND e.deleted_at IS NULL)
  ORDER BY si.position;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- "Restaurar agenda original" (L1804-1812): apaga edições e blocos pessoais,
-- volta à grade do ciclo ativo, zera anotações e metas (seedState).
CREATE FUNCTION api.restore_baseline(p_user TEXT) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE t TEXT;
BEGIN
  PERFORM assert_acting_as(p_user);
  SELECT term_id INTO t FROM enrollments WHERE user_id = p_user AND is_active;
  IF t IS NULL THEN RAISE EXCEPTION 'aluno % sem ciclo ativo', p_user USING ERRCODE = 'P0002'; END IF;
  UPDATE planner_events SET deleted_at = now() WHERE user_id = p_user AND deleted_at IS NULL;
  DELETE FROM week_notes WHERE user_id = p_user AND week_id IN (SELECT id FROM weeks WHERE term_id = t);
  INSERT INTO user_goals (user_id) VALUES (p_user)
  ON CONFLICT (user_id) DO UPDATE SET gym_per_week = 4, study_hours_per_week = 10;
  RETURN api.enroll_user(p_user, t);
END $$;

-- =====================================================================
-- WORKSPACE
-- =====================================================================

-- cria workspace + membership owner + convite (fluxo "Novo workspace" L2530-2540)
CREATE FUNCTION api.create_workspace(p_owner TEXT, p_name TEXT, p_description TEXT DEFAULT '',
                                     p_color TEXT DEFAULT 'estudo', p_icon TEXT DEFAULT '◍')
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE ws TEXT := short_id(); code TEXT := gen_invite_code();
BEGIN
  PERFORM assert_acting_as(p_owner);
  INSERT INTO workspaces (id, name, description, color, icon, owner_id, invite_code)
  VALUES (ws, btrim(p_name), coalesce(p_description, ''), p_color, p_icon, p_owner, code);
  INSERT INTO memberships (id, workspace_id, user_id, role) VALUES (short_id(), ws, p_owner, 'owner');
  INSERT INTO invites (id, workspace_id, code, created_by) VALUES (short_id(), ws, code, p_owner);
  RETURN ws;
END $$;

-- Garante que workspaces.invite_code aponte para um convite real
-- (a migração v3 do app gera código sem criar Invite quando w.invite falta, L2104/L2110).
CREATE FUNCTION ensure_workspace_invite(p_workspace TEXT) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE w workspaces; c TEXT;
BEGIN
  SELECT * INTO w FROM workspaces WHERE id = p_workspace AND deleted_at IS NULL;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF w.invite_code IS NOT NULL
     AND EXISTS (SELECT 1 FROM invites WHERE upper(code) = upper(w.invite_code) AND workspace_id = w.id) THEN
    RETURN w.invite_code;
  END IF;
  SELECT code INTO c FROM invites WHERE workspace_id = w.id AND status = 'active' ORDER BY created_at LIMIT 1;
  IF c IS NULL THEN
    c := CASE WHEN w.invite_code IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM invites WHERE upper(code) = upper(w.invite_code))
              THEN w.invite_code ELSE gen_invite_code() END;
    INSERT INTO invites (id, workspace_id, code, created_by) VALUES (short_id(), w.id, c, w.owner_id);
  END IF;
  PERFORM set_config('estudy.keep_updated_at', 'on', TRUE);
  UPDATE workspaces SET invite_code = c WHERE id = w.id AND invite_code IS DISTINCT FROM c;
  PERFORM set_config('estudy.keep_updated_at', '', TRUE);
  RETURN c;
END $$;

-- Invites.validate + redeem + Memberships.add (L2012-2042, L2555-2570)
-- retorno: {ok, reason?, workspaceId?, membershipId?, alreadyMember?}
-- reasons: not_found | inactive | expired | exhausted | workspace_not_found
CREATE FUNCTION api.redeem_invite(p_user TEXT, p_code TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE inv invites; m memberships;
BEGIN
  PERFORM assert_acting_as(p_user);
  INSERT INTO users (id) VALUES (p_user) ON CONFLICT DO NOTHING;     -- 1º acesso pode ser o resgate
  SELECT * INTO inv FROM invites WHERE upper(code) = upper(btrim(coalesce(p_code, ''))) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', FALSE, 'reason', 'not_found'); END IF;
  IF NOT EXISTS (SELECT 1 FROM workspaces WHERE id = inv.workspace_id AND deleted_at IS NULL) THEN
    RETURN jsonb_build_object('ok', FALSE, 'reason', 'workspace_not_found');
  END IF;
  -- já participa: entra direto, sem consumir o convite (L2555)
  SELECT * INTO m FROM memberships WHERE workspace_id = inv.workspace_id AND user_id = p_user AND status = 'active';
  IF FOUND THEN
    RETURN jsonb_build_object('ok', TRUE, 'alreadyMember', TRUE, 'workspaceId', inv.workspace_id, 'membershipId', m.id);
  END IF;
  IF inv.status = 'exhausted' THEN RETURN jsonb_build_object('ok', FALSE, 'reason', 'exhausted'); END IF;
  IF inv.status <> 'active'   THEN RETURN jsonb_build_object('ok', FALSE, 'reason', 'inactive');  END IF;
  IF inv.expires_at IS NOT NULL AND inv.expires_at < now() THEN
    RETURN jsonb_build_object('ok', FALSE, 'reason', 'expired');
  END IF;
  IF inv.max_uses IS NOT NULL AND inv.current_uses >= inv.max_uses THEN
    RETURN jsonb_build_object('ok', FALSE, 'reason', 'exhausted');
  END IF;

  UPDATE invites SET current_uses = current_uses + 1,
         status = CASE WHEN max_uses IS NOT NULL AND current_uses + 1 >= max_uses THEN 'exhausted'::invite_status ELSE status END
   WHERE id = inv.id;
  -- reentrada após remoção reativa a linha antiga em vez de duplicar
  UPDATE memberships SET status = 'active', role = 'member', invite_id = inv.id, joined_at = now()
   WHERE id = (SELECT id FROM memberships WHERE workspace_id = inv.workspace_id AND user_id = p_user
               ORDER BY joined_at DESC LIMIT 1)
  RETURNING * INTO m;
  IF NOT FOUND THEN
    INSERT INTO memberships (id, workspace_id, user_id, role, invite_id)
    VALUES (short_id(), inv.workspace_id, p_user, 'member', inv.id) RETURNING * INTO m;
  END IF;
  INSERT INTO invite_redemptions (invite_id, user_id, membership_id) VALUES (inv.id, p_user, m.id);
  RETURN jsonb_build_object('ok', TRUE, 'alreadyMember', FALSE, 'workspaceId', inv.workspace_id, 'membershipId', m.id);
END $$;

CREATE FUNCTION api.revoke_invite(p_user TEXT, p_invite TEXT) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE ws TEXT;
BEGIN
  PERFORM assert_acting_as(p_user);
  SELECT workspace_id INTO ws FROM invites WHERE id = p_invite;
  IF ws IS NULL THEN RETURN FALSE; END IF;
  IF NOT api.has_permission(p_user, ws, 'manageInvites') THEN
    RAISE EXCEPTION 'sem permissão manageInvites' USING ERRCODE = '42501';
  END IF;
  UPDATE invites SET status = 'revoked' WHERE id = p_invite AND status <> 'revoked';
  RETURN TRUE;
END $$;

-- o próprio membro edita a sua responsabilidade (L2658-2660, L2688) — única
-- coluna de memberships que ele altera sem manageMembers
CREATE FUNCTION api.set_my_responsibility(p_user TEXT, p_membership TEXT, p_text TEXT) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM assert_acting_as(p_user);
  UPDATE memberships SET responsibility = coalesce(p_text, '')
   WHERE id = p_membership AND user_id = p_user AND status = 'active';
  RETURN FOUND;
END $$;
