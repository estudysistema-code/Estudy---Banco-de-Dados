# ESTUDY — Auditoria do ecossistema e do banco (30/09/2026)

Este documento registra o que foi verificado, **com execução real**, antes de fechar o banco:

1. uma auditoria de código × especificação (todo o JavaScript do HTML lido, L369–3192);
2. uma auditoria de produto (o app aberto no Chromium, 58 telas, todos os fluxos, dump real do localStorage);
3. duas rodadas de revisão adversarial de segurança e integridade, feitas por um revisor independente.

## 1. O que a especificação v1 errava

| Onde | O que dizia | O que o código faz | Como ficou no banco |
|---|---|---|---|
| §5 regra 3 | "Dia livre = sem CAMPO/TEORIA/PROVA; Sáb 03/10 (só Medway) é livre" | Nenhum trecho usa esse conjunto. `isAcad` = tudo menos ACADEMIA/ESTUDO/PESSOAL (L977), então Medway **é** atividade oficial | duas funções: `is_empty_day` (zero eventos) e `is_free_of_official` (sem acadêmico) |
| §3.3 / §5.10 | `goals.study` = "10 blocos" | soma **horas** de ESTUDO (L1471, "Estudo (h)") | `study_hours_per_week NUMERIC(4,1)` |
| §3.3 | planner = `{events, notes, goals}` | também grava `weeks` e `baseline` ao importar plano por IA (L3103) | `terms` por aluno + `schedule_items` |
| §7 | semanas globais `S02..S21` | semanas recriadas por plano (S01..S60, `GERAL`) | `weeks` por `term` |
| §4 / §5.4 | extensões pdf, docx, jpeg, png | aceita e grava também `jpg` (L2855) | enum com `jpg` |
| §3.5 / §3.6 | status `active` | membership também `removed`; convite `exhausted`/`revoked` | enums completos |
| §5.7 | permissões derivam do papel | `canOn` lê o **snapshot** (L2135) | snapshot sempre rederivado por trigger |
| §5 Bus | 11 eventos | 34 declarados, 30 emitidos (L507–521) | `domain_event_catalog` com os 34 |
| §9 | `users (ALUNO_026)` | o id é o uuid da identity; `ALUNO_026` é código de aluno | `enrollments.student_code` |
| §7 | `UNIQUE(workspace_id,user_id)` | remoção é lógica e reentrar cria linha nova (L1966) | índice único parcial `WHERE status='active'` |
| §7 | `username`/`email UNIQUE` | OAuth grava `''` e o literal `usuario.google` para todos (L2947) | `''`→NULL; username único só para `provider='email'` |

**Prova de que o DDL v1 não aguentava o app:** carregando o dump real do localStorage no DDL da §7,
**22 de 274 inserts falharam** (18 eventos sem `status`, 1 `jpg`, 2 órfãos de workspace excluído, 1 FK de semana S01).
No banco v2: **0 falhas** — e os três dumps (completo, plano importado, legado migrado) voltam do banco **idênticos**.

## 2. Funcionalidades do app × suporte no banco

Todas as funcionalidades encontradas têm tabela/coluna/função. As que **não tinham** na v1 e passaram a ter:

- Restaurar agenda original → `schedule_items` + `api.restore_baseline`
- Plano importado por IA com semanas próprias → `terms(source='import')`, `weeks`, `schedule_items`, `ai_jobs`
- Arquivos do onboarding → `assets(context='onboarding')`
- Presença por matéria → `planner_events.subject` (gerada)
- Registro retroativo → `attendance_marked_at`
- Quem resgatou convite → `invite_redemptions`, `memberships.invite_id`
- Sync sem ressuscitar excluídos → `deleted_at` + `sync_state`

Intencionalmente **fora** do banco: estado de UI (aba, semana selecionada, busca — só memória/URL), presença online (mock), toasts.

## 3. Bugs do app encontrados (para o time de front)

O banco já se protege de todos; o app deveria corrigir na origem.

| # | Bug | Linha | Impacto |
|---|---|---|---|
| 1 | "Aplicar todas as sugestões" grava evento **sem `status`** | L1775 | depende do fallback `done` |
| 2 | Permissões só checadas na **criação**: viewer edita/exclui tarefa e evento, qualquer um comenta | L2771, L2780, L2633 | no banco, RLS e `ns_put` recusam |
| 3 | Excluir workspace deixa memberships/convites **órfãos**; código órfão "não encontrado" | L2526, L2561 | banco faz CASCADE |
| 4 | Migração v3 gera `inviteCode` **sem criar o convite** | L2104/L2110 | `ensure_workspace_invite` |
| 5 | `avatarUrl` e ids interpolados **sem escape** em `style="url(...)"` → XSS armazenado | L2127 | CHECK `users_avatar_safe` + `users_id_format` |
| 6 | Senha = SHA-256 **sem salt, no cliente** | L2852 | `pass_algo='sha256-client'`: refazer hash no servidor (argon2id) |
| 7 | `io.set` engole erro e zera `dirty`: gravação perdida sem aviso | L437, L489 | `ns_put` pula só o item ruim; adaptador emite `estudy:synced` |
| 8 | GET que falha → app parte do seed e o grava por cima | L426 | adaptador bloqueia o PUT daquele namespace até recarregar |
| 9 | Lista **todos** os workspaces do aparelho, sem filtrar por membership | L2230 | `ns_get` só devolve os visíveis |
| 10 | `uid()` = 7 caracteres base36 sem checar colisão | L907 | usar `crypto.randomUUID()` (ver pendência P2) |
| 11 | Chamada direta à API da Anthropic do navegador, sem chave | L3071 | mover para o backend (`ai_jobs`) |
| 12 | Provas AV3 (18/10) e AV4 (08/11) caem em **domingo** | seed | confirmar com a faculdade |

## 4. Revisão adversarial de segurança

Um revisor independente tentou quebrar o banco com SQL executado de verdade.

**Rodada 1:** 7 críticos, 9 altos e 4 médios, entre eles: escalar papel e adulterar membership de outro workspace pelo sync;
funções `SECURITY DEFINER` agindo por qualquer usuário sem sessão; a view vazando o planner de todos;
admin tomando posse do workspace; o modo de importação acionável pelo próprio app; sequestro de `search_path` via `pg_temp`;
um item malformado derrubando o namespace inteiro; cópia antiga de outro membro apagando tarefa nova.

**Rodada 2** (após as correções): **todos os 7 críticos e 8 dos 9 altos confirmados como corrigidos.**
Os casos restantes foram corrigidos a seguir: cópia antiga reativando membro removido ou convite revogado,
importação de dump antigo sobre workspace de terceiro, identity parcial apagando credenciais, e-mail repetido
descartando a senha, app forjando job de IA concluído e `updated_at` gravável no futuro.
Cada ataque virou um caso nos testes `tests/sql/04`–`06`.

Controles que ficaram no banco:

- sem usuário na sessão (`estudy.user_id`), nenhuma função age: 42501
- nenhuma função é executável por PUBLIC; `GRANT` explícito para `estudy_app`
- `UPDATE` concedido por coluna: ninguém troca dono, workspace ou autor de uma linha
- `search_path = public, pg_temp` e `REVOKE TEMPORARY`
- importação só por `api.ns_import`, com papel `estudy_admin`
- outbox só escrito por trigger

## 5. Pendências conhecidas (decisão do time)

| # | Pendência | Risco | Caminho proposto |
|---|---|---|---|
| P1 | O mesmo usuário em **dois aparelhos**: a proteção por linha é por usuário, então uma cópia antiga do aparelho B pode sobrescrever o que outros membros fizeram depois do GET do aparelho A | perda de edição em workspace compartilhado | o adaptador gera um `deviceId` (localStorage) e manda no cabeçalho; `sync_state` passa a ser por `(user, device, namespace)` |
| P2 | PK global em ids gerados no cliente (`'e'`+7 base36): colisão entre usuários vira `id_conflict` | baixo hoje, cresce com a escala | app trocar `uid()` por `crypto.randomUUID()` (o banco já aceita) |
| P3 | Senha `sha256-client` não é credencial segura | alto quando abrir o login real | auth no servidor (argon2id) ou provedor OAuth; no 1º login, refazer o hash |
| P4 | Binários ainda não sobem (`stored=false`) | nenhum hoje | bucket + `storage_key`; worker de IA consumindo `ai_jobs` / `assets.ai_status` |
| P5 | `avatar_url` pode ser data URI grande | tamanho de linha | mover para o storage e guardar só a URL |
| P6 | Servidor de referência faz login como superusuário em dev | só dev | produção: login com papel membro apenas de `estudy_app` |
| P7 | Semanas com a mesma data dentro de um plano importado recusam o namespace planner inteiro | o app nunca gera isso | pular a semana duplicada |
