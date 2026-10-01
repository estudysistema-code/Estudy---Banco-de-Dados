#!/usr/bin/env node
// Gera db/seed/0001_term_2026_2.sql a partir de data/estudy-seed.json.
// Sem dependências. Uso: node scripts/build-seed.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const seed = JSON.parse(readFileSync(join(root, 'data/estudy-seed.json'), 'utf8'));
const q = (v) => (v === null || v === undefined ? 'NULL' : `'${String(v).replace(/'/g, "''")}'`);

const TERM = seed.aluno.ciclo;                   // '2026.2'
const rodByLabel = { 'Rodízio 1': 'Rod1', 'Rodízio 2': 'Rod2' };
const labelByRod = { Rod1: 'Rodízio 1', Rod2: 'Rodízio 2' };

const weeks = seed.weeks;
const lastWeek = weeks[weeks.length - 1];
const endDate = new Date(lastWeek.start + 'T00:00:00Z');
endDate.setUTCDate(endDate.getUTCDate() + 6);
const termEnd = endDate.toISOString().slice(0, 10);

const out = [];
out.push(`-- GERADO por scripts/build-seed.mjs a partir de data/estudy-seed.json — não edite à mão.
-- Grade oficial do ciclo ${TERM} (${seed.extraidoDe}).
-- ${seed.rodizios.length} rodízios · ${weeks.length} semanas · ${seed.events.length} itens de grade.
-- Idempotente: pode rodar de novo sem duplicar.
SET LOCAL estudy.skip_outbox = 'on';
`);

out.push(`INSERT INTO terms (id, label, source, course, start_date, end_date) VALUES
  (${q(TERM)}, ${q('Agenda 9P ' + TERM)}, 'seed', ${q(seed.aluno.curso)}, ${q(weeks[0].start)}, ${q(termEnd)})
ON CONFLICT (id) DO UPDATE SET label = EXCLUDED.label, start_date = EXCLUDED.start_date, end_date = EXCLUDED.end_date;
`);

out.push(`INSERT INTO rotations (id, term_id, code, label, module, name, sort_order) VALUES
${seed.rodizios.map((r, i) => `  (${q(TERM + ':' + r.id)}, ${q(TERM)}, ${q(r.id)}, ${q(labelByRod[r.id])}, ${q(r.modulo)}, ${q(r.nome)}, ${i + 1})`).join(',\n')}
ON CONFLICT (id) DO UPDATE SET label = EXCLUDED.label, module = EXCLUDED.module, name = EXCLUDED.name;
`);

out.push(`INSERT INTO weeks (id, term_id, code, rotation_id, rod_label, module, start_date) VALUES
${weeks.map((w) => `  (${q(TERM + ':' + w.id)}, ${q(TERM)}, ${q(w.id)}, ${q(TERM + ':' + rodByLabel[w.rod])}, ${q(w.rod)}, ${q(w.mod)}, ${q(w.start)})`).join(',\n')}
ON CONFLICT (id) DO UPDATE SET rotation_id = EXCLUDED.rotation_id, rod_label = EXCLUDED.rod_label,
  module = EXCLUDED.module, start_date = EXCLUDED.start_date;
`);

// ids determinísticos: '<term>:<posição>' — reimportar a grade atualiza no lugar
out.push(`INSERT INTO schedule_items (id, term_id, position, date, start_time, end_time, type, title) VALUES
${seed.events.map((e, i) => `  (${q(`${TERM}:${String(i + 1).padStart(4, '0')}`)}, ${q(TERM)}, ${i + 1}, ${q(e.date)}, ${q(e.start)}, ${q(e.end)}, ${q(e.type)}, ${q(e.title)})`).join(',\n')}
ON CONFLICT (id) DO UPDATE SET date = EXCLUDED.date, start_time = EXCLUDED.start_time, end_time = EXCLUDED.end_time,
  type = EXCLUDED.type, title = EXCLUDED.title;
`);

writeFileSync(join(root, 'db/seed/0001_term_2026_2.sql'), out.join('\n'));
console.log(`✓ db/seed/0001_term_2026_2.sql — ${weeks.length} semanas, ${seed.events.length} itens`);
