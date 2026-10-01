-- API de sincronização (ns_put / ns_get) em runtime — inclui os ataques da revisão adversarial
BEGIN;
INSERT INTO users (id, display_name) VALUES ('s_dona','Dona'), ('s_vic','Vic'), ('s_bia','Bia'), ('s_att','Atacante');
INSERT INTO identities (user_id, username, provider) VALUES ('s_bia', 'bia.real', 'email');

CREATE FUNCTION pg_temp.as_user(u TEXT) RETURNS VOID LANGUAGE sql AS $$ SELECT set_config('estudy.user_id', u, true) $$;

DO $$
DECLARE r JSONB; g JSONB;
BEGIN
  PERFORM pg_temp.as_user('s_dona');
  -- versão errada / forma errada são recusadas (payload parcial nunca apaga dados)
  BEGIN
    PERFORM api.ns_put('s_dona', 'planner', '{"v":1,"at":"2026-09-30T10:00:00.000Z","data":{"events":[]}}');
    ASSERT FALSE, 'v1 deveria ser recusado';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM api.ns_put('s_dona', 'planner', '{"v":2,"at":"2026-09-30T10:00:00.000Z","data":{"goals":{"gym":4}}}');
    ASSERT FALSE, 'planner sem events deveria ser recusado';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM api.ns_put('s_dona', 'identity', '{"v":2,"at":"2026-09-30T10:00:00.000Z","data":null}');
    ASSERT FALSE, 'identity data:null deveria ser recusado';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM api.ns_put('s_dona', 'identity', '{"v":2,"at":"2026-09-30T10:00:00.000Z","data":{"userId":"s_vic"}}');
    ASSERT FALSE, 'identity alheia deveria falhar';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  -- planner: sem status → pendente; done:true → presente; horário vazio e tipos lixo viram skipped, não erro
  r := api.ns_put('s_dona', 'planner', $j${"v":2,"at":"2026-09-30T10:00:00.000Z","data":{
        "events":[
          {"id":"p1","date":"2026-10-05","start":"07:00","end":"13:00","type":"CAMPO","title":"Enfermaria Clínica Médica","note":"","done":false,"custom":false},
          {"id":"p2","date":"2026-10-05","start":"13:00","end":"19:00","type":"CAMPO","title":"CR Aparelho Digestivo","note":"","done":true,"custom":false},
          {"id":"p3","date":"2026-10-06","start":"08:00","end":"09:15","type":"ACADEMIA","title":"Academia","note":"sugestão automática","done":false,"custom":true},
          {"id":"p4","date":"2026-10-06","start":"","end":"","type":"ESTUDO","title":"quebrado","note":"","status":"pendente","custom":true},
          {"id":"p5","date":"2026-10-07","start":"08:00","end":"09:00","type":"ESTUDO","title":"lixo","note":"","done":"x","custom":"sim"},
          "não sou objeto"],
        "notes":{"S12":"primeira semana SA"}, "goals":{"gym":"abc","study":12.5}}}$j$);
  ASSERT (r->>'applied')::bool AND (r->>'events')::int = 4, 'item ruim não derruba o namespace';
  ASSERT (SELECT status FROM planner_events WHERE id = 'p1') = 'pendente', 'sem status → pendente';
  ASSERT (SELECT status FROM planner_events WHERE id = 'p2') = 'presente', 'done:true → presente';
  ASSERT (SELECT origin FROM planner_events WHERE id = 'p3') = 'sugestao', 'note de sugestão → origin sugestao';
  ASSERT (SELECT title = 'lixo' AND NOT custom FROM planner_events WHERE id = 'p5'), 'custom lixo → false';
  ASSERT (SELECT source_item_id FROM planner_events WHERE id = 'p1') IS NOT NULL, 'evento da grade ligado ao item oficial';
  ASSERT (SELECT gym_per_week FROM user_goals WHERE user_id = 's_dona') = 4, 'gym "abc" → padrão';
  g := api.ns_get('s_dona', 'planner');
  ASSERT g->'data'->'notes' = '{"S12":"primeira semana SA"}' AND g->'data'->'goals' = '{"gym":4,"study":12.5}', 'notas e metas voltam';
  ASSERT (SELECT bool_and((e->>'done')::bool = (e->>'status' = 'presente')) FROM jsonb_array_elements(g->'data'->'events') e),
    'done legado derivado do status';

  -- evento que sumiu do payload → exclusão lógica
  r := api.ns_put('s_dona', 'planner', $j${"v":2,"at":"2026-09-30T10:05:00.000Z","data":{"events":[
          {"id":"p1","date":"2026-10-05","start":"07:00","end":"13:00","type":"CAMPO","title":"Enfermaria Clínica Médica","note":"","status":"falta","custom":false}],
        "notes":{}, "goals":{"gym":5,"study":12.5}}}$j$);
  ASSERT (r->>'softDeleted')::int = 3, 'p2, p3 e p5 excluídos logicamente';
  -- envelope mais antigo que o último gravado é recusado (last-write-wins)
  r := api.ns_put('s_dona', 'planner', '{"v":2,"at":"2026-09-30T09:00:00.000Z","data":{"events":[]}}');
  ASSERT NOT (r->>'applied')::bool AND r->>'reason' = 'stale', 'stale recusado';
  ASSERT (SELECT count(*) FROM planner_events WHERE user_id = 's_dona' AND deleted_at IS NULL) = 1, 'nada mudou';
  -- relógio adiantado não trava o namespace (M3)
  r := api.ns_put('s_dona', 'planner', '{"v":2,"at":"2031-01-01T00:00:00.000Z","data":{"events":[{"id":"p1","date":"2026-10-05","start":"07:00","end":"13:00","type":"CAMPO","title":"Enfermaria Clínica Médica","status":"falta","custom":false}]}}');
  ASSERT (SELECT client_at < now() + interval '6 minutes' FROM sync_state WHERE user_id = 's_dona' AND namespace = 'planner'), 'at futuro limitado';

  -- workspace novo: quem cria é dono — mesmo que o payload diga outro ownerId (M1)
  r := api.ns_put('s_dona', 'workspace', $j${"v":3,"at":"2026-09-30T10:00:00.000Z","data":{"workspaces":[{
        "id":"ws1","name":"Monitoria Ped","description":"","color":"var(--teoria)","icon":"◆","ownerId":"s_vic",
        "inviteCode":"ESTUDY-T3ST","createdAt":"2026-09-30T10:00:00.000Z","updatedAt":"2026-09-30T10:00:00.000Z","dirty":true,
        "events":[], "files":[{"id":"f1","name":"a.gif","size":1,"ext":"gif","addedBy":"s_dona","addedAt":"2026-09-30T10:00:00.000Z","aiStatus":"pendente","stored":false},
                             {"id":"f2","name":"b.pdf","size":"abc","ext":"pdf","addedBy":"s_vic","addedAt":"2026-09-30T10:00:00.000Z","aiStatus":"concluido","stored":true}],
        "comments":[],
        "tasks":[{"id":"tk1","title":"Escala","desc":"","assignee":null,"due":null,"status":"aberta","comments":[],"createdBy":"s_dona","createdAt":"2026-09-30T10:00:00.000Z"}]}]}}$j$);
  ASSERT (SELECT owner_id FROM workspaces WHERE id = 'ws1') = 's_dona', 'ownerId do payload ignorado em runtime';
  ASSERT (SELECT color FROM workspaces WHERE id = 'ws1') = 'teoria', 'cor gravada como token';
  ASSERT EXISTS (SELECT 1 FROM invites WHERE code = 'ESTUDY-T3ST' AND workspace_id = 'ws1'), 'inviteCode ganhou convite real';
  ASSERT r->'skipped'->0->>'reason' = 'ext_not_allowed', 'gif recusado (regra §5.4)';
  ASSERT (SELECT added_by = 's_dona' AND size_bytes = 0 AND ai_status = 'pendente' AND NOT stored FROM assets WHERE id = 'f2'),
    'autor = sessão; size lixo → 0; ai_status/stored não vêm do cliente';
  r := api.ns_put('s_dona', 'memberships', $j${"v":1,"at":"2026-09-30T10:00:00.000Z","data":{"items":[
        {"id":"ms1","workspaceId":"ws1","userId":"s_dona","role":"owner","responsibility":"","joinedAt":"2026-09-30T10:00:00.000Z","status":"active","permissions":{}},
        {"id":"ms2","workspaceId":"ws1","userId":"s_vic","role":"viewer","responsibility":"","joinedAt":"2026-09-30T10:00:00.000Z","status":"active","permissions":{"deleteWorkspace":true}},
        {"id":"ms3","workspaceId":"ws1","userId":"s_bia","role":"member","responsibility":"","joinedAt":"2026-09-30T10:00:00.000Z","status":"active","permissions":{}},
        {"id":"ms4","workspaceId":"ws1","userId":"s_att","role":"owner","responsibility":"","joinedAt":"2026-09-30T10:00:00.000Z","status":"active","permissions":{}}]}}$j$);
  ASSERT (r->>'memberships')::int = 3, 'dono adiciona membros';
  ASSERT (SELECT NOT (permissions->>'deleteWorkspace')::bool FROM memberships WHERE id = 'ms2'), 'permissões do cliente ignoradas';
  ASSERT NOT EXISTS (SELECT 1 FROM memberships WHERE id = 'ms4'), 'ninguém além do dono vira owner';

  -- Bia (member) baixa o workspace; depois a dona cria e edita tarefas
  PERFORM pg_temp.as_user('s_bia');
  g := api.ns_get('s_bia', 'workspace');
  -- tudo aqui roda numa transação só (now() congelado): simula o GET da Bia 1 minuto antes
  UPDATE sync_state SET pulled_at = now() - interval '1 minute' WHERE user_id = 's_bia' AND namespace = 'workspace';
  PERFORM pg_temp.as_user('s_dona');
  r := api.ns_put('s_dona', 'workspace', $j${"v":3,"at":"2026-09-30T10:06:00.000Z","data":{"workspaces":[{
        "id":"ws1","name":"Monitoria Ped","description":"","color":"var(--teoria)","icon":"◆","ownerId":"s_dona",
        "createdAt":"2026-09-30T10:00:00.000Z","updatedAt":"2026-09-30T10:06:00.000Z","events":[],"comments":[],
        "files":[{"id":"f2","name":"b.pdf","size":1,"ext":"pdf","addedBy":"s_dona","addedAt":"2026-09-30T10:00:00.000Z"}],
        "tasks":[{"id":"tk1","title":"Escala v2","desc":"","assignee":null,"due":null,"status":"aberta","comments":[],"createdBy":"s_dona","createdAt":"2026-09-30T10:00:00.000Z"},
                 {"id":"tk2","title":"URGENTE","desc":"","assignee":"s_bia","due":null,"status":"aberta","comments":[],"createdBy":"s_dona","createdAt":"2026-09-30T10:06:00.000Z"}]}]}}$j$);
  -- Bia envia a cópia ANTIGA (sem tk2, tk1 com o título velho) → não apaga nem sobrescreve (A7)
  PERFORM pg_temp.as_user('s_bia');
  r := api.ns_put('s_bia', 'workspace', $j${"v":3,"at":"2026-09-30T10:07:00.000Z","data":{"workspaces":[{
        "id":"ws1","name":"Monitoria Ped","description":"","color":"var(--teoria)","icon":"◆","ownerId":"s_dona",
        "createdAt":"2026-09-30T10:00:00.000Z","updatedAt":"2026-09-30T10:07:00.000Z","events":[],"comments":[],"files":[],
        "tasks":[{"id":"tk1","title":"Escala","desc":"","assignee":null,"due":null,"status":"aberta","comments":[],"createdBy":"s_dona","createdAt":"2026-09-30T10:00:00.000Z"},
                 {"id":"tk3","title":"minha","desc":"","assignee":null,"due":null,"status":"aberta","comments":[],"createdBy":"s_dona","createdAt":"2026-09-30T10:07:00.000Z"}]}]}}$j$);
  ASSERT (SELECT deleted_at IS NULL FROM tasks WHERE id = 'tk2'), 'tarefa nova da dona sobrevive à cópia antiga da bia';
  ASSERT (SELECT title FROM tasks WHERE id = 'tk1') = 'Escala v2', 'edição mais nova da dona não é sobrescrita';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'skipped') s WHERE s->>'reason' = 'conflict_newer_on_server'), 'conflito reportado';
  ASSERT (SELECT created_by FROM tasks WHERE id = 'tk3') = 's_bia', 'autor da tarefa = sessão (M1)';
  ASSERT (SELECT deleted_at IS NULL FROM assets WHERE id = 'f2'), 'arquivo da dona não some pela cópia da bia';
  -- bia apaga a própria tarefa (omitindo-a) → vale
  r := api.ns_put('s_bia', 'workspace', $j${"v":3,"at":"2026-09-30T10:08:00.000Z","data":{"workspaces":[{
        "id":"ws1","name":"Monitoria Ped","description":"","color":"var(--teoria)","icon":"◆","ownerId":"s_dona",
        "events":[],"comments":[],"files":[],
        "tasks":[{"id":"tk1","title":"Escala v2","desc":"","assignee":null,"due":null,"status":"aberta","comments":[]},
                 {"id":"tk2","title":"URGENTE","desc":"","assignee":"s_bia","due":null,"status":"aberta","comments":[]}]}]}}$j$);
  ASSERT (SELECT deleted_at IS NOT NULL FROM tasks WHERE id = 'tk3'), 'bia apaga o que ela mesma criou';

  -- ataques de membership/convite por id de outro workspace (C1/C2) e de perfil (C3)
  PERFORM pg_temp.as_user('s_att');
  r := api.ns_put('s_att', 'workspace', $j${"v":3,"at":"2026-09-30T10:00:00.000Z","data":{"workspaces":[{
        "id":"wx","name":"Meu","ownerId":"s_att","events":[],"tasks":[],"files":[],"comments":[]}]}}$j$);
  r := api.ns_put('s_att', 'memberships', $j${"v":1,"at":"2026-09-30T10:01:00.000Z","data":{"items":[
        {"id":"ms2","workspaceId":"wx","userId":"s_att","role":"admin","status":"active"},
        {"id":"ms3","workspaceId":"wx","userId":"s_bia","role":"member","status":"removed"}]}}$j$);
  ASSERT (SELECT role = 'viewer' AND user_id = 's_vic' FROM memberships WHERE id = 'ms2'), 'membership alheia intacta (id_conflict)';
  ASSERT (SELECT status = 'active' FROM memberships WHERE id = 'ms3'), 'bia não foi removida pelo atacante';
  r := api.ns_put('s_att', 'invites', $j${"v":1,"at":"2026-09-30T10:01:00.000Z","data":{"items":[
        {"id":"inv_x","workspaceId":"wx","code":"ESTUDY-T3ST","status":"active"}]}}$j$);
  ASSERT (SELECT workspace_id FROM invites WHERE upper(code) = 'ESTUDY-T3ST') = 'ws1', 'código de outro workspace não é tomado';
  r := api.ns_put('s_att', 'users', $j${"v":1,"at":"2026-09-30T10:01:00.000Z","data":{"byId":{
        "s_bia":{"displayName":"HACKEADO","avatarUrl":"https://evil/x.png","updatedAt":"2099-01-01T00:00:00.000Z"},
        "s_att":{"displayName":"Eu","avatarUrl":"x); background:url(https://evil","updatedAt":"2099-01-01T00:00:00.000Z"}}}}$j$);
  ASSERT (SELECT display_name FROM users WHERE id = 's_bia') = 'Bia', 'perfil alheio intacto (C3)';
  ASSERT (SELECT display_name = 'Eu' AND avatar_url IS NULL FROM users WHERE id = 's_att'), 'avatar inseguro descartado';
  -- ns_put do dono não pode ser aproveitado para tomar posse (C7): admin/owner_id não mudam
  r := api.ns_put('s_att', 'workspace', $j${"v":3,"at":"2026-09-30T10:02:00.000Z","data":{"workspaces":[{
        "id":"ws1","name":"TOMADO","ownerId":"s_att","events":[],"tasks":[],"files":[],"comments":[]},
        {"id":"wx","name":"Meu","ownerId":"s_att","events":[],"tasks":[],"files":[],"comments":[]}]}}$j$);
  ASSERT (SELECT name = 'Monitoria Ped' AND owner_id = 's_dona' FROM workspaces WHERE id = 'ws1'), 'não membro não mexe no ws1';

  -- viewer tenta mudar a tarefa e renomear o workspace pelo sync → banco não aplica
  PERFORM pg_temp.as_user('s_vic');
  r := api.ns_put('s_vic', 'workspace', $j${"v":3,"at":"2026-09-30T10:10:00.000Z","data":{"workspaces":[{
        "id":"ws1","name":"HACK","description":"","color":"var(--teoria)","icon":"◆","ownerId":"s_vic",
        "events":[], "files":[], "comments":[{"id":"cm1","author":"s_dona","text":"posso?","at":"2026-09-30T10:10:00.000Z","parentId":null}],
        "tasks":[{"id":"tk1","title":"Mudei","desc":"","assignee":null,"due":null,"status":"concluida","comments":[]}]}]}}$j$);
  ASSERT (SELECT name FROM workspaces WHERE id = 'ws1') = 'Monitoria Ped', 'viewer não renomeia';
  ASSERT (SELECT title FROM tasks WHERE id = 'tk1') = 'Escala v2', 'viewer não edita tarefa';
  ASSERT (SELECT author_id FROM activities WHERE id = 'cm1') = 's_vic', 'viewer comenta, mas sempre como ele mesmo';
  ASSERT jsonb_array_length(r->'readOnly') >= 2, 'relatório aponta seções somente leitura';
  r := api.ns_put('s_vic', 'memberships', $j${"v":1,"at":"2026-09-30T10:10:00.000Z","data":{"items":[
        {"id":"ms2","workspaceId":"ws1","userId":"s_vic","role":"admin","responsibility":"Escalas","status":"active","permissions":{}}]}}$j$);
  ASSERT (SELECT role FROM memberships WHERE id = 'ms2') = 'viewer', 'viewer não se promove';
  ASSERT (SELECT responsibility FROM memberships WHERE id = 'ms2') = 'Escalas', 'mas edita a própria responsabilidade';
  BEGIN
    PERFORM api.ns_get('s_dona', 'planner');
    ASSERT FALSE, 'vic não lê o planner da dona';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  ASSERT jsonb_array_length(api.ns_get('s_vic', 'workspace')->'data'->'workspaces') = 1, 'vic vê o workspace dele';
  ASSERT jsonb_array_length(api.ns_get('s_vic', 'planner')->'data'->'events') = 0, 'planner da vic vazio';

  -- dono tira o workspace do payload → exclusão lógica (só dono)
  PERFORM pg_temp.as_user('s_dona');
  r := api.ns_put('s_dona', 'workspace', '{"v":3,"at":"2026-09-30T10:20:00.000Z","data":{"workspaces":[]}}');
  ASSERT (r->>'softDeleted')::int = 1 AND (SELECT deleted_at IS NOT NULL FROM workspaces WHERE id = 'ws1'), 'dono apaga';
  PERFORM pg_temp.as_user('s_vic');
  ASSERT jsonb_array_length(api.ns_get('s_vic', 'workspace')->'data'->'workspaces') = 0, 'some para todos';
  RAISE NOTICE 'ok 05 — API de sync (inclui ataques da revisão)';
END $$;
ROLLBACK;
