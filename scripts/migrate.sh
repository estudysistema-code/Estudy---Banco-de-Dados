#!/usr/bin/env bash
# Aplica as migrations em ordem, uma única vez cada (tabela schema_migrations).
# Uso: DATABASE_URL=postgres://user:pass@host:5432/estudy ./scripts/migrate.sh [--seed] [--dev-seed]
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DATABASE_URL:?defina DATABASE_URL}"
PSQL=(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -X)

"${PSQL[@]}" -c "CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())"

for f in db/migrations/*.sql; do
  v=$(basename "$f" .sql)
  if [ "$("${PSQL[@]}" -Atc "SELECT 1 FROM schema_migrations WHERE version = '$v'")" = "1" ]; then
    continue
  fi
  echo "→ migration $v"
  "${PSQL[@]}" --single-transaction -f "$f" -c "INSERT INTO schema_migrations (version) VALUES ('$v')"
done

for arg in "$@"; do
  case "$arg" in
    --seed)     for f in db/seed/*.sql;     do echo "→ seed $(basename "$f")"; "${PSQL[@]}" --single-transaction -f "$f"; done ;;
    --dev-seed) for f in db/seed/dev/*.sql; do echo "→ dev seed $(basename "$f")"; "${PSQL[@]}" --single-transaction -f "$f"; done ;;
  esac
done
echo "✓ banco atualizado"
