-- Regras de negócio do PLANNER (§5.2, §5.3, §5.8, §5.9, §5.10)
BEGIN;
INSERT INTO users (id, display_name) VALUES ('t_ana', 'Ana'), ('t_bia', 'Bia');
SELECT set_config('estudy.user_id', 't_ana', true);
SELECT api.enroll_user('t_ana', '2026.2', 'ALUNO_T1');

DO $$
DECLARE e1 TEXT; e2 TEXT; e3 TEXT; e4 TEXT; s presence_status; n INT; r RECORD; ev_before INT;
BEGIN
  ASSERT (SELECT count(*) FROM planner_events WHERE user_id = 't_ana') = 160, 'matrícula materializa 160 eventos';
  ASSERT api.enroll_user('t_ana', '2026.2') = 0, 'matrícula é idempotente';
  ASSERT (SELECT bool_and(NOT custom AND origin = 'grade' AND status = 'pendente' AND source_item_id IS NOT NULL)
          FROM planner_events WHERE user_id = 't_ana'), 'grade: custom=false, pendente, ligada ao item';
  ASSERT (SELECT gym_per_week = 4 AND study_hours_per_week = 10 FROM user_goals WHERE user_id = 't_ana'), 'metas padrão 4 / 10h';
  ASSERT (SELECT student_code FROM enrollments WHERE user_id = 't_ana') = 'ALUNO_T1', 'student_code na matrícula';

  -- §5.2 presença: ciclo de 4 estados
  SELECT id INTO e1 FROM planner_events WHERE user_id = 't_ana' AND date = '2026-07-28';           -- Egressos Neo
  ASSERT api.cycle_attendance('t_ana', e1) = 'presente', 'ciclo 1';
  ASSERT (SELECT attendance_marked_at IS NOT NULL FROM planner_events WHERE id = e1), 'carimbo do check-in';
  ASSERT api.cycle_attendance('t_ana', e1) = 'falta', 'ciclo 2';
  ASSERT api.cycle_attendance('t_ana', e1) = 'justificada', 'ciclo 3';
  ASSERT api.cycle_attendance('t_ana', e1) = 'pendente', 'ciclo 4 volta a pendente';
  ASSERT (SELECT attendance_marked_at IS NULL FROM planner_events WHERE id = e1), 'pendente limpa o carimbo';
  -- idempotência: marcar o mesmo status duas vezes não gera novo evento de domínio
  PERFORM api.set_attendance('t_ana', e1, 'presente');
  SELECT count(*) INTO ev_before FROM domain_events WHERE aggregate_id = e1 AND name = 'planner.attendance.recorded';
  PERFORM api.set_attendance('t_ana', e1, 'presente');
  ASSERT (SELECT count(*) FROM domain_events WHERE aggregate_id = e1 AND name = 'planner.attendance.recorded') = ev_before,
    'set_attendance idempotente';
  BEGIN
    UPDATE planner_events SET status = 'true' WHERE id = e1;
    ASSERT FALSE, 'booleano em status deveria falhar';
  EXCEPTION WHEN invalid_text_representation THEN NULL;
  END;

  -- estatística (stats L1050): presente + justificada / registrados
  SELECT id INTO e2 FROM planner_events WHERE user_id = 't_ana' AND date = '2026-07-29' AND start_time = '07:00'; -- Cardio Ped 6h
  SELECT id INTO e3 FROM planner_events WHERE user_id = 't_ana' AND date = '2026-07-29' AND start_time = '13:00'; -- 6h
  SELECT id INTO e4 FROM planner_events WHERE user_id = 't_ana' AND date = '2026-07-30';                           -- Radiologia
  PERFORM api.set_attendance('t_ana', e2, 'falta');
  PERFORM api.set_attendance('t_ana', e3, 'falta');
  PERFORM api.set_attendance('t_ana', e4, 'justificada');
  SELECT * INTO r FROM api.attendance_stats('t_ana');
  ASSERT r.registrados = 4 AND r.presente = 1 AND r.falta = 2 AND r.justificada = 1, 'contagens';
  ASSERT r.pct = 50 AND r.em_risco, 'pct 50% e em risco (<75)';
  ASSERT r.horas_falta = 12, '12h de falta';
  ASSERT (SELECT pct FROM api.attendance_stats('t_ana', 'SA')) IS NULL, 'SA sem registros → pct NULL';
  ASSERT (SELECT registrados FROM api.attendance_by_subject('t_ana') WHERE subject = 'Pré/Pós GO Cirurgia') = 1,
    'presença por matéria agrupa pelo subject';
  ASSERT (SELECT count(*) FROM api.pending_checkins('t_ana', '2026-07-31')) = 3, 'pendentes antes de 31/07';
  PERFORM set_config('estudy.user_id', 't_bia', TRUE);
  BEGIN
    PERFORM * FROM api.attendance_stats('t_ana');
    ASSERT FALSE, 'bia não lê estatística da ana (C5)';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('estudy.user_id', 't_ana', TRUE);

  -- §5.3 dia livre: DUAS definições
  SELECT * INTO r FROM api.day_overview('t_ana', '2026-10-03', '2026-10-03');  -- sábado só com Medway
  ASSERT NOT r.is_empty_day AND NOT r.is_free_of_official, 'Medway conta como atividade oficial (isAcad)';
  SELECT * INTO r FROM api.day_overview('t_ana', '2026-10-04', '2026-10-04');  -- domingo vazio
  ASSERT r.is_empty_day AND r.is_free_of_official, 'domingo vazio é livre nos dois sentidos';
  INSERT INTO planner_events (id, user_id, date, start_time, end_time, type, title, origin)
  VALUES ('t_estudo', 't_ana', '2026-10-04', '09:45', '11:45', 'ESTUDO', 'Bloco de estudo', 'sugestao');
  SELECT * INTO r FROM api.day_overview('t_ana', '2026-10-04', '2026-10-04');
  ASSERT NOT r.is_empty_day AND r.is_free_of_official, 'dia só com ESTUDO: não vazio, mas sem atividade oficial';

  -- §5.9 custom deriva da origem
  ASSERT (SELECT custom FROM planner_events WHERE id = 't_estudo'), 'sugestão é custom';
  -- metas: ESTUDO soma horas, ACADEMIA conta eventos (L1470)
  INSERT INTO planner_events (id, user_id, date, start_time, end_time, type, title, origin) VALUES
    ('t_gym1', 't_ana', '2026-09-28', '06:00', '07:00', 'ACADEMIA', 'Academia', 'manual'),
    ('t_gym2', 't_ana', '2026-09-29', '06:00', '07:15', 'ACADEMIA', 'Academia', 'manual');
  SELECT * INTO r FROM api.weekly_goal_progress('t_ana', '2026.2:S11');
  ASSERT r.gym_done = 2 AND r.gym_pct = 50, 'academia = contagem';
  ASSERT r.study_hours_done = 2 AND r.study_pct = 20, 'estudo = horas (2h de 10h)';

  -- restaurar agenda original: some o custom, volta a grade, zera notas e metas
  INSERT INTO week_notes VALUES ('t_ana', '2026.2:S11', 'revisar ECG');
  UPDATE user_goals SET gym_per_week = 6 WHERE user_id = 't_ana';
  ASSERT api.restore_baseline('t_ana') = 160, 'restore recria 160';
  ASSERT (SELECT count(*) FROM planner_events WHERE user_id = 't_ana' AND deleted_at IS NULL) = 160, 'só a grade viva';
  ASSERT (SELECT count(*) FROM planner_events WHERE user_id = 't_ana' AND deleted_at IS NULL AND status <> 'pendente') = 0, 'presenças zeradas';
  ASSERT NOT EXISTS (SELECT 1 FROM week_notes WHERE user_id = 't_ana'), 'notas zeradas';
  ASSERT (SELECT gym_per_week FROM user_goals WHERE user_id = 't_ana') = 4, 'metas voltam ao padrão';

  -- integridade
  BEGIN
    INSERT INTO planner_events (id, user_id, date, start_time, end_time, type, title) VALUES ('t_bad', 't_ana', '2026-10-01', '10:00', '10:00', 'ESTUDO', 'x');
    ASSERT FALSE, 'fim = início deveria falhar no planner';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO users (id) VALUES ('u_me');
    ASSERT FALSE, 'u_me deveria falhar';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO user_goals (user_id, gym_per_week) VALUES ('t_bia', 9);
    ASSERT FALSE, 'meta de academia > 7 deveria falhar';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- acting-as: um usuário não mexe no planner do outro
  PERFORM set_config('estudy.user_id', 't_bia', TRUE);
  BEGIN
    PERFORM api.cycle_attendance('t_ana', e1);
    ASSERT FALSE, 'bia não pode ciclar presença da ana';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('estudy.user_id', 't_ana', TRUE);
  -- sem usuário na sessão, nenhuma função age em nome de ninguém (C4)
  PERFORM set_config('estudy.user_id', '', TRUE);
  BEGIN
    PERFORM api.cycle_attendance('t_ana', e1);
    ASSERT FALSE, 'sem GUC deveria falhar';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('estudy.user_id', 't_ana', TRUE);

  -- outbox recebeu os eventos do planner
  ASSERT EXISTS (SELECT 1 FROM domain_events WHERE name = 'planner.event.created' AND user_id = 't_ana'), 'outbox created';
  ASSERT EXISTS (SELECT 1 FROM domain_events WHERE name = 'planner.event.deleted' AND user_id = 't_ana'), 'outbox deleted';
  RAISE NOTICE 'ok 02 — regras do planner';
END $$;
ROLLBACK;
