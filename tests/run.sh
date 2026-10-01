#!/usr/bin/env bash
# Bateria completa: banco limpo → migrations → seed → testes SQL → ida e volta de cada fixture.
# Uso: ADMIN_URL=postgresql://postgres@localhost:5432/postgres ./tests/run.sh
# (cria e apaga o banco estudy_test; precisa de um usuário que possa CREATE DATABASE)
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ADMIN_URL:=postgresql://postgres@localhost:5432/postgres}"
DB=estudy_test
TEST_URL="$(echo "$ADMIN_URL" | sed -E "s#/[^/?]+(\?|$)#/$DB\1#")"
export DATABASE_URL="$TEST_URL"

fresh() {
  psql "$ADMIN_URL" -X -q -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB" >/dev/null 2>&1
  ./scripts/migrate.sh --seed >/dev/null
}

echo "== migrations + seed"; fresh; echo "✓ $(ls db/migrations/*.sql | wc -l | tr -d ' ') migrations aplicadas"

echo "== testes de regra"
for f in tests/sql/*.sql; do
  out=$(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f "$f" 2>&1) || { echo "✗ $f"; echo "$out"; exit 1; }
  echo "$out" | grep -o 'ok [0-9]* — .*' || true
done

echo "== ida e volta (localStorage → banco → localStorage)"
for fx in tests/fixtures/*.json; do
  fresh
  node scripts/import-localstorage.mjs "$fx" --apply >/dev/null
  node tests/roundtrip.mjs "$fx"
done
if [ -d server/node_modules ] && [ -f reference/planner_aluno026.html ]; then
  echo "== ponta a ponta (planner_aluno026.html real no Chromium ↔ banco)"
  fresh
  node scripts/import-localstorage.mjs tests/fixtures/device-full.json --apply >/dev/null
  E2E_USER=65e69ccc-dc25-4265-b725-096d34a3af54 node server/e2e.mjs
else
  echo "(e2e pulado: rode 'npm install' em server/ para habilitar)"
fi
psql "$ADMIN_URL" -X -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1
echo "== tudo verde"
