-- =====================================================================
-- ESTUDY · 0010 — API de sincronização por namespace (contrato do Store)
-- ---------------------------------------------------------------------
-- O app grava 6 namespaces como envelope {v, at, data} (§2). Estas funções
-- são o "ponto de encaixe" da §8.3: o adaptador de rede troca
-- window.storage.get/set por
--     GET  /ns/:name  → SELECT api.ns_get(:user, :name)
--     PUT  /ns/:name  → SELECT api.ns_put(:user, :name, :envelope)
-- sem tocar em componente nenhum do front.
--
-- api.ns_put     runtime (estudy_app). Aplica a matriz §4.4, autoria = usuário
--                da sessão, protege o que OUTRO membro mudou depois do seu GET.
-- api.ns_import  carga inicial do localStorage (só estudy_admin). Confia no
--                aparelho: preserva autores, donos e workspaces de terceiros.
-- api.ns_get     remonta o envelope no shape EXATO que o app lê e marca o GET.
--
-- Cada item é processado num sub-bloco: item ruim vira `skipped` no relatório
-- em vez de derrubar o namespace inteiro (o app perderia a gravação calado,
-- porque io.set engole erros, L437).
-- Conflito: last-write-wins por namespace (§8.4) + proteção por linha no workspace.
-- =====================================================================

CREATE FUNCTION ns_schema_version(p_ns TEXT) RETURNS SMALLINT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_ns WHEN 'identity' THEN 2 WHEN 'users' THEN 1 WHEN 'planner' THEN 2
                   WHEN 'workspace' THEN 3 WHEN 'memberships' THEN 1 WHEN 'invites' THEN 1 END::smallint
$$;

-- ---------- conversores tolerantes (nunca lançam) ----------
CREATE FUNCTION try_date(t TEXT) RETURNS DATE LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF t IS NULL OR t !~ '^\d{4}-\d{2}-\d{2}$' THEN RETURN NULL; END IF;
  RETURN t::date;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE FUNCTION try_time(t TEXT) RETURNS TIME LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF t IS NULL OR t !~ '^\d{1,2}:\d{2}(:\d{2})?$' THEN RETURN NULL; END IF;
  RETURN t::time;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE FUNCTION try_ts(t TEXT) RETURNS TIMESTAMPTZ LANGUAGE plpgsql STABLE AS $$
DECLARE r TIMESTAMPTZ;
BEGIN
  IF t IS NULL OR t = '' THEN RETURN NULL; END IF;
  r := t::timestamptz;
  RETURN CASE WHEN r BETWEEN '2000-01-01' AND '2200-01-01' THEN r END;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE FUNCTION try_bool(j JSONB) RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN jsonb_typeof(j) = 'boolean' THEN (j #>> '{}')::boolean END
$$;

CREATE FUNCTION try_num(j JSONB) RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF jsonb_typeof(j) = 'number' THEN RETURN (j #>> '{}')::numeric; END IF;
  IF jsonb_typeof(j) = 'string' AND (j #>> '{}') ~ '^\s*-?\d+(\.\d+)?\s*$' THEN RETURN (j #>> '{}')::numeric; END IF;
  RETURN NULL;
END $$;

CREATE FUNCTION try_int(j JSONB) RETURNS BIGINT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN try_num(j) = trunc(try_num(j)) AND abs(try_num(j)) < 9e15 THEN try_num(j)::bigint END
$$;

-- texto com teto de tamanho. (NUL/\u0000 não existe em TEXT/JSONB no Postgres:
-- a camada HTTP remove antes — ver server/index.mjs)
CREATE FUNCTION clean_text(t TEXT, maxlen INT DEFAULT 5000) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT left(t, maxlen)
$$;

CREATE FUNCTION is_enum_value(p_type REGTYPE, p_val TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pg_enum WHERE enumtypid = p_type AND enumlabel = p_val)
$$;

-- id de usuário válido (formato + nunca 'u_me') ou NULL
CREATE FUNCTION valid_user_id(p_id TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_id ~ '^[A-Za-z0-9_.:-]{1,80}$' AND p_id <> 'u_me' THEN p_id END
$$;

-- cria o usuário "casca" citado antes do namespace users; devolve NULL se inválido
CREATE FUNCTION ensure_user(p_id TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE v TEXT := valid_user_id(p_id);
BEGIN
  IF v IS NULL THEN RETURN NULL; END IF;
  INSERT INTO users (id, is_mock) VALUES (v, v LIKE 'demo\_%') ON CONFLICT (id) DO NOTHING;
  RETURN v;
END $$;

-- avatar aceito pela CHECK users_avatar_safe, senão NULL
CREATE FUNCTION safe_avatar(p TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p ~ '^https://[^\s"''()<>\\]+$'
                OR p ~ '^data:image/(png|jpeg|jpg|webp|gif);base64,[A-Za-z0-9+/=]+$' THEN p END
$$;

-- permissão efetiva no sync: importação confia no aparelho; o dono
-- (workspaces.owner_id) tem tudo mesmo antes da própria membership chegar.
CREATE FUNCTION sync_can(p_user TEXT, p_workspace TEXT, p_perm TEXT, p_trust BOOLEAN) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT p_trust
      OR EXISTS (SELECT 1 FROM workspaces WHERE id = p_workspace AND owner_id = p_user)
      OR api.has_permission(p_user, p_workspace, p_perm)
$$;

-- workspaces que o usuário da sessão enxerga (membro ativo ou dono; nunca apagados)
CREATE FUNCTION api.visible_workspaces(p_user TEXT) RETURNS SETOF TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT w.id FROM workspaces w
  WHERE p_user = api.current_user_id() AND w.deleted_at IS NULL
    AND (w.owner_id = p_user OR EXISTS (SELECT 1 FROM memberships m
          WHERE m.workspace_id = w.id AND m.user_id = p_user AND m.status = 'active'))
$$;

-- validação de forma do `data` por namespace (payload parcial nunca apaga dados)
CREATE FUNCTION ns_validate_shape(p_ns TEXT, d JSONB) RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF jsonb_typeof(d) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'estudy:% — data precisa ser um objeto', p_ns USING ERRCODE = '22023';
  END IF;
  IF (p_ns = 'identity'    AND jsonb_typeof(d->'userId')     IS DISTINCT FROM 'string')
  OR (p_ns = 'users'       AND jsonb_typeof(d->'byId')       IS DISTINCT FROM 'object')
  OR (p_ns = 'planner'     AND jsonb_typeof(d->'events')     IS DISTINCT FROM 'array')
  OR (p_ns = 'workspace'   AND jsonb_typeof(d->'workspaces') IS DISTINCT FROM 'array')
  OR (p_ns IN ('memberships','invites') AND jsonb_typeof(d->'items') IS DISTINCT FROM 'array')
  OR (p_ns = 'planner'     AND d ? 'notes' AND jsonb_typeof(d->'notes') NOT IN ('object','null'))
  OR (p_ns = 'planner'     AND d ? 'weeks' AND jsonb_typeof(d->'weeks') NOT IN ('array','null'))
  OR (p_ns = 'identity'    AND d ? 'files' AND jsonb_typeof(d->'files') NOT IN ('array','null')) THEN
    RAISE EXCEPTION 'estudy:% — formato de data inválido (chave obrigatória ausente ou de tipo errado)', p_ns
      USING ERRCODE = '22023';
  END IF;
END $$;

-- =====================================================================
-- PUT — um por namespace (todos recebem p_trust: TRUE só via ns_import)
-- =====================================================================

CREATE FUNCTION ns_put_identity(p_user TEXT, d JSONB, p_trust BOOLEAN) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
  f JSONB; ord BIGINT; x TEXT; fid TEXT; keep TEXT[] := '{}'; skipped JSONB := '[]'; warnings JSONB := '[]';
  nm TEXT := clean_text(coalesce(d->>'name', ''), 200);
  un TEXT := nullif(btrim(clean_text(coalesce(d->>'username',''), 80)), '');
  em TEXT := nullif(btrim(clean_text(coalesce(d->>'email',''), 200)), '');
  pv TEXT := d->>'provider'; av TEXT := safe_avatar(d->>'avatarUrl');
  onb BOOLEAN := coalesce(try_bool(d->'onboarded'), FALSE); attempt INT;
BEGIN
  IF d->>'userId' IS DISTINCT FROM p_user THEN
    RAISE EXCEPTION 'identity.userId (%) difere do usuário da requisição (%)', d->>'userId', p_user
      USING ERRCODE = '22023';
  END IF;
  IF d->>'avatarUrl' IS NOT NULL AND av IS NULL THEN
    warnings := warnings || '{"field":"avatarUrl","reason":"unsafe_url_dropped"}'::jsonb;
  END IF;
  IF un IS NOT NULL AND length(un) < 3 THEN un := NULL; warnings := warnings || '{"field":"username","reason":"too_short"}'::jsonb; END IF;
  IF em IS NOT NULL AND em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN em := NULL; warnings := warnings || '{"field":"email","reason":"invalid"}'::jsonb; END IF;

  -- boot do app (L2059-2063): identity.profile.updated → Users.upsert do próprio usuário
  INSERT INTO users (id, display_name, avatar_url, course, institution)
  VALUES (p_user, coalesce(nullif(nm,''), un, 'Você'), av,
          clean_text(coalesce(d->>'course',''), 200), clean_text(coalesce(d->>'institution',''), 200))
  ON CONFLICT (id) DO UPDATE SET
    display_name = EXCLUDED.display_name, avatar_url = EXCLUDED.avatar_url,
    course = EXCLUDED.course, institution = EXCLUDED.institution
  WHERE (users.display_name, users.avatar_url, users.course, users.institution)
        IS DISTINCT FROM (EXCLUDED.display_name, EXCLUDED.avatar_url, EXCLUDED.course, EXCLUDED.institution);

  -- só as chaves presentes no payload mudam (identity parcial não apaga credenciais);
  -- e-mail/username já usados por outra conta são descartados um a um, sem perder o resto
  FOR attempt IN 1..3 LOOP
    BEGIN
      INSERT INTO identities AS i (user_id, username, email, full_name, period, provider, pass_hash, pass_algo,
                                   onboarded, onboarded_at, signed_in)
      VALUES (p_user, un, em, nm, clean_text(coalesce(d->>'period',''), 40),
              CASE WHEN is_enum_value('auth_provider', pv) THEN pv::auth_provider END,
              clean_text(d->>'passHash', 200), CASE WHEN d->>'passHash' IS NOT NULL THEN 'sha256-client' END,
              onb, CASE WHEN onb THEN now() END, coalesce(try_bool(d->'signedIn'), FALSE))
      ON CONFLICT (user_id) DO UPDATE SET
        username  = CASE WHEN d ? 'username' THEN EXCLUDED.username ELSE i.username END,
        email     = CASE WHEN d ? 'email'    THEN EXCLUDED.email    ELSE i.email END,
        full_name = CASE WHEN d ? 'name'     THEN EXCLUDED.full_name ELSE i.full_name END,
        period    = CASE WHEN d ? 'period'   THEN EXCLUDED.period   ELSE i.period END,
        provider  = CASE WHEN d ? 'provider' THEN EXCLUDED.provider ELSE i.provider END,
        pass_hash = CASE WHEN d ? 'passHash' THEN EXCLUDED.pass_hash ELSE i.pass_hash END,
        pass_algo = CASE WHEN NOT (d ? 'passHash') THEN i.pass_algo
                         WHEN EXCLUDED.pass_hash IS NULL THEN NULL
                         WHEN EXCLUDED.pass_hash = i.pass_hash THEN i.pass_algo ELSE 'sha256-client' END,
        onboarded = CASE WHEN d ? 'onboarded' THEN EXCLUDED.onboarded ELSE i.onboarded END,
        onboarded_at = CASE WHEN (CASE WHEN d ? 'onboarded' THEN EXCLUDED.onboarded ELSE i.onboarded END)
                            THEN coalesce(i.onboarded_at, now()) END,
        signed_in = CASE WHEN d ? 'signedIn' THEN EXCLUDED.signed_in ELSE i.signed_in END;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF em IS NOT NULL AND EXISTS (SELECT 1 FROM identities WHERE email = em::citext AND user_id <> p_user) THEN
        warnings := warnings || jsonb_build_object('field', 'email', 'reason', 'taken'); em := NULL;
      ELSIF un IS NOT NULL THEN
        warnings := warnings || jsonb_build_object('field', 'username', 'reason', 'taken'); un := NULL;
      ELSE RAISE;
      END IF;
    END;
  END LOOP;

  -- identity.files [{name,size}] → assets context 'onboarding' (só metadados)
  FOR f, ord IN SELECT value, ordinality FROM jsonb_array_elements(coalesce(nullif(d->'files','null'),'[]')) WITH ORDINALITY LOOP
    BEGIN
      x := lower(regexp_replace(coalesce(f->>'name',''), '^.*\.', ''));
      IF NOT is_enum_value('asset_ext', x) THEN
        skipped := skipped || jsonb_build_object('file', f->>'name', 'reason', 'ext_not_allowed'); CONTINUE;
      END IF;
      fid := 'onb_' || left(md5(p_user), 8) || '_' || lpad(ord::text, 3, '0') || '_'
             || left(md5(coalesce(f->>'name','') || '|' || coalesce(f->>'size','')), 8);
      INSERT INTO assets (id, context, owner_user_id, name, size_bytes, ext, mime_type, added_by)
      VALUES (fid, 'onboarding', p_user, clean_text(f->>'name', 255), greatest(coalesce(try_int(f->'size'), 0), 0),
              x::asset_ext, (SELECT mime FROM asset_ext_meta WHERE ext = x::asset_ext), p_user)
      ON CONFLICT (id) DO UPDATE SET deleted_at = NULL WHERE assets.deleted_at IS NOT NULL;
      keep := keep || fid;
    EXCEPTION WHEN others THEN
      skipped := skipped || jsonb_build_object('file', f->>'name', 'reason', 'error', 'detail', SQLERRM);
    END;
  END LOOP;
  DELETE FROM assets WHERE context = 'onboarding' AND owner_user_id = p_user AND id <> ALL (keep);

  RETURN jsonb_build_object('files', cardinality(keep), 'skipped', skipped, 'warnings', warnings);
END $$;

CREATE FUNCTION ns_put_users(p_user TEXT, d JSONB, p_trust BOOLEAN) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE k TEXT; u JSONB; n INT := 0; skipped JSONB := '[]'; may_edit BOOLEAN; av TEXT; ts TIMESTAMPTZ;
BEGIN
  FOR k, u IN SELECT key, value FROM jsonb_each(d->'byId') LOOP
    BEGIN
      IF valid_user_id(k) IS NULL OR jsonb_typeof(u) <> 'object' THEN      -- regra §5.8 ('u_me') + formato
        skipped := skipped || jsonb_build_object('id', k, 'reason', 'invalid_user'); CONTINUE;
      END IF;
      -- quem pode editar um perfil existente: o próprio; ou, para participante SEM conta,
      -- quem tem manageMembers num workspace onde ele é membro (L2688). Importação confia.
      may_edit := p_trust OR k = p_user OR (
        NOT EXISTS (SELECT 1 FROM identities WHERE user_id = k)
        AND EXISTS (SELECT 1 FROM memberships m WHERE m.user_id = k
                      AND sync_can(p_user, m.workspace_id, 'manageMembers', FALSE)));
      av := safe_avatar(u->>'avatarUrl');
      ts := coalesce(try_ts(u->>'updatedAt'), now());
      IF NOT EXISTS (SELECT 1 FROM users WHERE id = k) THEN
        INSERT INTO users (id, display_name, avatar_url, course, institution, is_mock, created_at, updated_at)
        VALUES (k, clean_text(coalesce(u->>'displayName',''), 200), av, clean_text(coalesce(u->>'course',''), 200),
                clean_text(coalesce(u->>'institution',''), 200), p_trust AND k LIKE 'demo\_%',
                coalesce(try_ts(u->>'createdAt'), now()), least(ts, now()));
        n := n + 1;
      ELSIF may_edit THEN
        UPDATE users SET display_name = clean_text(coalesce(u->>'displayName',''), 200), avatar_url = av,
               course = clean_text(coalesce(u->>'course',''), 200), institution = clean_text(coalesce(u->>'institution',''), 200),
               created_at = CASE WHEN p_trust THEN least(created_at, coalesce(try_ts(u->>'createdAt'), created_at)) ELSE created_at END,
               updated_at = least(ts, now())
         WHERE id = k AND (p_trust OR ts >= updated_at)          -- não regride
           AND (display_name, avatar_url, course, institution, updated_at) IS DISTINCT FROM
               (clean_text(coalesce(u->>'displayName',''), 200), av, clean_text(coalesce(u->>'course',''), 200),
                clean_text(coalesce(u->>'institution',''), 200), least(ts, now()));
        IF NOT FOUND AND NOT p_trust AND EXISTS (SELECT 1 FROM users x WHERE x.id = k AND ts < x.updated_at
             AND (x.display_name, x.avatar_url, x.course, x.institution) IS DISTINCT FROM
                 (clean_text(coalesce(u->>'displayName',''), 200), av, clean_text(coalesce(u->>'course',''), 200),
                  clean_text(coalesce(u->>'institution',''), 200))) THEN
          skipped := skipped || jsonb_build_object('id', k, 'reason', 'stale_profile');
        END IF;
        n := n + 1;
      END IF;
    EXCEPTION WHEN others THEN
      skipped := skipped || jsonb_build_object('id', k, 'reason', 'error', 'detail', SQLERRM);
    END;
  END LOOP;
  RETURN jsonb_build_object('users', n, 'skipped', skipped);
END $$;

CREATE FUNCTION ns_put_planner(p_user TEXT, d JSONB, p_trust BOOLEAN) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
  t_id TEXT; t_src plan_source; e JSONB; w JSONB; r JSONB; ord BIGINT;
  eid TEXT; dt DATE; st TIME; en TIME; ty activity_type; ps presence_status; og event_origin; ttl TEXT;
  src TEXT; owner TEXT; ids TEXT[] := '{}'; wk_codes TEXT[] := '{}';
  n_ev INT := 0; n_del INT := 0; n_notes INT := 0; skipped JSONB := '[]'; warnings JSONB := '[]';
  k TEXT; v TEXT; gym NUMERIC; study NUMERIC; old_base JSONB; new_base JSONB;
BEGIN
  -- 1) ciclo: plano importado (state.weeks/baseline, L3103) ou grade oficial
  IF jsonb_typeof(d->'weeks') = 'array' AND jsonb_array_length(d->'weeks') > 0 THEN
    t_id := 'import:' || p_user; t_src := 'import';
    INSERT INTO terms (id, label, source, owner_user_id) VALUES (t_id, 'Plano importado', 'import', p_user)
    ON CONFLICT (id) DO NOTHING;
    FOR w IN SELECT value FROM jsonb_array_elements(d->'weeks') LOOP
      BEGIN
        IF try_date(w->>'start') IS NULL OR coalesce(w->>'id','') !~ '^S[0-9]{2}$' THEN
          skipped := skipped || jsonb_build_object('week', w->>'id', 'reason', 'invalid_week'); CONTINUE;
        END IF;
        INSERT INTO weeks (id, term_id, code, rod_label, module, start_date)
        VALUES (t_id || ':' || (w->>'id'), t_id, w->>'id', clean_text(coalesce(w->>'rod', 'Plano importado'), 80),
                CASE WHEN EXISTS (SELECT 1 FROM modules WHERE code = w->>'mod') THEN w->>'mod' ELSE 'GERAL' END,
                try_date(w->>'start'))
        ON CONFLICT (id) DO UPDATE SET rod_label = EXCLUDED.rod_label, module = EXCLUDED.module,
                                       start_date = EXCLUDED.start_date;
        wk_codes := wk_codes || (w->>'id');
      EXCEPTION WHEN others THEN
        skipped := skipped || jsonb_build_object('week', w->>'id', 'reason', 'error', 'detail', SQLERRM);
      END;
    END LOOP;
    DELETE FROM weeks WHERE term_id = t_id AND code <> ALL (wk_codes);
    SET CONSTRAINTS weeks_term_start_uq IMMEDIATE;   -- falha aqui = semanas com a mesma data no payload
    SET CONSTRAINTS weeks_term_start_uq DEFERRED;
    UPDATE terms SET start_date = (SELECT min(start_date) FROM weeks WHERE term_id = t_id),
                     end_date   = (SELECT max(end_date)   FROM weeks WHERE term_id = t_id)
     WHERE id = t_id;
    -- baseline: só regrava se mudou (preserva source_item_id dos eventos)
    SELECT coalesce(jsonb_agg(jsonb_build_array(to_char(date,'YYYY-MM-DD'), hhmm(start_time), hhmm(end_time), type, title)
                              ORDER BY position), '[]')
      INTO old_base FROM schedule_items WHERE term_id = t_id;
    new_base := CASE WHEN jsonb_typeof(d->'baseline') = 'array' THEN d->'baseline' ELSE '[]' END;
    IF old_base IS DISTINCT FROM new_base THEN
      DELETE FROM schedule_items WHERE term_id = t_id;
      FOR r, ord IN SELECT value, ordinality FROM jsonb_array_elements(new_base) WITH ORDINALITY LOOP
        BEGIN
          IF jsonb_typeof(r) <> 'array' OR try_date(r->>0) IS NULL OR try_time(r->>1) IS NULL OR try_time(r->>2) IS NULL
             OR try_time(r->>2) <= try_time(r->>1) OR NOT is_enum_value('activity_type', r->>3)
             OR btrim(coalesce(r->>4, '')) = '' THEN
            skipped := skipped || jsonb_build_object('baseline', ord, 'reason', 'invalid_row'); CONTINUE;
          END IF;
          INSERT INTO schedule_items (term_id, position, date, start_time, end_time, type, title)
          VALUES (t_id, ord, (r->>0)::date, (r->>1)::time, (r->>2)::time, (r->>3)::activity_type, clean_text(r->>4, 200));
        EXCEPTION WHEN others THEN
          skipped := skipped || jsonb_build_object('baseline', ord, 'reason', 'error', 'detail', SQLERRM);
        END;
      END LOOP;
    END IF;
  ELSE
    SELECT en.term_id, t.source INTO t_id, t_src FROM enrollments en JOIN terms t ON t.id = en.term_id
     WHERE en.user_id = p_user AND en.is_active;
    IF t_src IS DISTINCT FROM 'seed' THEN
      SELECT id, source INTO t_id, t_src FROM terms WHERE source = 'seed'
       ORDER BY start_date DESC NULLS LAST, created_at DESC LIMIT 1;
    END IF;
    IF t_id IS NULL THEN
      warnings := warnings || '"nenhum ciclo oficial carregado (rode o seed): eventos sem term_id, notas ignoradas"'::jsonb;
    END IF;
  END IF;

  IF t_id IS NOT NULL THEN
    UPDATE enrollments SET is_active = FALSE WHERE user_id = p_user AND term_id <> t_id AND is_active;
    INSERT INTO enrollments (user_id, term_id, is_active) VALUES (p_user, t_id, TRUE)
    ON CONFLICT (user_id, term_id) DO UPDATE SET is_active = TRUE;
  END IF;

  -- 2) eventos
  FOR e, ord IN SELECT value, ordinality FROM jsonb_array_elements(d->'events') WITH ORDINALITY LOOP
    BEGIN
      eid := nullif(e->>'id', '');
      dt := try_date(e->>'date'); st := try_time(e->>'start'); en := try_time(e->>'end');
      IF jsonb_typeof(e) <> 'object' OR eid IS NULL OR eid !~ '^\S{1,80}$' OR dt IS NULL OR st IS NULL OR en IS NULL OR en <= st THEN
        skipped := skipped || jsonb_build_object('event', coalesce(eid, '#' || ord), 'reason', 'invalid_event',
                                                 'date', e->>'date', 'start', e->>'start', 'end', e->>'end');
        CONTINUE;
      END IF;
      IF eid = ANY (ids) THEN
        skipped := skipped || jsonb_build_object('event', eid, 'reason', 'duplicate_in_payload'); CONTINUE;
      END IF;
      owner := NULL;
      SELECT user_id INTO owner FROM planner_events WHERE id = eid;
      IF owner IS NOT NULL AND owner <> p_user THEN
        skipped := skipped || jsonb_build_object('event', eid, 'reason', 'id_conflict'); CONTINUE;
      END IF;
      -- tipo desconhecido é renderizado como PESSOAL (L1082)
      IF is_enum_value('activity_type', e->>'type') THEN ty := (e->>'type')::activity_type;
      ELSE ty := 'PESSOAL'; warnings := warnings || jsonb_build_object('event', eid, 'type', e->>'type', 'mappedTo', 'PESSOAL');
      END IF;
      -- status ausente ("aplicar todas as sugestões" L1775) → stOf() L706
      IF is_enum_value('presence_status', e->>'status') THEN ps := (e->>'status')::presence_status;
      ELSIF coalesce(try_bool(e->'done'), FALSE) THEN ps := 'presente';
      ELSE ps := 'pendente'; END IF;
      ttl := coalesce(nullif(btrim(clean_text(coalesce(e->>'title',''), 200)), ''), 'Sem título');
      IF coalesce(try_bool(e->'custom'), FALSE) THEN
        og := CASE WHEN e->>'note' = 'sugestão automática' THEN 'sugestao' ELSE 'manual' END;
      ELSE
        og := CASE WHEN t_src = 'import' THEN 'import' ELSE 'grade' END;
      END IF;
      src := NULL;
      IF og IN ('grade','import') AND t_id IS NOT NULL THEN
        SELECT si.id INTO src FROM schedule_items si
         WHERE si.term_id = t_id AND si.date = dt AND si.start_time = st AND si.end_time = en
           AND si.type = ty AND si.title = ttl
           AND NOT EXISTS (SELECT 1 FROM planner_events x WHERE x.user_id = p_user AND x.source_item_id = si.id
                             AND x.id <> eid AND x.id = ANY (ids))
         ORDER BY si.position LIMIT 1;
      END IF;
      INSERT INTO planner_events AS pe (id, user_id, term_id, source_item_id, date, start_time, end_time, type,
                                        title, note, status, origin)
      VALUES (eid, p_user, t_id, src, dt, st, en, ty, ttl, clean_text(coalesce(e->>'note',''), 2000), ps, og)
      ON CONFLICT (id) DO UPDATE SET
        term_id = EXCLUDED.term_id, source_item_id = EXCLUDED.source_item_id, date = EXCLUDED.date,
        start_time = EXCLUDED.start_time, end_time = EXCLUDED.end_time, type = EXCLUDED.type,
        title = EXCLUDED.title, note = EXCLUDED.note, status = EXCLUDED.status, origin = EXCLUDED.origin,
        deleted_at = NULL
      WHERE pe.user_id = p_user AND (pe.deleted_at IS NOT NULL
         OR (pe.term_id, pe.source_item_id, pe.date, pe.start_time, pe.end_time, pe.type, pe.title, pe.note, pe.status, pe.origin)
            IS DISTINCT FROM (EXCLUDED.term_id, EXCLUDED.source_item_id, EXCLUDED.date, EXCLUDED.start_time, EXCLUDED.end_time,
                              EXCLUDED.type, EXCLUDED.title, EXCLUDED.note, EXCLUDED.status, EXCLUDED.origin));
      ids := ids || eid; n_ev := n_ev + 1;
    EXCEPTION WHEN others THEN
      skipped := skipped || jsonb_build_object('event', coalesce(eid, '#' || ord), 'reason', 'error', 'detail', SQLERRM);
    END;
  END LOOP;
  -- planner é pessoal: o que sumiu do payload foi excluído pelo aluno (LWW por namespace, §8.4)
  UPDATE planner_events SET deleted_at = now()
   WHERE user_id = p_user AND deleted_at IS NULL AND id <> ALL (ids);
  GET DIAGNOSTICS n_del = ROW_COUNT;

  -- 3) anotações por semana (chave = código 'Sxx' do ciclo ativo)
  IF t_id IS NOT NULL AND jsonb_typeof(d->'notes') = 'object' THEN
    DELETE FROM week_notes WHERE user_id = p_user
       AND week_id IN (SELECT id FROM weeks WHERE term_id = t_id)
       AND week_id NOT IN (SELECT t_id || ':' || key FROM jsonb_each(d->'notes'));
    FOR k, v IN SELECT key, value FROM jsonb_each_text(d->'notes') LOOP
      IF NOT EXISTS (SELECT 1 FROM weeks WHERE id = t_id || ':' || k) THEN
        skipped := skipped || jsonb_build_object('note', k, 'reason', 'week_not_in_term'); CONTINUE;
      END IF;
      INSERT INTO week_notes (user_id, week_id, body) VALUES (p_user, t_id || ':' || k, clean_text(coalesce(v, ''), 20000))
      ON CONFLICT (user_id, week_id) DO UPDATE SET body = EXCLUDED.body WHERE week_notes.body IS DISTINCT FROM EXCLUDED.body;
      n_notes := n_notes + 1;
    END LOOP;
  END IF;

  -- 4) metas (inputs 0-7 e 0-40 só existem no HTML: o banco impõe e avisa)
  IF jsonb_typeof(d->'goals') = 'object' THEN
    gym   := coalesce(try_num(d->'goals'->'gym'), 4);
    study := coalesce(try_num(d->'goals'->'study'), 10);
    IF gym <> round(least(greatest(gym, 0), 7)) OR study <> round(least(greatest(study, 0), 40), 1) THEN
      warnings := warnings || jsonb_build_object('goals', d->'goals', 'reason', 'clamped');
    END IF;
    INSERT INTO user_goals (user_id, gym_per_week, study_hours_per_week)
    VALUES (p_user, round(least(greatest(gym, 0), 7)), round(least(greatest(study, 0), 40), 1))
    ON CONFLICT (user_id) DO UPDATE SET gym_per_week = EXCLUDED.gym_per_week,
                                        study_hours_per_week = EXCLUDED.study_hours_per_week
    WHERE (user_goals.gym_per_week, user_goals.study_hours_per_week)
          IS DISTINCT FROM (EXCLUDED.gym_per_week, EXCLUDED.study_hours_per_week);
  END IF;

  RETURN jsonb_build_object('term', t_id, 'events', n_ev, 'softDeleted', n_del, 'notes', n_notes,
                            'skipped', skipped, 'warnings', warnings);
END $$;

CREATE FUNCTION ns_put_workspace(p_user TEXT, d JSONB, p_trust BOOLEAN) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
  w JSONB; x JSONB; c JSONB; wid TEXT; col TEXT; ico TEXT; xt TEXT; nm TEXT;
  ws_ids TEXT[] := '{}'; kids TEXT[]; exists_before BOOLEAN; pulled TIMESTAMPTZ; n INT;
  n_ws INT := 0; n_del INT := 0; skipped JSONB := '[]'; warnings JSONB := '[]'; read_only JSONB := '[]';
  dt DATE; st TIME; en TIME; trust BOOLEAN; owner_now TEXT; t_ws BOOLEAN; fresh BOOLEAN;
  can_ws BOOLEAN; can_ev BOOLEAN; can_tk BOOLEAN; can_as BOOLEAN; can_cm BOOLEAN;
  a_created TEXT; a_assignee TEXT; t_title TEXT; t_desc TEXT; t_due DATE; t_status task_status; e_title TEXT;
BEGIN
  -- último GET deste usuário: o que OUTRO membro mudou depois dele é protegido
  SELECT pulled_at INTO pulled FROM sync_state WHERE user_id = p_user AND namespace = 'workspace';
  pulled := coalesce(pulled, '-infinity');

  FOR w IN SELECT value FROM jsonb_array_elements(d->'workspaces') LOOP
   BEGIN
    wid := w->>'id';
    nm := btrim(clean_text(coalesce(w->>'name',''), 200));
    IF jsonb_typeof(w) <> 'object' OR wid IS NULL OR wid !~ '^\S{1,80}$' OR nm = '' THEN
      skipped := skipped || jsonb_build_object('workspace', wid, 'reason', 'invalid_workspace'); CONTINUE;
    END IF;
    owner_now := NULL;
    SELECT owner_id, (inserted_at = now()) INTO owner_now, fresh FROM workspaces WHERE id = wid;
    exists_before := owner_now IS NOT NULL;
    -- importação confia no aparelho só para workspace novo (ou criado nesta mesma carga) ou do próprio usuário;
    -- workspace de terceiros que já está no banco segue as regras de runtime (dump antigo não corrompe)
    t_ws := p_trust AND (NOT exists_before OR owner_now = p_user OR coalesce(fresh, FALSE));
    trust := t_ws OR NOT exists_before OR owner_now = p_user;
    IF exists_before AND EXISTS (SELECT 1 FROM workspaces WHERE id = wid AND deleted_at IS NOT NULL) AND NOT t_ws THEN
      -- excluído no servidor: aparelho desatualizado não ressuscita (inclui purge_mocks)
      skipped := skipped || jsonb_build_object('workspace', wid, 'reason', 'deleted_on_server'); CONTINUE;
    END IF;
    IF NOT trust AND NOT api.is_member(wid, p_user) THEN
      skipped := skipped || jsonb_build_object('workspace', wid, 'reason', 'not_member'); CONTINUE;
    END IF;
    -- matriz §4.4 aplicada pelo banco (o app só checa na criação: L2357, L2417)
    can_ws := trust OR api.has_permission(p_user, wid, 'manageWorkspace');
    can_ev := trust OR api.has_permission(p_user, wid, 'manageEvents');
    can_tk := trust OR api.has_permission(p_user, wid, 'manageTasks');
    can_as := trust OR api.has_permission(p_user, wid, 'manageAssets');
    can_cm := trust OR api.has_permission(p_user, wid, 'comment');
    ws_ids := ws_ids || wid;

    IF NOT can_ws THEN
      read_only := read_only || jsonb_build_object('workspace', wid, 'section', 'meta');
    ELSE
      col := regexp_replace(coalesce(w->>'color',''), '^var\(--(.*)\)$', '\1');
      IF NOT EXISTS (SELECT 1 FROM workspace_colors WHERE token = col) THEN
        warnings := warnings || jsonb_build_object('workspace', wid, 'color', w->>'color', 'mappedTo', 'estudo');
        col := 'estudo';
      END IF;
      ico := CASE WHEN EXISTS (SELECT 1 FROM workspace_icons WHERE icon = w->>'icon') THEN w->>'icon' ELSE '◍' END;
      INSERT INTO workspaces AS ws (id, name, description, color, icon, owner_id, invite_code, is_mock,
                                    created_at, updated_at)
      VALUES (wid, nm, clean_text(coalesce(w->>'description',''), 2000), col, ico,
              -- dono: na importação vem do aparelho; em runtime quem cria é o dono
              CASE WHEN t_ws THEN coalesce(ensure_user(w->>'ownerId'), p_user) ELSE p_user END,
              CASE WHEN coalesce(w->>'inviteCode','') ~ '^[A-Za-z0-9-]{4,32}$' THEN w->>'inviteCode' END,
              t_ws AND nm IN ('Grupo de Estudos — Clínica Médica', 'TCC — Pneumologia e Tabagismo'),
              coalesce(try_ts(w->>'createdAt'), now()), least(coalesce(try_ts(w->>'updatedAt'), now()), now()))
      ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name, description = EXCLUDED.description, color = EXCLUDED.color, icon = EXCLUDED.icon,
        -- owner_id NUNCA muda por sync (tomada de posse)
        invite_code = coalesce(ws.invite_code, EXCLUDED.invite_code),
        updated_at = EXCLUDED.updated_at, deleted_at = NULL
      WHERE (ws.deleted_at IS NOT NULL AND t_ws)
         OR (ws.deleted_at IS NULL AND (ws.name, ws.description, ws.color, ws.icon, ws.updated_at)
             IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.description, EXCLUDED.color, EXCLUDED.icon, EXCLUDED.updated_at));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM workspaces WHERE id = wid AND deleted_at IS NULL) THEN CONTINUE; END IF;
    n_ws := n_ws + 1;

    -- ---------- calendário do workspace ----------
    IF NOT can_ev THEN read_only := read_only || jsonb_build_object('workspace', wid, 'section', 'events');
    ELSE
      kids := '{}';
      FOR x IN SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(w->'events') = 'array' THEN w->'events' ELSE '[]' END) LOOP
        BEGIN
          dt := try_date(x->>'date'); st := try_time(x->>'start'); en := try_time(x->>'end');
          IF x->>'id' IS NULL OR dt IS NULL OR st IS NULL OR en IS NULL OR en < st THEN
            skipped := skipped || jsonb_build_object('workspaceEvent', x->>'id', 'workspace', wid, 'reason', 'invalid_event');
            CONTINUE;
          END IF;
          a_created := CASE WHEN t_ws THEN coalesce(ensure_user(x->>'createdBy'), p_user) ELSE p_user END;
          e_title := coalesce(nullif(btrim(clean_text(coalesce(x->>'title',''), 200)),''), 'Sem título');
          INSERT INTO workspace_events AS we (id, workspace_id, date, start_time, end_time, title, note,
                                              created_by, created_at, updated_by)
          VALUES (x->>'id', wid, dt, st, en, e_title, clean_text(coalesce(x->>'note',''), 2000),
                  a_created, least(coalesce(try_ts(x->>'createdAt'), now()), now()), a_created)
          ON CONFLICT (id) DO UPDATE SET date = EXCLUDED.date, start_time = EXCLUDED.start_time, end_time = EXCLUDED.end_time,
            title = EXCLUDED.title, note = EXCLUDED.note, updated_by = p_user, deleted_at = NULL
          WHERE we.workspace_id = wid
            AND (t_ws OR we.updated_at <= pulled OR we.updated_by = p_user)       -- não sobrescreve edição alheia recente
            AND (we.deleted_at IS NOT NULL OR (we.date, we.start_time, we.end_time, we.title, we.note)
                 IS DISTINCT FROM (EXCLUDED.date, EXCLUDED.start_time, EXCLUDED.end_time, EXCLUDED.title, EXCLUDED.note));
          GET DIAGNOSTICS n = ROW_COUNT;
          IF n = 0 AND NOT t_ws AND EXISTS (SELECT 1 FROM workspace_events we WHERE we.id = x->>'id' AND we.workspace_id = wid
               AND we.updated_at > pulled AND we.updated_by IS DISTINCT FROM p_user
               AND (we.date, we.start_time, we.end_time, we.title) IS DISTINCT FROM (dt, st, en, e_title)) THEN
            skipped := skipped || jsonb_build_object('workspaceEvent', x->>'id', 'reason', 'conflict_newer_on_server');
          END IF;
          kids := kids || (x->>'id');
        EXCEPTION WHEN others THEN
          skipped := skipped || jsonb_build_object('workspaceEvent', x->>'id', 'reason', 'error', 'detail', SQLERRM);
        END;
      END LOOP;
      UPDATE workspace_events SET deleted_at = now(), updated_by = p_user
       WHERE workspace_id = wid AND deleted_at IS NULL AND id <> ALL (kids)
         AND (t_ws OR updated_at <= pulled OR updated_by = p_user);
    END IF;

    -- ---------- tarefas + comentários de tarefa (→ activities.task_id) ----------
    -- Comentários nunca são apagados pelo app (somem com a tarefa, L2639): o sync só acrescenta.
    IF NOT can_tk THEN read_only := read_only || jsonb_build_object('workspace', wid, 'section', 'tasks'); END IF;
    kids := '{}';
    FOR x IN SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(w->'tasks') = 'array' THEN w->'tasks' ELSE '[]' END) LOOP
      BEGIN
        t_title := btrim(clean_text(coalesce(x->>'title',''), 300));
        IF x->>'id' IS NULL OR t_title = '' THEN
          skipped := skipped || jsonb_build_object('task', x->>'id', 'workspace', wid, 'reason', 'invalid_task'); CONTINUE;
        END IF;
        IF can_tk THEN
          a_created  := CASE WHEN t_ws THEN coalesce(ensure_user(x->>'createdBy'), p_user) ELSE p_user END;
          -- responsável: precisa ser um usuário que já existe (ou casca, na importação)
          a_assignee := CASE WHEN t_ws THEN ensure_user(x->>'assignee')
                             ELSE (SELECT id FROM users WHERE id = valid_user_id(x->>'assignee')) END;
          t_desc := clean_text(coalesce(x->>'desc',''), 5000); t_due := try_date(x->>'due');
          t_status := CASE WHEN is_enum_value('task_status', x->>'status') THEN (x->>'status')::task_status ELSE 'aberta' END;
          INSERT INTO tasks AS t (id, workspace_id, title, description, assignee_id, due_date, status,
                                  created_by, created_at, updated_by)
          VALUES (x->>'id', wid, t_title, t_desc, a_assignee, t_due, t_status,
                  a_created, least(coalesce(try_ts(x->>'createdAt'), now()), now()), a_created)
          ON CONFLICT (id) DO UPDATE SET title = EXCLUDED.title, description = EXCLUDED.description,
            assignee_id = EXCLUDED.assignee_id, due_date = EXCLUDED.due_date, status = EXCLUDED.status,
            updated_by = p_user, deleted_at = NULL
          WHERE t.workspace_id = wid
            AND (t_ws OR t.updated_at <= pulled OR t.updated_by = p_user)
            AND (t.deleted_at IS NOT NULL OR (t.title, t.description, t.assignee_id, t.due_date, t.status)
                 IS DISTINCT FROM (EXCLUDED.title, EXCLUDED.description, EXCLUDED.assignee_id, EXCLUDED.due_date, EXCLUDED.status));
          GET DIAGNOSTICS n = ROW_COUNT;
          IF n = 0 AND NOT t_ws AND EXISTS (SELECT 1 FROM tasks t WHERE t.id = x->>'id' AND t.workspace_id = wid
               AND t.updated_at > pulled AND t.updated_by IS DISTINCT FROM p_user
               AND (t.title, t.description, t.assignee_id, t.due_date, t.status)
                   IS DISTINCT FROM (t_title, t_desc, a_assignee, t_due, t_status)) THEN
            skipped := skipped || jsonb_build_object('task', x->>'id', 'reason', 'conflict_newer_on_server');
          END IF;
          kids := kids || (x->>'id');
        END IF;
        IF can_cm AND EXISTS (SELECT 1 FROM tasks WHERE id = x->>'id' AND workspace_id = wid AND deleted_at IS NULL) THEN
          FOR c IN SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(x->'comments') = 'array' THEN x->'comments' ELSE '[]' END) LOOP
            IF c->>'id' IS NULL OR btrim(coalesce(c->>'text','')) = '' THEN CONTINUE; END IF;
            INSERT INTO activities AS a (id, workspace_id, author_id, body, task_id, created_at)
            VALUES (c->>'id', wid, CASE WHEN t_ws THEN coalesce(ensure_user(c->>'author'), p_user) ELSE p_user END,
                    clean_text(c->>'text', 5000), x->>'id', least(coalesce(try_ts(c->>'at'), now()), now()))
            ON CONFLICT (id) DO UPDATE SET body = EXCLUDED.body, deleted_at = NULL
            WHERE a.workspace_id = wid AND a.task_id IS NOT DISTINCT FROM EXCLUDED.task_id
              AND (t_ws OR a.author_id = p_user)
              AND (a.deleted_at IS NOT NULL OR a.body IS DISTINCT FROM EXCLUDED.body);
          END LOOP;
        END IF;
      EXCEPTION WHEN others THEN
        skipped := skipped || jsonb_build_object('task', x->>'id', 'workspace', wid, 'reason', 'error', 'detail', SQLERRM);
      END;
    END LOOP;
    IF can_tk THEN
      UPDATE tasks SET deleted_at = now(), updated_by = p_user
       WHERE workspace_id = wid AND deleted_at IS NULL AND id <> ALL (kids)
         AND (t_ws OR updated_at <= pulled OR updated_by = p_user);
    END IF;

    -- ---------- arquivos (Assets) ----------
    IF NOT can_as THEN read_only := read_only || jsonb_build_object('workspace', wid, 'section', 'files');
    ELSE
      kids := '{}';
      FOR x IN SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(w->'files') = 'array' THEN w->'files' ELSE '[]' END) LOOP
        BEGIN
          xt := lower(coalesce(x->>'ext', regexp_replace(coalesce(x->>'name',''), '^.*\.', '')));
          IF x->>'id' IS NULL OR NOT is_enum_value('asset_ext', xt) THEN      -- regra §5.4
            skipped := skipped || jsonb_build_object('asset', x->>'id', 'workspace', wid, 'reason', 'ext_not_allowed', 'ext', xt);
            CONTINUE;
          END IF;
          INSERT INTO assets AS s (id, context, workspace_id, name, size_bytes, ext, mime_type, added_by, added_at,
                                   ai_status, stored)
          VALUES (x->>'id', 'workspace', wid, clean_text(coalesce(x->>'name',''), 255),
                  greatest(coalesce(try_int(x->'size'), 0), 0), xt::asset_ext,
                  (SELECT mime FROM asset_ext_meta WHERE ext = xt::asset_ext),
                  CASE WHEN t_ws THEN coalesce(ensure_user(x->>'addedBy'), p_user) ELSE p_user END,
                  least(coalesce(try_ts(x->>'addedAt'), now()), now()),
                  -- ai_status é do pipeline do servidor; o cliente só informa na importação
                  CASE WHEN t_ws AND is_enum_value('ai_status', x->>'aiStatus') THEN (x->>'aiStatus')::ai_status ELSE 'pendente' END,
                  FALSE)   -- stored=true exige storage_key: o binário ainda não sobe pelo app
          ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, deleted_at = NULL
          WHERE s.workspace_id = wid AND (s.deleted_at IS NOT NULL OR s.name IS DISTINCT FROM EXCLUDED.name);
          kids := kids || (x->>'id');
        EXCEPTION WHEN others THEN
          skipped := skipped || jsonb_build_object('asset', x->>'id', 'workspace', wid, 'reason', 'error', 'detail', SQLERRM);
        END;
      END LOOP;
      UPDATE assets SET deleted_at = now()
       WHERE context = 'workspace' AND workspace_id = wid AND deleted_at IS NULL AND id <> ALL (kids)
         AND (t_ws OR updated_at <= pulled OR added_by = p_user);
    END IF;

    -- ---------- mural (activities sem task) — 2 passadas para resolver parentId ----------
    IF NOT can_cm THEN read_only := read_only || jsonb_build_object('workspace', wid, 'section', 'comments');
    ELSE
      FOR c IN SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(w->'comments') = 'array' THEN w->'comments' ELSE '[]' END) LOOP
        BEGIN
          IF c->>'id' IS NULL OR btrim(coalesce(c->>'text','')) = '' THEN
            skipped := skipped || jsonb_build_object('activity', c->>'id', 'workspace', wid, 'reason', 'empty_comment'); CONTINUE;
          END IF;
          INSERT INTO activities AS a (id, workspace_id, author_id, body, created_at)
          VALUES (c->>'id', wid, CASE WHEN t_ws THEN coalesce(ensure_user(c->>'author'), p_user) ELSE p_user END,
                  clean_text(c->>'text', 5000), least(coalesce(try_ts(c->>'at'), now()), now()))
          ON CONFLICT (id) DO UPDATE SET body = EXCLUDED.body, deleted_at = NULL
          WHERE a.workspace_id = wid AND a.task_id IS NULL AND (t_ws OR a.author_id = p_user)
            AND (a.deleted_at IS NOT NULL OR a.body IS DISTINCT FROM EXCLUDED.body);
        EXCEPTION WHEN others THEN
          skipped := skipped || jsonb_build_object('activity', c->>'id', 'reason', 'error', 'detail', SQLERRM);
        END;
      END LOOP;
      FOR c IN SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(w->'comments') = 'array' THEN w->'comments' ELSE '[]' END) LOOP
        BEGIN
          -- só o autor (ou a importação) define o pai; o trigger impõe pai raiz do mesmo workspace
          UPDATE activities SET parent_id = nullif(c->>'parentId','')
           WHERE id = c->>'id' AND workspace_id = wid AND task_id IS NULL
             AND (t_ws OR author_id = p_user)
             AND parent_id IS DISTINCT FROM nullif(c->>'parentId','');
        EXCEPTION WHEN others THEN
          skipped := skipped || jsonb_build_object('activity', c->>'id', 'reason', 'invalid_parent', 'detail', SQLERRM);
        END;
      END LOOP;
    END IF;

    PERFORM ensure_workspace_invite(wid);
   EXCEPTION WHEN others THEN
    skipped := skipped || jsonb_build_object('workspace', wid, 'reason', 'error', 'detail', SQLERRM);
   END;
  END LOOP;

  -- workspace que sumiu do payload: só o DONO apaga (deleteWorkspace, L2511)
  UPDATE workspaces SET deleted_at = now()
   WHERE owner_id = p_user AND deleted_at IS NULL AND id <> ALL (ws_ids);
  GET DIAGNOSTICS n_del = ROW_COUNT;

  RETURN jsonb_build_object('workspaces', n_ws, 'softDeleted', n_del, 'skipped', skipped, 'warnings', warnings,
                            'readOnly', read_only);
END $$;

CREATE FUNCTION ns_put_memberships(p_user TEXT, d JSONB, p_trust BOOLEAN) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE m JSONB; n INT := 0; skipped JSONB := '[]'; rl member_role; cur memberships; mid TEXT; wsid TEXT; uid_ TEXT;
        st membership_status; ws_owner TEXT; resp TEXT; t_ws BOOLEAN;
BEGIN
  FOR m IN SELECT value FROM jsonb_array_elements(d->'items') LOOP
    BEGIN
      mid := m->>'id'; wsid := m->>'workspaceId'; uid_ := valid_user_id(m->>'userId');
      IF mid IS NULL OR mid !~ '^\S{1,80}$' OR wsid IS NULL OR uid_ IS NULL THEN
        skipped := skipped || jsonb_build_object('membership', mid, 'reason', 'invalid_membership'); CONTINUE;
      END IF;
      ws_owner := NULL;
      SELECT owner_id, p_trust AND (owner_id = p_user OR inserted_at = now()) INTO ws_owner, t_ws
        FROM workspaces WHERE id = wsid;
      IF ws_owner IS NULL THEN
        -- órfã: o app apaga o workspace sem limpar memberships (L2526)
        skipped := skipped || jsonb_build_object('membership', mid, 'reason', 'orphan_workspace'); CONTINUE;
      END IF;
      cur := NULL;
      SELECT * INTO cur FROM memberships WHERE id = mid;
      -- id de outra membership (outro workspace/usuário): nunca reaproveita
      IF cur.id IS NOT NULL AND (cur.workspace_id <> wsid OR cur.user_id <> uid_) THEN
        skipped := skipped || jsonb_build_object('membership', mid, 'reason', 'id_conflict'); CONTINUE;
      END IF;
      rl := CASE WHEN is_enum_value('member_role', m->>'role') THEN (m->>'role')::member_role ELSE 'member' END;
      st := CASE WHEN m->>'status' = 'removed' THEN 'removed'::membership_status ELSE 'active' END;
      resp := clean_text(coalesce(m->>'responsibility',''), 200);
      IF NOT sync_can(p_user, wsid, 'manageMembers', t_ws) THEN
        -- sem manageMembers: só a própria responsabilidade (L2658-2660, L2688).
        -- Entrar por código é api.redeem_invite, nunca um PUT de membership.
        IF cur.user_id = p_user AND cur.status = 'active' THEN
          UPDATE memberships SET responsibility = resp WHERE id = mid AND responsibility IS DISTINCT FROM resp;
        ELSIF cur.id IS NULL OR (cur.role, cur.status, cur.responsibility) IS DISTINCT FROM (rl, st, resp) THEN
          skipped := skipped || jsonb_build_object('membership', mid, 'reason', 'permission_denied');
        END IF;
        CONTINUE;
      END IF;
      -- owner é SEMPRE quem é workspaces.owner_id (inclusive na importação)
      IF rl = 'owner' AND uid_ <> ws_owner THEN
        skipped := skipped || jsonb_build_object('membership', mid, 'reason', 'owner_is_fixed'); CONTINUE;
      END IF;
      IF NOT t_ws THEN
        -- remoção é definitiva pelo sync: cópia antiga não devolve o acesso (reentrada = api.redeem_invite)
        IF cur.status = 'removed' AND st = 'active' THEN
          skipped := skipped || jsonb_build_object('membership', mid, 'reason', 'removed_on_server'); CONTINUE;
        END IF;
        IF cur.role = 'owner' AND (rl <> 'owner' OR st = 'removed') THEN
          skipped := skipped || jsonb_build_object('membership', mid, 'reason', 'owner_is_fixed'); CONTINUE;
        END IF;
      END IF;
      PERFORM ensure_user(uid_);
      -- permissions: o trigger SEMPRE deriva de role (nunca vem do cliente)
      INSERT INTO memberships AS ms (id, workspace_id, user_id, role, responsibility, joined_at, status, permissions)
      VALUES (mid, wsid, uid_, rl, resp, least(coalesce(try_ts(m->>'joinedAt'), now()), now()), st, permissions_for(rl))
      ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, responsibility = EXCLUDED.responsibility, status = EXCLUDED.status
      WHERE ms.workspace_id = EXCLUDED.workspace_id AND ms.user_id = EXCLUDED.user_id
        AND (ms.role, ms.responsibility, ms.status) IS DISTINCT FROM (EXCLUDED.role, EXCLUDED.responsibility, EXCLUDED.status);
      n := n + 1;
    EXCEPTION
      WHEN unique_violation THEN
        skipped := skipped || jsonb_build_object('membership', mid, 'reason', 'duplicate_active_or_second_owner');
      WHEN others THEN
        skipped := skipped || jsonb_build_object('membership', mid, 'reason', 'error', 'detail', SQLERRM);
    END;
  END LOOP;
  RETURN jsonb_build_object('memberships', n, 'skipped', skipped);
END $$;

CREATE FUNCTION ns_put_invites(p_user TEXT, d JSONB, p_trust BOOLEAN) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE i JSONB; n INT := 0; skipped JSONB := '[]'; cur invites; mx BIGINT; uses BIGINT; wsx TEXT[] := '{}'; w TEXT;
        t_ws BOOLEAN; nst invite_status;
BEGIN
  FOR i IN SELECT value FROM jsonb_array_elements(d->'items') LOOP
    BEGIN
      IF i->>'id' IS NULL OR i->>'id' !~ '^\S{1,80}$' THEN
        skipped := skipped || jsonb_build_object('invite', i->>'id', 'reason', 'invalid_invite'); CONTINUE;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM workspaces WHERE id = i->>'workspaceId') THEN
        skipped := skipped || jsonb_build_object('invite', i->>'id', 'code', i->>'code', 'reason', 'orphan_workspace'); CONTINUE;
      END IF;
      SELECT p_trust AND (owner_id = p_user OR inserted_at = now()) INTO t_ws FROM workspaces WHERE id = i->>'workspaceId';
      IF NOT sync_can(p_user, i->>'workspaceId', 'manageInvites', t_ws) THEN
        CONTINUE;   -- uso do convite passa por api.redeem_invite
      END IF;
      IF coalesce(i->>'code','') !~ '^[A-Za-z0-9-]{4,32}$' THEN
        skipped := skipped || jsonb_build_object('invite', i->>'id', 'reason', 'invalid_code'); CONTINUE;
      END IF;
      cur := NULL;
      SELECT * INTO cur FROM invites WHERE id = i->>'id';
      IF cur.id IS NOT NULL AND cur.workspace_id <> i->>'workspaceId' THEN
        skipped := skipped || jsonb_build_object('invite', i->>'id', 'reason', 'id_conflict'); CONTINUE;
      END IF;
      IF cur.id IS NULL THEN
        -- mesmo código já no banco (ex.: criado por ensure_workspace_invite): adota o id do app
        SELECT * INTO cur FROM invites WHERE upper(code) = upper(i->>'code');
        IF cur.id IS NOT NULL AND cur.workspace_id <> i->>'workspaceId' THEN
          skipped := skipped || jsonb_build_object('invite', i->>'id', 'code', i->>'code', 'reason', 'code_taken'); CONTINUE;
        END IF;
      END IF;
      nst := CASE WHEN is_enum_value('invite_status', i->>'status') THEN (i->>'status')::invite_status ELSE 'active' END;
      IF cur.status = 'revoked' AND nst <> 'revoked' AND NOT t_ws THEN
        -- revogação é definitiva: cópia antiga não reativa convite vazado
        skipped := skipped || jsonb_build_object('invite', i->>'id', 'reason', 'revoked_on_server'); CONTINUE;
      END IF;
      mx := try_int(i->'maxUses'); IF mx IS NOT NULL AND mx < 1 THEN mx := NULL; END IF;
      IF t_ws THEN
        uses := greatest(coalesce(try_int(i->'currentUses'), 0), 0);
      ELSE
        uses := coalesce(cur.current_uses, 0);           -- contagem de usos é do servidor (redeem_invite)
      END IF;
      IF mx IS NOT NULL AND uses > mx THEN mx := uses; END IF;
      IF cur.id IS NOT NULL THEN
        UPDATE invites SET id = i->>'id', code = i->>'code', expires_at = try_ts(i->>'expiresAt'), max_uses = mx,
               current_uses = uses,
               created_by = CASE WHEN t_ws THEN coalesce(ensure_user(i->>'createdBy'), created_by) ELSE created_by END,
               created_at = CASE WHEN t_ws THEN coalesce(try_ts(i->>'createdAt'), created_at) ELSE created_at END,
               status = CASE WHEN is_enum_value('invite_status', i->>'status') THEN (i->>'status')::invite_status ELSE 'active' END
         WHERE id = cur.id;
      ELSE
        INSERT INTO invites (id, workspace_id, code, created_by, created_at, expires_at, max_uses, current_uses, status)
        VALUES (i->>'id', i->>'workspaceId', i->>'code',
                CASE WHEN t_ws THEN coalesce(ensure_user(i->>'createdBy'), p_user) ELSE p_user END,
                least(coalesce(try_ts(i->>'createdAt'), now()), now()), try_ts(i->>'expiresAt'), mx, uses,
                CASE WHEN is_enum_value('invite_status', i->>'status') THEN (i->>'status')::invite_status ELSE 'active' END);
      END IF;
      wsx := wsx || (i->>'workspaceId'); n := n + 1;
    EXCEPTION WHEN others THEN
      skipped := skipped || jsonb_build_object('invite', i->>'id', 'reason', 'error', 'detail', SQLERRM);
    END;
  END LOOP;
  FOREACH w IN ARRAY wsx LOOP PERFORM ensure_workspace_invite(w); END LOOP;
  RETURN jsonb_build_object('invites', n, 'skipped', skipped);
END $$;

-- ---------- núcleo comum ----------
CREATE FUNCTION ns_put_core(p_user TEXT, p_ns TEXT, p_envelope JSONB, p_force BOOLEAN, p_trust BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v BIGINT; at TIMESTAMPTZ; prev TIMESTAMPTZ; d JSONB; rep JSONB;
BEGIN
  IF ns_schema_version(p_ns) IS NULL THEN
    RAISE EXCEPTION 'namespace desconhecido: %', p_ns USING ERRCODE = '22023';
  END IF;
  IF valid_user_id(p_user) IS NULL THEN
    RAISE EXCEPTION 'usuário inválido: %', p_user USING ERRCODE = '22023';
  END IF;
  v := try_int(p_envelope->'v');
  IF v IS DISTINCT FROM ns_schema_version(p_ns) THEN
    -- o Store roda as migrações na carga (L467): o cliente sempre envia a versão atual
    RAISE EXCEPTION 'estudy:% v% não suportado (esperado v%) — migre no cliente antes de enviar',
      p_ns, p_envelope->>'v', ns_schema_version(p_ns) USING ERRCODE = '22023';
  END IF;
  d := p_envelope->'data';
  PERFORM ns_validate_shape(p_ns, d);
  -- relógio do aparelho adiantado não pode travar o namespace
  at := least(coalesce(try_ts(p_envelope->>'at'), now()), now() + interval '5 minutes');

  -- serializa PUTs concorrentes do mesmo usuário/namespace
  PERFORM pg_advisory_xact_lock(hashtextextended(p_user || '|' || p_ns, 0));

  PERFORM ensure_user(p_user);
  SELECT client_at INTO prev FROM sync_state WHERE user_id = p_user AND namespace = p_ns;
  IF prev IS NOT NULL AND at < prev AND NOT p_force THEN
    RETURN jsonb_build_object('namespace', p_ns, 'applied', FALSE, 'reason', 'stale',
                              'serverAt', iso_ts(prev), 'clientAt', iso_ts(at));
  END IF;

  rep := CASE p_ns
    WHEN 'identity'    THEN ns_put_identity(p_user, d, p_trust)
    WHEN 'users'       THEN ns_put_users(p_user, d, p_trust)
    WHEN 'planner'     THEN ns_put_planner(p_user, d, p_trust)
    WHEN 'workspace'   THEN ns_put_workspace(p_user, d, p_trust)
    WHEN 'memberships' THEN ns_put_memberships(p_user, d, p_trust)
    WHEN 'invites'     THEN ns_put_invites(p_user, d, p_trust)
  END;

  INSERT INTO sync_state (user_id, namespace, schema_version, client_at, server_at)
  VALUES (p_user, p_ns, v, at, now())
  ON CONFLICT (user_id, namespace) DO UPDATE SET schema_version = EXCLUDED.schema_version,
    client_at = greatest(sync_state.client_at, EXCLUDED.client_at), server_at = now();

  RETURN jsonb_build_object('namespace', p_ns, 'applied', TRUE, 'v', v, 'at', iso_ts(at)) || rep;
END $$;

-- runtime (estudy_app): age SÓ como o usuário da sessão, sob a matriz de permissões
CREATE FUNCTION api.ns_put(p_user TEXT, p_ns TEXT, p_envelope JSONB, p_force BOOLEAN DEFAULT FALSE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM assert_acting_as(p_user);
  RETURN ns_put_core(p_user, p_ns, p_envelope, p_force, FALSE);
END $$;

-- importação do localStorage (só estudy_admin — ver GRANT em 0011): confia no aparelho
CREATE FUNCTION api.ns_import(p_user TEXT, p_ns TEXT, p_envelope JSONB, p_force BOOLEAN DEFAULT FALSE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM set_config('estudy.user_id', p_user, TRUE);   -- helpers de permissão respondem por este usuário
  RETURN ns_put_core(p_user, p_ns, p_envelope, p_force, TRUE);
END $$;

-- =====================================================================
-- GET — remonta o envelope no shape exato do app (e marca pulled_at)
-- =====================================================================
CREATE FUNCTION api.ns_get(p_user TEXT, p_ns TEXT) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE d JSONB; at TIMESTAMPTZ; trm terms; vis TEXT[];
BEGIN
  PERFORM assert_acting_as(p_user);
  IF ns_schema_version(p_ns) IS NULL THEN
    RAISE EXCEPTION 'namespace desconhecido: %', p_ns USING ERRCODE = '22023';
  END IF;
  SELECT client_at INTO at FROM sync_state WHERE user_id = p_user AND namespace = p_ns;
  vis := ARRAY(SELECT api.visible_workspaces(p_user));

  IF p_ns = 'identity' THEN
    SELECT jsonb_build_object(
      'userId', u.id, 'username', coalesce(i.username::text, ''), 'email', coalesce(i.email::text, ''),
      'passHash', i.pass_hash, 'provider', i.provider, 'name', coalesce(i.full_name, ''),
      'course', u.course, 'institution', u.institution, 'period', coalesce(i.period, ''),
      'avatarUrl', u.avatar_url, 'onboarded', coalesce(i.onboarded, FALSE), 'signedIn', coalesce(i.signed_in, FALSE),
      'files', coalesce((SELECT jsonb_agg(jsonb_build_object('name', a.name, 'size', a.size_bytes) ORDER BY a.id)
                         FROM assets a WHERE a.context = 'onboarding' AND a.owner_user_id = u.id
                           AND a.deleted_at IS NULL), '[]'))
      INTO d
    FROM users u LEFT JOIN identities i ON i.user_id = u.id WHERE u.id = p_user;
    IF d IS NULL THEN RETURN NULL; END IF;

  ELSIF p_ns = 'users' THEN
    WITH ids AS (
      SELECT p_user AS id
      UNION SELECT user_id FROM memberships WHERE workspace_id = ANY (vis)
      UNION SELECT owner_id FROM workspaces WHERE id = ANY (vis)
      UNION SELECT created_by FROM workspace_events WHERE workspace_id = ANY (vis) AND deleted_at IS NULL
      UNION SELECT created_by FROM tasks WHERE workspace_id = ANY (vis) AND deleted_at IS NULL
      UNION SELECT assignee_id FROM tasks WHERE workspace_id = ANY (vis) AND deleted_at IS NULL
      UNION SELECT added_by FROM assets WHERE workspace_id = ANY (vis) AND deleted_at IS NULL
      UNION SELECT author_id FROM activities WHERE workspace_id = ANY (vis) AND deleted_at IS NULL
      UNION SELECT created_by FROM invites WHERE workspace_id = ANY (vis))
    SELECT jsonb_build_object('byId', coalesce(jsonb_object_agg(u.id, jsonb_build_object(
             'id', u.id, 'displayName', u.display_name, 'avatarUrl', u.avatar_url, 'course', u.course,
             'institution', u.institution, 'createdAt', iso_ts(u.created_at), 'updatedAt', iso_ts(u.updated_at))), '{}'))
      INTO d
    FROM users u WHERE u.id IN (SELECT id FROM ids WHERE id IS NOT NULL);

  ELSIF p_ns = 'planner' THEN
    SELECT tt.* INTO trm FROM enrollments en JOIN terms tt ON tt.id = en.term_id
     WHERE en.user_id = p_user AND en.is_active;
    d := jsonb_build_object(
      'events', coalesce((SELECT jsonb_agg(jsonb_build_object(
                  'id', e.id, 'date', to_char(e.date, 'YYYY-MM-DD'), 'start', hhmm(e.start_time), 'end', hhmm(e.end_time),
                  'type', e.type, 'title', e.title, 'note', e.note, 'status', e.status,
                  'done', e.status = 'presente', 'custom', e.custom)
                  ORDER BY e.date, e.start_time, e.created_at, e.id)
                FROM planner_events e WHERE e.user_id = p_user AND e.deleted_at IS NULL), '[]'),
      'notes', coalesce((SELECT jsonb_object_agg(w.code, n.body)
                FROM week_notes n JOIN weeks w ON w.id = n.week_id
                WHERE n.user_id = p_user AND w.term_id = trm.id), '{}'),
      'goals', coalesce((SELECT jsonb_build_object('gym', g.gym_per_week, 'study', g.study_hours_per_week)
                FROM user_goals g WHERE g.user_id = p_user), '{"gym":4,"study":10}'));
    IF trm.source = 'import' THEN
      d := d || jsonb_build_object(
        'weeks', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', w.code, 'start', to_char(w.start_date,'YYYY-MM-DD'),
                    'end', to_char(w.end_date,'YYYY-MM-DD'), 'rod', w.rod_label, 'mod', w.module) ORDER BY w.start_date), '[]')
                  FROM weeks w WHERE w.term_id = trm.id),
        'baseline', (SELECT coalesce(jsonb_agg(jsonb_build_array(to_char(s.date,'YYYY-MM-DD'), hhmm(s.start_time),
                       hhmm(s.end_time), s.type, s.title) ORDER BY s.position), '[]')
                     FROM schedule_items s WHERE s.term_id = trm.id));
    END IF;

  ELSIF p_ns = 'workspace' THEN
    SELECT jsonb_build_object('workspaces', coalesce(jsonb_agg(jsonb_build_object(
      'id', w.id, 'name', w.name, 'description', w.description, 'color', 'var(--' || w.color || ')', 'icon', w.icon,
      'ownerId', w.owner_id,
      'inviteCode', coalesce(w.invite_code, (SELECT code FROM invites i WHERE i.workspace_id = w.id AND i.status = 'active'
                                            ORDER BY i.created_at LIMIT 1)),
      'createdAt', iso_ts(w.created_at), 'updatedAt', iso_ts(w.updated_at), 'dirty', FALSE,
      'events', coalesce((SELECT jsonb_agg(jsonb_build_object('id', e.id, 'date', to_char(e.date,'YYYY-MM-DD'),
                  'start', hhmm(e.start_time), 'end', hhmm(e.end_time), 'title', e.title, 'note', e.note,
                  'createdBy', e.created_by, 'createdAt', iso_ts(e.created_at)) ORDER BY e.created_at, e.id)
                FROM workspace_events e WHERE e.workspace_id = w.id AND e.deleted_at IS NULL), '[]'),
      'tasks', coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'desc', t.description,
                  'assignee', t.assignee_id, 'due', to_char(t.due_date,'YYYY-MM-DD'), 'status', t.status,
                  'comments', coalesce((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'author', a.author_id,
                                 'text', a.body, 'at', iso_ts(a.created_at)) ORDER BY a.created_at, a.id)
                               FROM activities a WHERE a.task_id = t.id AND a.deleted_at IS NULL), '[]'),
                  'createdBy', t.created_by, 'createdAt', iso_ts(t.created_at)) ORDER BY t.created_at, t.id)
                FROM tasks t WHERE t.workspace_id = w.id AND t.deleted_at IS NULL), '[]'),
      'files', coalesce((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'size', s.size_bytes,
                  'ext', s.ext, 'addedBy', s.added_by, 'addedAt', iso_ts(s.added_at), 'aiStatus', s.ai_status,
                  'stored', s.stored) ORDER BY s.added_at, s.id)
                FROM assets s WHERE s.workspace_id = w.id AND s.context = 'workspace' AND s.deleted_at IS NULL), '[]'),
      'comments', coalesce((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'author', a.author_id, 'text', a.body,
                  'at', iso_ts(a.created_at), 'parentId', a.parent_id) ORDER BY a.created_at, a.id)
                FROM activities a WHERE a.workspace_id = w.id AND a.task_id IS NULL AND a.deleted_at IS NULL), '[]')
      ) ORDER BY w.created_at, w.id), '[]'))
      INTO d
    FROM workspaces w WHERE w.id = ANY (vis);

  ELSIF p_ns = 'memberships' THEN
    SELECT jsonb_build_object('items', coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'workspaceId', m.workspace_id, 'userId', m.user_id, 'role', m.role,
      'responsibility', m.responsibility, 'joinedAt', iso_ts(m.joined_at), 'status', m.status,
      'permissions', m.permissions) ORDER BY m.joined_at, m.id), '[]'))
      INTO d
    FROM memberships m WHERE m.workspace_id = ANY (vis);

  ELSIF p_ns = 'invites' THEN
    SELECT jsonb_build_object('items', coalesce(jsonb_agg(jsonb_build_object(
      'id', i.id, 'workspaceId', i.workspace_id, 'code', i.code, 'createdBy', i.created_by,
      'createdAt', iso_ts(i.created_at), 'expiresAt', iso_ts(i.expires_at), 'maxUses', i.max_uses,
      'currentUses', i.current_uses, 'status', i.status) ORDER BY i.created_at, i.id), '[]'))
      INTO d
    FROM invites i WHERE i.workspace_id = ANY (vis);
  END IF;

  -- marca o GET: base da proteção por linha em ns_put(workspace)
  INSERT INTO sync_state (user_id, namespace, schema_version, pulled_at)
  VALUES (p_user, p_ns, ns_schema_version(p_ns), now())
  ON CONFLICT (user_id, namespace) DO UPDATE SET pulled_at = now();

  RETURN jsonb_build_object('v', ns_schema_version(p_ns), 'at', iso_ts(coalesce(at, now())), 'data', d);
END $$;

-- Dados de demonstração (wsSeed/seedParticipants): exclusão lógica, só estudy_admin (regra §9).
-- is_mock só é marcado na importação (ns_import), nunca por um usuário comum.
CREATE FUNCTION api.purge_mocks() RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE nw INT;
BEGIN
  UPDATE workspaces SET deleted_at = now() WHERE is_mock AND deleted_at IS NULL;
  GET DIAGNOSTICS nw = ROW_COUNT;
  RETURN jsonb_build_object('namespace', 'purge', 'workspaces', nw);
END $$;
