// Cole no console do navegador com o planner_aluno026.html aberto.
// Baixa estudy-localstorage.json com todas as chaves do Estudy (estudy:* e legadas),
// pronto para: node scripts/import-localstorage.mjs estudy-localstorage.json --apply
(() => {
  const keep = (k) => k.startsWith('estudy:') || ['planner_profile_v1', 'planner_aluno026_v1', 'estudy_workspaces_v1'].includes(k);
  const dump = {};
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    if (!keep(k)) continue;
    const v = localStorage.getItem(k);
    try { dump[k] = JSON.parse(v); } catch { dump[k] = v; }
  }
  const blob = new Blob([JSON.stringify(dump, null, 2)], { type: 'application/json' });
  const a = Object.assign(document.createElement('a'), { href: URL.createObjectURL(blob), download: 'estudy-localstorage.json' });
  document.body.appendChild(a); a.click(); a.remove();
  console.log('Estudy: exportadas', Object.keys(dump).length, 'chaves', Object.keys(dump));
})();
