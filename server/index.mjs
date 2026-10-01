// Servidor de REFERÊNCIA do Estudy — mostra o contrato HTTP ↔ banco em ~120 linhas.
// Não é o backend de produção: a autenticação aqui é um cabeçalho de desenvolvimento.
//
//   GET  /ns/:name              → api.ns_get(user, name)
//   PUT  /ns/:name   {v,at,data} → api.ns_put(user, name, envelope)
//   POST /invites/redeem {code} → api.redeem_invite(user, code)
//   GET  /stats/attendance[?module=SMI|SA]      → api.attendance_stats
//   GET  /stats/subjects[?module=]              → api.attendance_by_subject
//   GET  /app?user=<id>         → planner_aluno026.html com o adaptador de rede injetado (dev)
//
// Uso: DATABASE_URL=... PLANNER_HTML=../planner_aluno026.html node server/index.mjs
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import pg from 'pg';

const here = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8787);
const DEFAULT_TERM = process.env.DEFAULT_TERM || '2026.2';
const PLANNER_HTML = resolve(process.env.PLANNER_HTML || join(here, '..', 'planner_aluno026.html'));
const ADAPTER = readFileSync(join(here, '..', 'adapter', 'estudy-network-adapter.js'), 'utf8')
  .replace(/<\/script/gi, '<\\/script');          // seguro para embutir inline
const NAMESPACES = new Set(['identity', 'users', 'planner', 'workspace', 'memberships', 'invites']);
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });

// ⚠ DEV: identidade vem do cabeçalho. Em produção, valide a sessão/JWT aqui.
function authUser(req, url) {
  const u = req.headers['x-estudy-user'] || url.searchParams.get('user');
  return u && /^[A-Za-z0-9_.:-]{1,80}$/.test(u) ? u : null;
}

// cada requisição roda como estudy_app (RLS) com o usuário na sessão
async function asUser(userId, fn) {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await c.query("SELECT set_config('estudy.user_id', $1, true)", [userId]);
    await c.query('SET LOCAL ROLE estudy_app');
    const out = await fn(c);
    await c.query('COMMIT');
    return out;
  } catch (e) { await c.query('ROLLBACK').catch(() => {}); throw e; }
  finally { c.release(); }
}

// primeiro acesso: cria o usuário; no planner vazio, matricula no ciclo padrão
async function bootstrap(c, user, ns) {
  await c.query('RESET ROLE');
  await c.query("INSERT INTO users (id) VALUES ($1) ON CONFLICT DO NOTHING", [user]);
  if (ns === 'planner') {
    const { rows } = await c.query(
      `SELECT NOT EXISTS (SELECT 1 FROM planner_events WHERE user_id = $1)
          AND NOT EXISTS (SELECT 1 FROM enrollments WHERE user_id = $1)
          AND EXISTS (SELECT 1 FROM terms WHERE id = $2) AS fresh`, [user, DEFAULT_TERM]);
    if (rows[0].fresh) await c.query('SELECT api.enroll_user($1, $2)', [user, DEFAULT_TERM]);
  }
  await c.query('SET LOCAL ROLE estudy_app');
}

const send = (res, code, body, type = 'application/json') => {
  res.writeHead(code, { 'Content-Type': type, 'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Estudy-User',
    'Access-Control-Allow-Methods': 'GET, PUT, POST, OPTIONS' });
  res.end(type === 'application/json' ? JSON.stringify(body) : body);
};
const stripNul = (v) => typeof v === 'string' ? v.replace(/\u0000/g, '')
  : Array.isArray(v) ? v.map(stripNul)
  : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [stripNul(k), stripNul(x)])) : v;
const readBody = (req) => new Promise((ok, ko) => {
  let b = ''; req.on('data', (d) => { b += d; if (b.length > 8e6) ko(new Error('payload grande demais')); });
  req.on('end', () => ok(b)); req.on('error', ko);
});

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  if (req.method === 'OPTIONS') return send(res, 204, '');
  if (url.pathname === '/health') return send(res, 200, { ok: true });

  if (url.pathname === '/app') {                       // dev: serve o planner já apontando para esta API
    if (!existsSync(PLANNER_HTML)) return send(res, 404, { error: 'defina PLANNER_HTML' });
    const user = authUser(req, url);
    if (!user) return send(res, 400, { error: 'use /app?user=<id>' }, 'application/json');
    const inject = `<script>window.ESTUDY_API=${JSON.stringify({ baseUrl: '', user })};</script>\n<script>${ADAPTER}</script>\n`;
    const html = readFileSync(PLANNER_HTML, 'utf8').replace('<script>', () => inject + '<script>');
    return send(res, 200, html, 'text/html; charset=utf-8');
  }

  const user = authUser(req, url);
  if (!user) return send(res, 401, { error: 'não autenticado' });
  try {
    const m = url.pathname.match(/^\/ns\/([a-z]+)$/);
    if (m && NAMESPACES.has(m[1])) {
      const ns = m[1];
      if (req.method === 'GET') {
        const env = await asUser(user, async (c) => {
          await bootstrap(c, user, ns);
          const { rows } = await c.query('SELECT api.ns_get($1, $2) AS env', [user, ns]);
          return rows[0].env;   // workspace vazio volta como {workspaces:[]} — impede os mocks do wsSeed
        });
        return env ? send(res, 200, env) : send(res, 404, { error: 'vazio' });
      }
      if (req.method === 'PUT') {
        // NUL (\u0000) não existe em TEXT/JSONB do Postgres: removido das strings antes de enviar
        const envelope = stripNul(JSON.parse(await readBody(req)));
        const rep = await asUser(user, async (c) => {
          await bootstrap(c, user, null);
          const { rows } = await c.query('SELECT api.ns_put($1, $2, $3::jsonb) AS rep', [user, ns, envelope]);
          return rows[0].rep;
        });
        return send(res, 200, rep);
      }
    }
    if (url.pathname === '/invites/redeem' && req.method === 'POST') {
      const { code } = JSON.parse(await readBody(req) || '{}');
      const r = await asUser(user, async (c) => { await bootstrap(c, user, null);
        return c.query('SELECT api.redeem_invite($1, $2) AS r', [user, code]); });
      return send(res, 200, r.rows[0].r);
    }
    if (url.pathname === '/stats/attendance' && req.method === 'GET') {
      const r = await asUser(user, (c) => c.query('SELECT * FROM api.attendance_stats($1, $2)', [user, url.searchParams.get('module')]));
      return send(res, 200, r.rows[0]);
    }
    if (url.pathname === '/stats/subjects' && req.method === 'GET') {
      const r = await asUser(user, (c) => c.query('SELECT * FROM api.attendance_by_subject($1, $2)', [user, url.searchParams.get('module')]));
      return send(res, 200, r.rows);
    }
    return send(res, 404, { error: 'rota desconhecida' });
  } catch (e) {
    const code = e.code === '42501' ? 403 : e.code === '22023' ? 422 : 500;
    return send(res, code, { error: e.message, code: e.code });
  }
});

server.listen(PORT, () => console.log(`estudy api em http://localhost:${PORT}  ·  app: /app?user=<id>`));
export default server;
