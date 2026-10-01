DATABASE_URL ?= postgresql://postgres:postgres@localhost:5432/estudy
ADMIN_URL    ?= postgresql://postgres:postgres@localhost:5432/postgres
export DATABASE_URL ADMIN_URL

.PHONY: up migrate seed dev-seed build-seed import test server e2e

up:          ## sobe o Postgres local (docker)
	docker compose up -d --wait

migrate:     ## aplica db/migrations (idempotente)
	./scripts/migrate.sh

seed:        ## grade oficial 2026.2 (term, rodízios, 20 semanas, 160 itens)
	./scripts/migrate.sh --seed

dev-seed:    ## aluno de teste matriculado (NÃO usar em produção)
	./scripts/migrate.sh --dev-seed

build-seed:  ## regenera db/seed/0001_term_2026_2.sql a partir de data/estudy-seed.json
	node scripts/build-seed.mjs

import:      ## make import DUMP=estudy-localstorage.json
	node scripts/import-localstorage.mjs $(DUMP) --apply --student-code ALUNO_026

test:        ## bateria completa num banco descartável (estudy_test)
	./tests/run.sh

server:      ## servidor de referência em :8787 (npm install em server/ antes)
	PLANNER_HTML=reference/planner_aluno026.html node server/index.mjs
