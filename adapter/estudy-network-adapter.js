/* ============================================================
   Estudy — adaptador de rede para window.storage  (§8.3)
   ------------------------------------------------------------
   Carregue ANTES do script principal do planner_aluno026.html:
     1) defina window.ESTUDY_API = { baseUrl: 'https://api.seu-dominio', token: '<jwt>' }
     2) inclua este arquivo (script src="estudy-network-adapter.js")

   O app só cria o adaptador localStorage quando window.storage não
   existe (L384). Definindo-o aqui, todo o Store passa a ler/gravar no
   banco pelo mesmo contrato: get(k) → {value} | null · set(k, json).
   Nenhum componente do app muda.
   ============================================================ */
(function () {
  var cfg = window.ESTUDY_API || {};
  var base = String(cfg.baseUrl || '').replace(/\/$/, '');
  var PREFIX = 'estudy:';
  var KEEPALIVE_MAX = 60 * 1024;   // limite do fetch keepalive (flushSync no beforeunload)

  function headers(extra) {
    var h = { 'Content-Type': 'application/json' };
    if (cfg.token) h.Authorization = 'Bearer ' + cfg.token;
    if (cfg.user) h['X-Estudy-User'] = cfg.user;          // só em desenvolvimento
    for (var k in extra || {}) h[k] = extra[k];
    return h;
  }
  function nsOf(key) { return key.indexOf(PREFIX) === 0 ? key.slice(PREFIX.length) : null; }
  // Se o GET de um namespace falhou, o Store do app engole o erro e parte do seed (L426).
  // Gravar esse seed por cima do banco apagaria os dados reais: bloqueamos o PUT até recarregar.
  var loadFailed = {};

  window.storage = {
    async get(key) {
      var ns = nsOf(key);
      if (!ns) return null;                                  // chaves legadas: o banco não as tem
      var r;
      try { r = await fetch(base + '/ns/' + encodeURIComponent(ns), { headers: headers(), credentials: 'include' }); }
      catch (e) { loadFailed[ns] = true; throw e; }
      if (r.status === 404 || r.status === 204) return null;
      if (!r.ok) { loadFailed[ns] = true; throw new Error('estudy GET ' + ns + ' → ' + r.status); }
      loadFailed[ns] = false;
      var env = await r.json();
      return env && env.data != null ? { value: JSON.stringify(env) } : null;
    },
    async set(key, value) {
      var ns = nsOf(key);
      if (!ns) return;
      if (loadFailed[ns]) {
        console.error('[estudy] ' + ns + ': carga falhou nesta sessão — gravação bloqueada para não sobrescrever o servidor. Recarregue a página.');
        window.dispatchEvent(new CustomEvent('estudy:sync-blocked', { detail: { namespace: ns } }));
        return;
      }
      var body = String(value);
      var r = await fetch(base + '/ns/' + encodeURIComponent(ns), {
        method: 'PUT', headers: headers(), body: body, credentials: 'include',
        keepalive: body.length < KEEPALIVE_MAX
      });
      if (!r.ok) throw new Error('estudy PUT ' + ns + ' → ' + r.status);
      var rep = await r.json().catch(function () { return null; });
      if (rep && rep.applied === false) console.warn('[estudy] ' + ns + ' não aplicado:', rep.reason);
      if (rep && ((rep.skipped || []).length || (rep.readOnly || []).length))
        console.info('[estudy] ' + ns + ':', { skipped: rep.skipped, readOnly: rep.readOnly });
      window.dispatchEvent(new CustomEvent('estudy:synced', { detail: rep }));
    }
  };
})();
