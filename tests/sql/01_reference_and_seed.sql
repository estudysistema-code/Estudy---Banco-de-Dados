-- Referência (constantes do código) e seed do ciclo 2026.2
BEGIN;
DO $$
DECLARE r RECORD;
BEGIN
  -- 9 tipos, isAcad (L977) igual à tabela
  ASSERT (SELECT count(*) FROM activity_type_meta) = 9, '9 tipos de atividade';
  ASSERT NOT EXISTS (SELECT 1 FROM activity_type_meta WHERE is_academic <> is_academic(type)),
    'is_academic() concorda com activity_type_meta';
  ASSERT (SELECT array_agg(type ORDER BY type::text) FROM activity_type_meta WHERE NOT is_academic)
         = ARRAY['ACADEMIA','ESTUDO','PESSOAL']::activity_type[], 'não acadêmicos = ACADEMIA/ESTUDO/PESSOAL';

  -- ciclo de 4 estados volta ao início
  ASSERT api.next_status(api.next_status(api.next_status(api.next_status('pendente')))) = 'pendente', 'ciclo de 4 estados';
  ASSERT api.next_status('pendente') = 'presente' AND api.next_status('presente') = 'falta'
     AND api.next_status('falta') = 'justificada', 'ordem do ciclo';

  -- matriz §4.4 exata
  ASSERT (SELECT count(*) FROM role_permissions) = 5, '5 papéis';
  ASSERT (SELECT array_agg(role ORDER BY sort_order) FROM role_permissions WHERE (permissions->>'deleteWorkspace')::bool)
         = ARRAY['owner']::member_role[], 'só owner apaga workspace';
  ASSERT (SELECT array_agg(role ORDER BY sort_order) FROM role_permissions WHERE (permissions->>'manageMembers')::bool)
         = ARRAY['owner','admin']::member_role[], 'manageMembers = owner/admin';
  ASSERT (SELECT array_agg(role ORDER BY sort_order) FROM role_permissions WHERE (permissions->>'manageTasks')::bool)
         = ARRAY['owner','admin','editor','member']::member_role[], 'manageTasks sem viewer';
  ASSERT (SELECT bool_and((permissions->>'comment')::bool AND (permissions->>'view')::bool) FROM role_permissions),
    'todos comentam e veem';
  ASSERT permissions_for('viewer') ->> 'manageEvents' = 'false', 'viewer não gerencia eventos';

  -- seed
  ASSERT (SELECT count(*) FROM weeks WHERE term_id = '2026.2') = 20, '20 semanas';
  ASSERT (SELECT min(code) || '..' || max(code) FROM weeks WHERE term_id = '2026.2') = 'S02..S21', 'S02..S21';
  ASSERT (SELECT min(start_date) FROM weeks WHERE term_id = '2026.2') = '2026-07-27', 'início 27/07';
  ASSERT (SELECT max(end_date) FROM weeks WHERE term_id = '2026.2') = '2026-12-13', 'fim 13/12';
  ASSERT (SELECT count(*) FROM weeks WHERE term_id = '2026.2' AND module = 'SMI' AND code BETWEEN 'S02' AND 'S11') = 10, 'S02–S11 = SMI';
  ASSERT (SELECT count(*) FROM weeks WHERE term_id = '2026.2' AND module = 'SA'  AND code BETWEEN 'S12' AND 'S21') = 10, 'S12–S21 = SA';
  ASSERT (SELECT count(*) FROM schedule_items WHERE term_id = '2026.2') = 160, '160 itens de grade';
  ASSERT (SELECT string_agg(to_char(date,'DD/MM') || ' ' || title, ' · ' ORDER BY date) FROM schedule_items WHERE type = 'PROVA')
         = '31/07 Prova AVD · 14/08 Prova AV1 · 04/09 Prova AV2 · 18/10 Prova AV3 · 08/11 Prova AV4', 'provas nas datas reais';
  -- composição da grade (auditoria: CAMPO 106, TEORIA 37, SIMULACAO 6, PROVA 5, MEDWAY 5, ACOLHIMENTO 1)
  ASSERT (SELECT jsonb_object_agg(type, n) FROM (SELECT type, count(*) n FROM schedule_items GROUP BY type) x)
         = '{"CAMPO":106,"TEORIA":37,"SIMULACAO":6,"PROVA":5,"MEDWAY":5,"ACOLHIMENTO":1}'::jsonb, 'composição da grade';
  -- todo item cai dentro de uma semana do ciclo
  ASSERT NOT EXISTS (SELECT 1 FROM schedule_items si WHERE NOT EXISTS
    (SELECT 1 FROM weeks w WHERE w.term_id = si.term_id AND si.date BETWEEN w.start_date AND w.end_date)), 'itens dentro das semanas';

  -- subjectOf (L708)
  ASSERT subject_of('Pré/Pós GO Cirurgia (Dra Tayná)') = 'Pré/Pós GO Cirurgia', 'subject remove parênteses';
  ASSERT subject_of('Simulação Ped (Prof. Bruno) — Tema 1') = 'Simulação Ped', 'subject remove tema';
  ASSERT subject_of('  Teoria   GO ') = 'Teoria GO', 'subject colapsa espaços';

  -- regra §5.1: nenhuma FK entre planner e workspace
  ASSERT NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.contype = 'f'
      AND ((c.conrelid::regclass::text IN ('planner_events','week_notes','user_goals')
            AND c.confrelid::regclass::text IN ('workspaces','memberships','invites','workspace_events','tasks','assets','activities'))
        OR (c.confrelid::regclass::text IN ('planner_events','week_notes','user_goals')
            AND c.conrelid::regclass::text IN ('workspaces','memberships','invites','workspace_events','tasks','assets','activities')))),
    'planner e workspace sem FK cruzada';
  RAISE NOTICE 'ok 01 — referência e seed';
END $$;
ROLLBACK;
