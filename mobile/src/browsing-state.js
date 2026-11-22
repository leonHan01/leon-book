const tabs = ['articles', 'moments', 'todos'];
const savedPositionLimit = 60;

function storageKey(workspaceID) {
  return `leonbook-browsing:${workspaceID ?? 'local'}`;
}

export function loadBrowsingState(workspaceID) {
  let saved;
  try { saved = JSON.parse(localStorage.getItem(storageKey(workspaceID))); }
  catch { /* Browsing state is optional. */ }
  const queries = Object.fromEntries(tabs.map(tab => [tab,
    typeof saved?.queries?.[tab] === 'string' ? saved.queries[tab] : '',
  ]));
  const positions = Array.isArray(saved?.positions) ? saved.positions : [];
  return {
    tab: tabs.includes(saved?.tab) ? saved.tab : 'articles',
    folder: typeof saved?.folder === 'string' ? saved.folder : '',
    scope: saved?.scope === 'folder' ? 'folder' : 'all',
    queries,
    positions: new Map(positions.filter(entry => Array.isArray(entry) && typeof entry[0] === 'string' &&
      Number.isFinite(entry[1]?.top)).slice(-savedPositionLimit)),
  };
}

export function saveBrowsingState(workspaceID, browsing) {
  try {
    localStorage.setItem(storageKey(workspaceID), JSON.stringify({ ...browsing, positions: [...browsing.positions] }));
  } catch { /* Keep the current view available without persistent preferences. */ }
}

export function setBrowsingPosition(browsing, key, position) {
  browsing.positions.delete(key);
  browsing.positions.set(key, position);
  if (browsing.positions.size > savedPositionLimit) browsing.positions.delete(browsing.positions.keys().next().value);
}

export function browsingViewKey({ tab, folder, scope, queries }) {
  const query = queries[tab].trim();
  return JSON.stringify(tab === 'articles'
    ? [tab, folder, query, query && folder ? scope : '']
    : [tab, query]);
}
