#!/usr/bin/env node
// Teste de ida e volta: dump do aparelho → api.ns_put → api.ns_get → compara com o original.
// Prova que o banco guarda TUDO que o app persiste, no shape que o app lê.
// Uso: DATABASE_URL=... node tests/roundtrip.mjs tests/fixtures/device-full.json [--write-restored out.json]
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const file = process.argv[2];
const wIdx = process.argv.indexOf('--write-restored');
const DB = process.env.DATABASE_URL;
if (!file || !DB) { console.error('uso: DATABASE_URL=... node tests/roundtrip.mjs <dump.json>'); process.exit(2); }

const raw = JSON.parse(readFileSync(file, 'utf8'));
const env = (ns) => { const v = raw['estudy:' + ns]; return typeof v === 'string' ? JSON.parse(v) : v; };
const userId = env('identity').data.userId;
const psql = (sql) => {
  const r = spawnSync('psql', [DB, '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'], { input: sql, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(r.stderr);
  return r.stdout.trim();
};
const get = (ns) => JSON.parse(psql(`SET estudy.user_id = '${userId}';\nSELECT api.ns_get('${userId}', '${ns}');`));

const diffs = [];
// comparação canônica: a ordem das chaves de um objeto não importa (JSONB normaliza)
const canon = (v) => Array.isArray(v) ? v.map(canon)
  : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])])) : v;
const eq = (path, a, b) => { if (JSON.stringify(canon(a)) !== JSON.stringify(canon(b))) diffs.push(`${path}: esperado ${JSON.stringify(a)} · banco ${JSON.stringify(b)}`); };
const byId = (arr) => Object.fromEntries((arr || []).map((x) => [x.id, x]));
const pick = (o, keys) => Object.fromEntries(keys.map((k) => [k, o?.[k] ?? null]));
const stOf = (e) => e.status || (e.done ? 'presente' : 'pendente');   // L706

const wsIds = new Set((env('workspace')?.data.workspaces || []).map((w) => w.id));
const restored = {};
const counts = {};

// identity
{
  const a = env('identity').data, b = get('identity');
  restored['estudy:identity'] = b;
  eq('identity.v', env('identity').v, b.v);
  for (const k of Object.keys(a)) eq(`identity.${k}`, a[k], b.data[k]);
  counts.identity = 1;
}
// users
{
  const a = env('users').data.byId, b = get('users');
  restored['estudy:users'] = b;
  for (const id of Object.keys(a))
    eq(`users.${id}`, pick(a[id], ['id', 'displayName', 'avatarUrl', 'course', 'institution', 'createdAt', 'updatedAt']),
       pick(b.data.byId[id], ['id', 'displayName', 'avatarUrl', 'course', 'institution', 'createdAt', 'updatedAt']));
  counts.users = Object.keys(b.data.byId).length;
}
// planner
{
  const a = env('planner').data, b = get('planner');
  restored['estudy:planner'] = b;
  const A = byId(a.events), B = byId(b.data.events);
  eq('planner.events.count', Object.keys(A).length, Object.keys(B).length);
  for (const id of Object.keys(A)) {
    const x = A[id], y = B[id];
    if (!y) { diffs.push(`planner.events.${id}: ausente no banco`); continue; }
    eq(`planner.events.${id}`, { ...pick(x, ['date', 'start', 'end', 'type', 'title', 'note', 'custom']), status: stOf(x), done: stOf(x) === 'presente' },
                               { ...pick(y, ['date', 'start', 'end', 'type', 'title', 'note', 'custom']), status: y.status, done: y.done });
  }
  eq('planner.notes', a.notes || {}, b.data.notes);
  eq('planner.goals', a.goals, b.data.goals);
  if (a.weeks) eq('planner.weeks', a.weeks, b.data.weeks);
  if (a.baseline) eq('planner.baseline', a.baseline, b.data.baseline);
  counts.planner = Object.keys(B).length;
}
// workspace
if (env('workspace')) {
  const a = byId(env('workspace').data.workspaces), bEnv = get('workspace'), b = byId(bEnv.data.workspaces);
  restored['estudy:workspace'] = bEnv;
  eq('workspace.count', Object.keys(a).length, Object.keys(b).length);
  const kids = { events: ['date', 'start', 'end', 'title', 'note', 'createdBy', 'createdAt'],
                 tasks: ['title', 'desc', 'assignee', 'due', 'status', 'createdBy', 'createdAt'],
                 files: ['name', 'size', 'ext', 'addedBy', 'addedAt', 'aiStatus', 'stored'],
                 comments: ['author', 'text', 'at', 'parentId'] };
  for (const id of Object.keys(a)) {
    const x = a[id], y = b[id];
    if (!y) { diffs.push(`workspace.${id}: ausente`); continue; }
    eq(`workspace.${id}`, pick(x, ['name', 'description', 'color', 'icon', 'ownerId', 'inviteCode', 'createdAt', 'updatedAt']),
                          pick(y, ['name', 'description', 'color', 'icon', 'ownerId', 'inviteCode', 'createdAt', 'updatedAt']));
    for (const [k, keys] of Object.entries(kids)) {
      const X = byId(x[k]), Y = byId(y[k]);
      eq(`workspace.${id}.${k}.count`, Object.keys(X).length, Object.keys(Y).length);
      for (const cid of Object.keys(X)) {
        eq(`workspace.${id}.${k}.${cid}`, pick(X[cid], keys), pick(Y[cid], keys));
        if (k === 'tasks') {
          const C = byId(X[cid].comments), D = byId(Y[cid]?.comments);
          for (const tc of Object.keys(C)) eq(`workspace.${id}.tasks.${cid}.comments.${tc}`,
            pick(C[tc], ['author', 'text', 'at']), pick(D[tc], ['author', 'text', 'at']));
        }
      }
    }
  }
  counts.workspace = Object.keys(b).length;
}
// memberships / invites (órfãos de workspace excluído ficam fora — esperado)
for (const [ns, keys] of [['memberships', ['workspaceId', 'userId', 'role', 'responsibility', 'joinedAt', 'status', 'permissions']],
                          ['invites', ['workspaceId', 'code', 'createdBy', 'createdAt', 'expiresAt', 'maxUses', 'currentUses', 'status']]]) {
  if (!env(ns)) continue;
  const all = env(ns).data.items;
  const a = byId(all.filter((m) => wsIds.has(m.workspaceId)));
  const bEnv = get(ns), b = byId(bEnv.data.items);
  restored['estudy:' + ns] = bEnv;
  for (const id of Object.keys(a)) eq(`${ns}.${id}`, pick(a[id], keys), pick(b[id], keys));
  counts[ns] = `${Object.keys(b).length} (órfãos descartados: ${all.length - Object.keys(a).length})`;
}

if (wIdx > 0) writeFileSync(process.argv[wIdx + 1], JSON.stringify(restored, null, 2));
console.log(`roundtrip ${file}:`, JSON.stringify(counts));
if (diffs.length) { console.log(`✗ ${diffs.length} diferença(s):`); diffs.slice(0, 40).forEach((d) => console.log('  ' + d)); process.exit(1); }
console.log('✓ idêntico ao original (0 diferenças)');
