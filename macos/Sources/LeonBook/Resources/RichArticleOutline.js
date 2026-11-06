function createArticleOutline({ root, documentID, send, frameTask }) {
  const selector = 'h1,h2,h3,h4', fallbackIDs = new WeakMap();
  let enabled = false, headingsDirty = true, positionsDirty = true, records = [], nextID = 0;
  let lastOutline = '', lastActive = '';
  function rebuild() {
    if (!headingsDirty) return;
    records = [...root.querySelectorAll(selector)].map(node => {
      if (!fallbackIDs.has(node)) fallbackIDs.set(node, 'outline-' + ++nextID);
      return { node, id: node.dataset.blockId || fallbackIDs.get(node), level: Number(node.tagName.slice(1)), title: node.textContent.trim() };
    });
    headingsDirty = false; positionsDirty = true;
  }
  function update() {
    if (!enabled) return;
    rebuild();
    if (positionsDirty) {
      for (const record of records) record.top = record.node.getBoundingClientRect().top + scrollY;
      positionsDirty = false;
    }
    const items = records.map(({ id, level, title }) => ({ id, level, title }));
    const outline = JSON.stringify([documentID(), items]);
    if (outline !== lastOutline) { lastOutline = outline; send({ type: 'editorOutline', items }); }
    const marker = scrollY + document.getElementById('toolbar').getBoundingClientRect().bottom + 12;
    let active;
    // WebKit rounds scroll offsets to pixels while heading positions can be fractional.
    for (const record of records) if (record.top <= marker + 2 && (!active || record.top >= active.top)) active = record;
    active ||= records[0];
    if (scrollY > 0 && scrollY + innerHeight >= document.documentElement.scrollHeight - 2) active = records.at(-1);
    const activeID = active?.id || '', identity = JSON.stringify([documentID(), activeID]);
    if (identity !== lastActive) { lastActive = identity; send({ type: 'editorOutlineActive', id: activeID }); }
  }
  const schedule = frameTask(update);
  function refresh() { if (enabled) { positionsDirty = true; schedule(); } }
  // Body typing only invalidates positions; scan headings again only when a
  // heading's text or structure changes. Scrolling uses cached document offsets.
  const observer = new MutationObserver(changes => {
    if (!enabled) return;
    for (const change of changes) {
      const target = change.target.nodeType === Node.ELEMENT_NODE ? change.target : change.target.parentElement;
      if (target?.closest(selector) || [...change.addedNodes, ...change.removedNodes].some(node =>
        node.nodeType === Node.ELEMENT_NODE && (node.matches(selector) || node.querySelector(selector)))) headingsDirty = true;
    }
    refresh();
  });
  function setEnabled(value) {
    if (enabled === !!value) return;
    enabled = !!value; observer.disconnect(); schedule.cancel();
    records = []; headingsDirty = positionsDirty = true; lastOutline = lastActive = '';
    if (enabled) { observer.observe(root, { childList: true, characterData: true, subtree: true, attributes: true, attributeFilter: ['data-block-id'] }); schedule(); }
  }
  function navigate(id, expectedDocumentID) {
    if (!enabled || expectedDocumentID !== documentID()) return false;
    // MutationObserver delivery can lag a native click by one microtask.
    if (observer.takeRecords().length) headingsDirty = true;
    rebuild();
    const heading = records.find(record => record.id === id)?.node;
    if (!heading || !root.contains(heading)) return false;
    const inset = document.getElementById('toolbar').getBoundingClientRect().bottom + 12;
    window.scrollTo({ top: Math.max(0, heading.getBoundingClientRect().top + scrollY - inset), behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
    return true;
  }
  window.addEventListener('scroll', schedule, { passive: true });
  return { setEnabled, refresh, navigate };
}
