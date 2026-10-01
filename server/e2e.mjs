// Teste ponta a ponta: o planner_aluno026.html REAL rodando no Chromium, lendo e gravando no
// PostgreSQL pelo adaptador de rede (checklist §10: "testar com o próprio HTML apontando para o backend").
// Pré-requisito: banco com migrations + seed + tests/fixtures/device-full.json importado.
// Uso: DATABASE_URL=... E2E_USER=<userId do fixture> node server/e2e.mjs
import { chromium } from 'playwright';
import pg from 'pg';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
process.env.PORT ||= '8799';
process.env.PLANNER_HTML ||= join(here, '..', 'reference', 'planner_aluno026.html');
const { default: server } = await import('./index.mjs');
const BASE = `http://localhost:${process.env.PORT}`;
const USER = process.env.E2E_USER;
const NEW_USER = 'e2e-novo-' + Date.now().toString(36);
const db = new pg.Pool({ connectionString: process.env.DATABASE_URL });
const q = async (sql, p = []) => (await db.query(sql, p)).rows;

let failures = 0;
const ok = (cond, msg) => { console.log(`${cond ? '✓' : '✗'} ${msg}`); if (!cond) failures++; };

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 } });
await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));

const boot = async (user) => {
  await page.goto(`${BASE}/app?user=${encodeURIComponent(user)}`);
  await page.waitForFunction(() => typeof state !== 'undefined' && state?.events
    && typeof wsStore !== 'undefined' && wsStore?.workspaces, null, { timeout: 20000 });
  await page.waitForTimeout(900);          // deixa o debounce (400ms) do Store gravar o boot
};
const synced = (ns) => page.evaluate((ns) => new Promise((ok) => {
  const h = (e) => { if (e.detail?.namespace === ns) { removeEventListener('estudy:synced', h); ok(e.detail); } };
  addEventListener('estudy:synced', h);
}), ns);

// 1) aluno importado: tudo vem do banco
await boot(USER);
const s1 = await page.evaluate(() => ({
  ls: localStorage.length, events: state.events.length, ws: wsStore.workspaces.length,
  uid: Identity.current().userId,
  st: state.events.reduce((a, e) => (a[stOf(e)] = (a[stOf(e)] || 0) + 1, a), {}),
  notes: Object.keys(state.notes).length,
  brand: document.querySelector('#appRoot') ? !document.getElementById('appRoot').classList.contains('hidden') : false
}));
const dbSt = Object.fromEntries((await q(`SELECT status, count(*)::int n FROM planner_events
  WHERE user_id = $1 AND deleted_at IS NULL GROUP BY status`, [USER])).map((r) => [r.status, r.n]));
ok(s1.ls === 0, 'nada no localStorage: o app está lendo do banco');
ok(s1.uid === USER, `identidade do banco (${USER.slice(0, 8)}…)`);
ok(s1.events === 180, `planner com ${s1.events} eventos (esperado 180)`);
ok(JSON.stringify(s1.st) === JSON.stringify(Object.fromEntries(Object.keys(s1.st).sort().map((k) => [k, dbSt[k]])))
   || Object.keys(s1.st).every((k) => s1.st[k] === dbSt[k]), `presenças iguais às do banco ${JSON.stringify(s1.st)}`);
ok(s1.ws === 3, `${s1.ws} workspaces carregados`);
ok(s1.notes === 2, 'anotações semanais carregadas');
ok(s1.brand, 'app renderizado (fora do onboarding)');
await page.screenshot({ path: process.env.E2E_SHOTS ? join(process.env.E2E_SHOTS, 'e2e-1-planner.png') : '/dev/null' }).catch(() => {});

// 2) app → banco: marcar falta num evento pendente
const target = await page.evaluate(() => {
  const e = state.events.filter(isAcad).find((x) => stOf(x) === 'pendente');
  setStatus(e, 'falta'); save(); return e.id;
});
await synced('planner');
const [row] = await q('SELECT status, attendance_marked_at FROM planner_events WHERE id = $1', [target]);
ok(row?.status === 'falta' && row.attendance_marked_at, `falta gravada no banco pelo app (evento ${target})`);
ok((await q(`SELECT 1 FROM domain_events WHERE name = 'planner.attendance.recorded' AND aggregate_id = $1`, [target])).length === 1,
   'outbox registrou planner.attendance.recorded');

// 3) comentário no mural pelo app
const cid = await page.evaluate(() => {
  const w = wsStore.workspaces[0];
  const a = { id: uid(), author: viewer.id, text: 'teste e2e pelo banco', at: new Date().toISOString(), parentId: null };
  w.comments.push(a); wsTouch(w); wsSave(); return a.id;
});
await synced('workspace');
ok((await q('SELECT 1 FROM activities WHERE id = $1 AND body = $2', [cid, 'teste e2e pelo banco'])).length === 1,
   'comentário do mural gravado em activities');

// 4) reload: o que o app gravou volta do banco
await boot(USER);
const back = await page.evaluate((id) => stOf(state.events.find((e) => e.id === id)), target);
ok(back === 'falta', 'após recarregar, a falta continua (veio do banco)');

// 5) aluno novo: matrícula automática na grade oficial, sem mocks
await boot(NEW_USER);
const s2 = await page.evaluate(() => ({ events: state.events.length, ws: wsStore.workspaces.length }));
ok(s2.events === 160, `aluno novo recebe a grade 2026.2 (${s2.events} eventos)`);
ok(s2.ws === 0, 'aluno novo sem workspaces de exemplo (mocks bloqueados)');
const [nv] = await q(`SELECT count(*)::int n, count(source_item_id)::int linked FROM planner_events WHERE user_id = $1`, [NEW_USER]);
ok(nv.n === 160 && nv.linked === 160, 'eventos do aluno novo ligados à grade oficial (schedule_items)');
ok((await q('SELECT 1 FROM workspaces WHERE owner_id = $1', [NEW_USER])).length === 0, 'nenhum workspace mock criado no banco');

ok(errors.length === 0, `zero erros JS na página${errors.length ? ': ' + errors.join(' | ') : ''}`);

await browser.close(); await db.end(); server.close();
console.log(failures ? `✗ ${failures} falha(s)` : '✓ e2e verde');
process.exit(failures ? 1 : 0);
