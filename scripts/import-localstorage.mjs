#!/usr/bin/env node
// Importa um dump do localStorage do Estudy (chaves estudy:*) para o PostgreSQL.
// Usa api.ns_put — a MESMA função que o adaptador de rede vai chamar — então
// a importação e o sync de produção passam pelo mesmo caminho validado.
//
// Uso:
//   node scripts/import-localstorage.mjs dump.json                 # imprime o SQL
//   node scripts/import-localstorage.mjs dump.json --out import.sql
//   DATABASE_URL=... node scripts/import-localstorage.mjs dump.json --apply [--student-code ALUNO_026] [--purge-mocks]
//
// O dump sai de scripts/export-localstorage.js (colar no console do navegador).
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const args = process.argv.slice(2);
const file = args.find((a) => !a.startsWith('--'));
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? (args[i + 1] ?? true) : undefined; };
if (!file) { console.error('uso: import-localstorage.mjs <dump.json> [--out f.sql] [--apply] [--student-code X] [--purge-mocks] [--force]'); process.exit(2); }

const ORDER = ['identity', 'users', 'planner', 'workspace', 'memberships', 'invites'];
const LEGACY = ['planner_profile_v1', 'planner_aluno026_v1', 'estudy_workspaces_v1'];

const raw = JSON.parse(readFileSync(file, 'utf8'));
const parse = (v) => (typeof v === 'string' ? JSON.parse(v) : v);   // aceita envelope como string ou objeto

const envelopes = {};
for (const ns of ORDER) {
  const v = raw['estudy:' + ns];
  if (v !== undefined && v !== null) envelopes[ns] = parse(v);
}
const legacy = LEGACY.filter((k) => k in raw);
if (legacy.length) {
  const onlyLegacy = !Object.keys(envelopes).length;
  console.error(`! chaves legadas presentes (${legacy.join(', ')}): ${onlyLegacy
    ? 'abra o app uma vez para ele migrar para estudy:* e exporte de novo'
    : 'ignoradas — o app já migrou para estudy:*'}`);
  if (onlyLegacy) process.exit(1);
}
if (!envelopes.identity?.data?.userId) { console.error('✗ dump sem estudy:identity.userId'); process.exit(1); }

const userId = envelopes.identity.data.userId;
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`;
const dollar = (json) => { let tag = 'estudy'; while (json.includes(`$${tag}$`)) tag += 'x'; return `$${tag}$${json}$${tag}$`; };

const sql = [
  '-- importação gerada por scripts/import-localstorage.mjs',
  `-- origem: ${file} · usuário ${userId}`,
  '-- requer papel estudy_admin (ou superusuário): api.ns_import confia no aparelho',
  'BEGIN;',
];
for (const ns of ORDER) {
  if (!envelopes[ns]) { sql.push(`-- (sem estudy:${ns})`); continue; }
  sql.push(`SELECT api.ns_import(${lit(userId)}, ${lit(ns)}, ${dollar(JSON.stringify(envelopes[ns]))}::jsonb, ${opt('--force') ? 'TRUE' : 'FALSE'});`);
}
const code = opt('--student-code');
if (code && code !== true) {
  sql.push(`UPDATE enrollments SET student_code = ${lit(code)} WHERE user_id = ${lit(userId)} AND is_active;`);
}
if (opt('--purge-mocks')) sql.push('SELECT api.purge_mocks();');
sql.push('COMMIT;', '');
const text = sql.join('\n');

const out = opt('--out');
if (out && out !== true) { writeFileSync(out, text); console.error(`✓ SQL gravado em ${out}`); }
if (!opt('--apply')) { if (!out) process.stdout.write(text); process.exit(0); }

if (!process.env.DATABASE_URL) { console.error('✗ defina DATABASE_URL para --apply'); process.exit(2); }
const r = spawnSync('psql', [process.env.DATABASE_URL, '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'], { input: text, encoding: 'utf8' });
if (r.status !== 0) { console.error(r.stderr || r.stdout); process.exit(r.status || 1); }
for (const line of r.stdout.split('\n').filter((l) => l.startsWith('{'))) {
  const rep = JSON.parse(line);
  const skipped = (rep.skipped || []).length, warns = (rep.warnings || []).length;
  console.log(`✓ ${String(rep.namespace || 'purge').padEnd(11)} ${JSON.stringify(Object.fromEntries(
    Object.entries(rep).filter(([k]) => !['namespace', 'skipped', 'warnings', 'readOnly', 'applied', 'v', 'at'].includes(k))))}`
    + (skipped ? `  · ignorados: ${skipped}` : '') + (warns ? `  · avisos: ${warns}` : ''));
  for (const s of rep.skipped || []) console.log('    - ignorado', JSON.stringify(s));
  for (const w of rep.warnings || []) console.log('    - aviso   ', JSON.stringify(w));
}
