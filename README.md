# Estudy — banco de dados

Banco PostgreSQL do **Estudy**, o sistema operacional da vida acadêmica do estudante de Medicina em internato:
planner pessoal (grade, check-in de presença, metas, anotações) e workspaces colaborativos (grupos de estudo, TCC, monitoria).

O modelo foi extraído do app funcionando (`reference/planner_aluno026.html`), não inventado.
Ele parte da especificação v1 e a corrige onde o código diverge. Está validado com o próprio app:
o HTML real roda no Chromium lendo e gravando neste banco, sem nenhuma mudança no front.

```
db/
  migrations/     0001…0011 — tipos, tabelas, triggers, regras (api.*), sync, RLS
  seed/           grade oficial 2026.2 (gerada de data/estudy-seed.json)
  seed/dev/       aluno de teste (NÃO usar em produção)
data/             estudy-seed.json — 20 semanas + 160 itens da grade real
scripts/          migrate.sh · build-seed.mjs · import-localstorage.mjs · export-localstorage.js
adapter/          estudy-network-adapter.js — troca o localStorage do app pela API
server/           servidor de referência (contrato HTTP ↔ banco) + teste ponta a ponta
tests/            testes de regra em SQL, ida e volta com dumps reais, runner
types/            estudy-db.ts — tipos TypeScript das tabelas e dos namespaces
docs/             MODELO-DE-DADOS.md · AUDITORIA.md · referencia/ESTUDY-DATABASE-v1.md
reference/        planner_aluno026.html — o app (fonte de verdade do comportamento)
```

## Começar

```bash
docker compose up -d --wait          # Postgres 16 em localhost:5432
make migrate seed                    # schema + grade oficial 2026.2
make dev-seed                        # opcional: aluno de teste com os 160 eventos
make test                            # bateria completa num banco descartável
```

Sem Docker: `DATABASE_URL=postgres://… ./scripts/migrate.sh --seed`.

## Trazer os dados reais do aluno (localStorage → banco)

1. Com o `planner_aluno026.html` aberto no navegador, cole `scripts/export-localstorage.js` no console.
   O navegador baixa `estudy-localstorage.json`.
2. `make import DUMP=estudy-localstorage.json` (usa `api.ns_import`; precisa de papel `estudy_admin` ou superusuário).

O relatório mostra o que entrou e o que foi ignorado, e por quê: órfãos de workspace excluído, extensão não aceita etc.

## Apontar o app para o banco

O app só cria o adaptador de localStorage quando `window.storage` não existe (L384).
Para trocar a persistência, carregue antes do script principal:

```html
<script>window.ESTUDY_API = { baseUrl: 'https://api.seu-dominio', token: '<jwt>' };</script>
<script src="estudy-network-adapter.js"></script>
```

Para ver funcionando localmente: `cd server && npm install && cd .. && make server` e abra
`http://localhost:8787/app?user=<userId>`. O servidor injeta o adaptador no HTML.

Contrato: `GET /ns/:name → api.ns_get` · `PUT /ns/:name → api.ns_put`. Os detalhes estão em [`docs/MODELO-DE-DADOS.md` §6](docs/MODELO-DE-DADOS.md).

Em cada requisição, o backend precisa:

```sql
BEGIN;
SELECT set_config('estudy.user_id', '<id autenticado>', true);   -- obrigatório: sem ele, 42501
SELECT api.ns_get('<id>', 'planner');
COMMIT;
```

Em produção, conecte com um papel que seja membro **apenas** de `estudy_app`:
`CREATE ROLE estudy_api LOGIN PASSWORD '…'; GRANT estudy_app TO estudy_api;`

## O que foi validado (`make test`)

| Etapa | Resultado |
|---|---|
| 11 migrations num banco limpo | ok |
| Seed | 20 semanas, 160 itens, 5 provas nas datas reais (AVD 31/07 · AV1 14/08 · AV2 04/09 · AV3 18/10 · AV4 08/11) |
| `tests/sql/01–06` | referência e seed, regras do planner, regras do workspace, privilégios e RLS, API de sync, regressões da revisão de segurança |
| Ida e volta com 3 dumps reais do aparelho | **0 diferenças**: completo (180 eventos, 3 workspaces), plano importado por IA, legado v1 migrado |
| Ponta a ponta no Chromium | 16 verificações: o app lê tudo do banco (localStorage vazio), a falta marcada no app chega ao banco e volta após recarregar, o outbox registra, um aluno novo recebe a grade sem os workspaces de exemplo, zero erros de JS |

Os achados das auditorias, os bugs do app que o banco contorna e as pendências estão em [`docs/AUDITORIA.md`](docs/AUDITORIA.md).
