# ESTUDY — Especificação de Banco de Dados

> **Propósito deste documento.** Fonte única para implementar o banco de dados do
> sistema Estudy inteiro. Todo o modelo aqui descrito foi **extraído do código
> funcional** (`planner_aluno026.html`, validado em navegador real em 30/09/2026)
> — nenhuma estrutura foi inventada. Acompanham este documento:
>
> | Arquivo | Papel |
> |---|---|
> | `planner_aluno026.html` | O sistema funcionando. Fonte de verdade do comportamento |
> | `estudy-seed.json` | Dados reais para carga inicial: 20 semanas + 160 eventos + enums |
> | Este `.md` | Dicionário de dados, regras, DDL proposto e estratégia de migração |
>
> Seções 1–6 são **fato extraído do código** (o que o sistema é hoje).
> Seções 7–9 são **proposta de implementação** (como levar isso a um banco real).

---

## 1. Contexto em uma página

O Estudy é o sistema operacional da vida acadêmica de um estudante de Medicina
em internato. Usuária real: `ALUNO_026`, ciclo 2026.2, dois rodízios —
**SMI** (Saúde da Mulher e da Criança, S02–S11) e **SA** (Saúde do Adulto,
S12–S21), de 27/07/2026 a 13/12/2026.

Dois domínios de dados, **estritamente separados por decisão arquitetural**:

- **Planner (pessoal)** — o cronograma do aluno: eventos, presenças, anotações,
  metas. Jamais se mistura com dados colaborativos.
- **Workspace (colaborativo)** — grupos de estudo, TCC, monitoria: participantes,
  tarefas, calendário próprio, arquivos, comentários.

Hoje tudo persiste em `localStorage` num Store com namespaces, versionamento e
migrações. O banco de dados substitui essa camada — e o Store foi desenhado
exatamente para isso ("Gravação delegada ao Kernel", sync por namespace).

---

## 2. Arquitetura de persistência atual (fato)

### 2.1 O Store

Cada domínio grava num **namespace** isolado, com chave `estudy:<nome>`.
O que vai ao armazenamento é sempre um **envelope**:

```json
{ "v": 2, "at": "2026-09-30T13:26:00.000Z", "data": { ... } }
```

- `v` — schemaVersion do namespace
- `at` — timestamp ISO da gravação
- `data` — o estado do domínio

Propriedades do Store: debounce de **400ms**, `flushSync` em `beforeunload`,
`onChange` por namespace, **migrações declarativas** (`migrations: {2: fn, 3: fn}`)
rodadas na carga quando `v` gravado < schemaVersion atual, e `legacyKey` para
adotar dados de instalações antigas.

### 2.2 Os 6 namespaces

| Chave | v | Conteúdo de `data` |
|---|---|---|
| `estudy:identity` | 2 | Identidade do aparelho + sessão (objeto único) |
| `estudy:users` | 1 | `{ byId: { [userId]: User } }` |
| `estudy:planner` | 2 | `{ events: Event[], notes: {}, goals: {} }` |
| `estudy:workspace` | 3 | `{ workspaces: Workspace[] }` |
| `estudy:memberships` | 1 | `{ items: Membership[] }` |
| `estudy:invites` | 1 | `{ items: Invite[] }` |

### 2.3 Histórico de migrações (importa para o banco!)

- `identity v1→v2`: nasce o `userId` (uuid) persistente — fim do literal `'u_me'`
- `planner v1→v2`: presença deixa de ser booleano `done` e vira `status` de 4 valores
- `workspace v1→v2`: todo `'u_me'` no JSON vira o userId real
- `workspace v2→v3`: **normalização** — `members[]` embutido em cada workspace é
  desmontado em três entidades próprias: `User` (perfil), `Membership`
  (papel/responsabilidade/permissões) e `Invite` (código). *Esta migração é o
  desenho do modelo relacional feito pelo próprio sistema.*

---

## 3. Dicionário de dados (fato — shapes exatos do código)

### 3.1 Identity — `estudy:identity`

Identidade do aparelho (existe desde o primeiro boot) + estado de sessão.

```ts
{
  userId: string(uuid),      // identidade permanente do aparelho
  username: string, email: string,
  passHash: string|null, provider: string|null,   // autenticação preparada
  name: string, course: string, institution: string, period: string,
  avatarUrl: string|null,
  onboarded: boolean, signedIn: boolean,
  files: []                  // uploads do onboarding
}
```

### 3.2 User — `estudy:users.byId[id]`

Perfil público, referenciável por qualquer domínio (contrato `UserRef`).

```ts
{ id, displayName, avatarUrl: string|null, course, institution,
  createdAt: ISO, updatedAt: ISO }
```

### 3.3 Planner — `estudy:planner` (PESSOAL)

```ts
{
  events: Array<{
    id: string,
    date:  'YYYY-MM-DD',
    start: 'HH:MM', end: 'HH:MM',
    type:  TYPE,               // enum §4.1
    title: string,
    note:  string,
    status: STATUS,            // enum §4.2 — ciclo de presença
    done:  boolean,            // LEGADO v1, mantido por compatibilidade
    custom: boolean            // true = criado pelo aluno; false = veio da grade
  }>,
  notes: { [weekId: 'S02'..'S21']: string },   // anotações por semana
  goals: { gym: 4, study: 10 }                 // metas semanais (padrão real)
}
```

### 3.4 Workspace — `estudy:workspace.workspaces[]` (COLABORATIVO)

```ts
{
  id, name, description,
  color: string, icon: string,          // identidade visual (8 opções cada)
  ownerId: string(→User),
  inviteCode: string,
  createdAt: ISO, updatedAt: ISO, dirty: boolean,   // dirty = flag de sync

  events: Array<{      // calendário próprio — NÃO toca o planner pessoal
    id, date, start, end, title, note, createdBy(→User), createdAt }>,

  tasks: Array<{
    id, title, desc, assignee: string|null(→User), due: 'YYYY-MM-DD'|null,
    status: 'aberta'|'andamento'|'concluida',
    comments: Array<{ id, author(→User), text, at: ISO }>,
    createdBy(→User), createdAt }>,

  files: Array<{       // Assets — ciclo de IA preparado
    id, name, size: number, ext: 'pdf'|'docx'|'jpeg'|'png',
    addedBy(→User), addedAt: ISO,
    aiStatus: 'pendente',              // futuro: resumo/flashcards/embeddings
    stored: boolean }>,               // false = só metadados, binário não guardado

  comments: Array<{    // mural do workspace — já é um tipo de Activity
    id, author(→User), text, at: ISO, parentId: string|null }>  // thread preparada
}
```

### 3.5 Membership — `estudy:memberships.items[]`

```ts
{ id, workspaceId(→Workspace), userId(→User),
  role: 'owner'|'admin'|'editor'|'member'|'viewer',
  responsibility: string,              // texto livre ("Estatística", "Resumos")
  joinedAt: ISO, status: 'active',
  permissions: { ...matriz §4.4 } }    // snapshot derivado do role
```

### 3.6 Invite — `estudy:invites.items[]`

```ts
{ id, workspaceId(→Workspace), code: string,
  createdBy(→User), createdAt: ISO,
  expiresAt: ISO|null, maxUses: number|null, currentUses: 0,
  status: 'active' }
```

---

## 4. Enums e constantes (fato)

### 4.1 Tipos de atividade (9)

`CAMPO · TEORIA · PROVA · SIMULACAO · MEDWAY · ACOLHIMENTO · ACADEMIA · ESTUDO · PESSOAL`

Cada tipo tem cor e fundo próprios na UI (a legenda visual vive no HTML).

### 4.2 Status de presença — ciclo de 4 estados

```
pendente → presente(✓) → falta(✕) → justificada(!) → pendente ...
```

### 4.3 Status de tarefa (3)

`aberta · andamento · concluida`

### 4.4 Papéis × permissões (matriz exata do código)

| permissão | owner | admin | editor | member | viewer |
|---|---|---|---|---|---|
| manageWorkspace | ✓ | ✓ | — | — | — |
| manageMembers | ✓ | ✓ | — | — | — |
| manageInvites | ✓ | ✓ | — | — | — |
| manageTasks | ✓ | ✓ | ✓ | ✓ | — |
| manageEvents | ✓ | ✓ | ✓ | ✓ | — |
| manageAssets | ✓ | ✓ | ✓ | ✓ | — |
| comment | ✓ | ✓ | ✓ | ✓ | ✓ |
| view | ✓ | ✓ | ✓ | ✓ | ✓ |
| deleteWorkspace | ✓ | — | — | — | — |

### 4.5 Estrutura do semestre (dados reais em `estudy-seed.json`)

- 20 semanas: `S02` (2026-07-27) … `S21` (2026-12-07..13)
- `S02–S11` → Rodízio 1 / SMI · `S12–S21` → Rodízio 2 / SA
- Cada semana: `{ id, start: 'YYYY-MM-DD' (segunda), rod, mod }` + 6 dias
- **160 eventos** da grade oficial da faculdade
- Provas reais: AVD 31/07 · AV1 14/08 · AV2 04/09 · AV3 18/10 · AV4 08/11
- Timeline do dia: 05:30–22:30 (marcas em 8h/12h/16h/20h)

---

## 5. Regras de negócio que o banco deve garantir (fato)

1. **Planner é pessoal; Workspace é colaborativo.** Nenhuma consulta ou FK cruza
   os dois lados exceto via `userId`. O calendário do workspace nunca escreve no
   planner do aluno.
2. **Presença é o ciclo de 4 estados** — nunca booleano (a migração v2 existe
   exatamente para isso). Marcação é idempotente.
3. **Dia livre** = dia sem eventos `CAMPO`, `TEORIA` ou `PROVA` (eventos de
   outros tipos não "ocupam" o dia — ex.: Sáb 03/10 só tem Medway online e
   conta como livre). Não confundir com **"dia sem evento"**, o stat card da
   UI, que exige zero eventos de qualquer tipo. São duas consultas distintas.
4. **Todo arquivo é um Asset** com ciclo de vida próprio (`aiStatus` desde o
   nascimento) — extensões aceitas: pdf, docx, jpeg, png; demais são recusadas.
5. **Comentário é um tipo de Activity** (decisão do arquiteto): já nasce com
   `parentId` para threads; no banco, modele como atividade genérica.
6. **Convite**: código único por workspace; `expiresAt`/`maxUses` já previstos
   no contrato mesmo que hoje não sejam impostos.
7. **Permissões derivam do papel** (matriz §4.4). O snapshot em Membership
   existe para o dia em que houver granularidade por membro — mantenha os dois.
8. **`u_me` está proibido**: toda referência a pessoa usa `userId` real.
9. Eventos importados da grade têm `custom:false`; criados pelo aluno,
   `custom:true` — preserve a distinção (permite reimportar a grade sem
   destruir o que o aluno criou).
10. Metas semanais padrão: `gym: 4` treinos, `study: 10` blocos.

### Domain Events (Bus) — base para triggers/outbox no backend

```
user.upserted
planner.event.created / updated
workspace.created · workspace.member.added
workspace.task.created / updated / deleted
workspace.event.created · workspace.asset.uploaded
workspace.activity.created
```

---

## 6. O que existe no monorepo Next.js (contexto)

Além do HTML, existe um monorepo TypeScript (`estudy-1.0-source.zip`) com o
mesmo domínio em packages puros (`@estudy/planner`: `Activity`, `Week`,
`Semester` imutáveis; persistência via interface `PersistenceDriver`, chave
`estudy:planner:v1`). O banco deve servir aos dois clientes; onde os shapes
divergirem, **o HTML é a referência de produto** (é a versão que o usuário usa)
e o monorepo se adapta via `PersistenceDriver` — essa interface existe
exatamente para trocar localStorage por API sem tocar componente algum.

---

## 7. PROPOSTA — Esquema relacional (PostgreSQL)

> Derivado 1:1 do modelo acima. Nomes em `snake_case`. UUIDs onde o app usa uuid;
> os ids curtos existentes (`uid()`) cabem em `TEXT` — na migração, preserve os
> ids originais para não quebrar referências.

```sql
-- ============ ENUMS ============
CREATE TYPE activity_type   AS ENUM ('CAMPO','TEORIA','PROVA','SIMULACAO','MEDWAY',
                                     'ACOLHIMENTO','ACADEMIA','ESTUDO','PESSOAL');
CREATE TYPE presence_status AS ENUM ('pendente','presente','falta','justificada');
CREATE TYPE task_status     AS ENUM ('aberta','andamento','concluida');
CREATE TYPE member_role     AS ENUM ('owner','admin','editor','member','viewer');
CREATE TYPE asset_ext       AS ENUM ('pdf','docx','jpeg','png');
CREATE TYPE ai_status       AS ENUM ('pendente','processando','concluido','erro');

-- ============ IDENTIDADE ============
CREATE TABLE users (
  id           TEXT PRIMARY KEY,
  display_name TEXT NOT NULL DEFAULT '',
  avatar_url   TEXT,
  course       TEXT NOT NULL DEFAULT '',
  institution  TEXT NOT NULL DEFAULT '',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE identities (              -- espelho do namespace identity (1:1 com users)
  user_id    TEXT PRIMARY KEY REFERENCES users(id),
  username   TEXT UNIQUE,
  email      TEXT UNIQUE,
  pass_hash  TEXT,
  provider   TEXT,
  period     TEXT NOT NULL DEFAULT '',
  onboarded  BOOLEAN NOT NULL DEFAULT FALSE
);

-- ============ ESTRUTURA DO SEMESTRE (dados de referência) ============
CREATE TABLE rotations (
  id     TEXT PRIMARY KEY,             -- 'Rod1' | 'Rod2'
  module TEXT NOT NULL,                -- 'SMI' | 'SA'
  name   TEXT NOT NULL
);

CREATE TABLE weeks (
  id          TEXT PRIMARY KEY,        -- 'S02'..'S21'
  rotation_id TEXT NOT NULL REFERENCES rotations(id),
  start_date  DATE NOT NULL            -- segunda-feira; semana = start..start+6
);

-- ============ PLANNER (PESSOAL) ============
CREATE TABLE planner_events (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id),
  date       DATE NOT NULL,
  start_time TIME,
  end_time   TIME,
  type       activity_type   NOT NULL,
  title      TEXT NOT NULL,
  note       TEXT NOT NULL DEFAULT '',
  status     presence_status NOT NULL DEFAULT 'pendente',
  custom     BOOLEAN NOT NULL DEFAULT FALSE,   -- false = veio da grade oficial
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_planner_user_date ON planner_events(user_id, date);

CREATE TABLE week_notes (
  user_id TEXT NOT NULL REFERENCES users(id),
  week_id TEXT NOT NULL REFERENCES weeks(id),
  body    TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (user_id, week_id)
);

CREATE TABLE user_goals (
  user_id        TEXT PRIMARY KEY REFERENCES users(id),
  gym_per_week   INT NOT NULL DEFAULT 4,
  study_per_week INT NOT NULL DEFAULT 10
);

-- ============ WORKSPACE (COLABORATIVO) ============
CREATE TABLE workspaces (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  color       TEXT NOT NULL,
  icon        TEXT NOT NULL,
  owner_id    TEXT NOT NULL REFERENCES users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE memberships (
  id             TEXT PRIMARY KEY,
  workspace_id   TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id        TEXT NOT NULL REFERENCES users(id),
  role           member_role NOT NULL DEFAULT 'member',
  responsibility TEXT NOT NULL DEFAULT '',
  joined_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  status         TEXT NOT NULL DEFAULT 'active',
  permissions    JSONB NOT NULL,        -- snapshot da matriz §4.4
  UNIQUE (workspace_id, user_id)
);

CREATE TABLE invites (
  id           TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  code         TEXT NOT NULL UNIQUE,
  created_by   TEXT NOT NULL REFERENCES users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at   TIMESTAMPTZ,
  max_uses     INT,
  current_uses INT NOT NULL DEFAULT 0,
  status       TEXT NOT NULL DEFAULT 'active'
);

CREATE TABLE workspace_events (          -- calendário do workspace, isolado do planner
  id           TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  date         DATE NOT NULL,
  start_time   TIME, end_time TIME,
  title        TEXT NOT NULL,
  note         TEXT NOT NULL DEFAULT '',
  created_by   TEXT NOT NULL REFERENCES users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_wsevents ON workspace_events(workspace_id, date);

CREATE TABLE tasks (
  id           TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  title        TEXT NOT NULL,
  description  TEXT NOT NULL DEFAULT '',
  assignee_id  TEXT REFERENCES users(id),
  due_date     DATE,
  status       task_status NOT NULL DEFAULT 'aberta',
  created_by   TEXT NOT NULL REFERENCES users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_tasks ON tasks(workspace_id, status);

CREATE TABLE assets (
  id           TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  size_bytes   BIGINT NOT NULL,
  ext          asset_ext NOT NULL,
  added_by     TEXT NOT NULL REFERENCES users(id),
  added_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  ai_status    ai_status NOT NULL DEFAULT 'pendente',
  stored       BOOLEAN NOT NULL DEFAULT FALSE,
  storage_url  TEXT                    -- preenchido quando o binário subir
);

-- Comentário = tipo de Activity (regra §5.5): mural E comentários de tarefa
-- vivem na mesma tabela, distinguidos pelo alvo.
CREATE TABLE activities (
  id           TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL DEFAULT 'comment',
  author_id    TEXT NOT NULL REFERENCES users(id),
  body         TEXT NOT NULL,
  parent_id    TEXT REFERENCES activities(id),   -- thread
  target_type  TEXT,                             -- NULL = mural | 'task'
  target_id    TEXT,                             -- ex.: tasks.id
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_activities ON activities(workspace_id, created_at DESC);
```

**Decisões desta proposta (e por quê):**
- `done` (legado) não vira coluna — a migração v2 já o converteu em `status`.
- Comentários de tarefa saem do array embutido e vão para `activities` com
  `target_type='task'` — é a direção que o arquiteto fixou (Épico 6: Activity).
- `permissions JSONB` preserva o snapshot que o app grava, sem impedir a
  derivação por `role`.
- `ai_status` ganha os estados futuros (`processando/concluido/erro`) — o app
  hoje só usa `pendente`, mas o enum nasce completo para o pipeline de IA.
- Ids `TEXT` para aceitar os ids curtos existentes na migração de dados.

---

## 8. PROPOSTA — Estratégia de migração localStorage → banco

O caminho já está pavimentado pelo próprio app:

1. **Leitura**: para cada namespace `estudy:*`, ler o envelope, verificar `v`
   e aplicar as `migrations` pendentes (o código delas está no HTML, seção
   correspondente de cada namespace) antes de importar.
2. **Mapeamento** (envelope → tabelas):
   - `identity` → `users` + `identities` (upsert pelo `userId`)
   - `users.byId` → `users`
   - `planner.events[]` → `planner_events` · `planner.notes` → `week_notes` ·
     `planner.goals` → `user_goals`
   - `workspace.workspaces[]` → `workspaces` + `workspace_events` + `tasks` +
     `assets`; `comments[]` e `tasks[].comments[]` → `activities`
   - `memberships.items` → `memberships` · `invites.items` → `invites`
3. **Sync no cliente**: o Store já expõe `flush()` por namespace e a flag
   `dirty` por workspace — o adaptador de backend substitui
   `window.storage.{get,set}` por chamadas HTTP mantendo o contrato
   (`get → {value}` | `set(k, jsonString)`). *Foi exatamente assim que o
   adaptador localStorage standalone foi injetado; o de rede é o mesmo ponto
   de encaixe, 12 linhas.*
4. **Conflito**: `at` do envelope dá last-write-wins por namespace como
   primeira versão; granularidade por entidade vem depois.

---

## 9. PROPOSTA — Carga inicial (seed)

Ordem de inserção com `estudy-seed.json`:

```
rotations (2) → weeks (20) → users (ALUNO_026) →
planner_events (160, status='pendente', custom=false) →
user_goals (gym 4 / study 10)
```

O JSON traz cada evento como `{date, start, end, type, title}` — mapeamento
direto para `planner_events`. Workspaces de exemplo (Grupo de Estudos, TCC)
existem no HTML como mock declarado ("substituíveis pelo backend") — **não**
os carregue como dados de produção.

---

## 10. Checklist para a sessão de implementação no Cowork

- [ ] Criar enums e tabelas da §7 (ordem do DDL já resolve dependências)
- [ ] Carregar seed da §9 a partir de `estudy-seed.json`
- [ ] Implementar endpoints (ou driver) com o contrato `window.storage` da §8.3
- [ ] Testar com o próprio `planner_aluno026.html` apontando para o backend
- [ ] Validar as 10 regras da §5 com constraints/testes
- [ ] Não usar `u_me`, não usar booleano para presença, não misturar
      planner pessoal com workspace

---

## Validação executada (evidência, não promessa)

Tudo neste documento foi verificado por execução em 30/09/2026:

| O quê | Como | Resultado |
|---|---|---|
| Sistema de referência | Chromium headless (Playwright) | Renderiza, navega, cicla presença e restaura pós-reload, zero erros JS |
| Shapes das entidades | Extraídos do código-fonte do HTML | Seções 2–4 citam linha a linha |
| Seed | `eval` dos literais `WEEKS`/`SEED` do próprio código | 20 semanas, 160 eventos — sem retranscrição manual |
| DDL da §7 | **Executado em PostgreSQL 16.13 real** | 6 types + 14 tables + 4 indexes, zero erros |
| Carga da §9 | 184 inserts a partir de `estudy-seed.json` | 160 eventos, 20 semanas, 5 provas nas datas corretas (AVD 31/07 · AV1 14/08 · AV2 04/09 · AV3 18/10 · AV4 08/11) |
| Regra de dia livre | Query SQL vs UI da Semana 11 | Consistente (e originou a nota da regra 3) |
