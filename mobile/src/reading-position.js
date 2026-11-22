export function rememberReadingPosition(dialog, body, workspaceID, article) {
  const key = `leonbook-reading:${JSON.stringify([workspaceID ?? null, article.slug])}`;
  const blocks = [...body.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,pre,figure,table,blockquote,.article-image')];
  if (!blocks.length) blocks.push(body);
  const toolbar = dialog.querySelector('.reader-toolbar');
  let saved;
  let offset;
  let timer;
  try { saved = JSON.parse(localStorage.getItem(key)); }
  catch { /* Reading still works without local preferences. */ }

  function store(position) {
    saved = position;
    try { localStorage.setItem(key, JSON.stringify(position)); }
    catch { /* The reading position is optional. */ }
  }

  function visiblePosition() {
    const line = toolbar.getBoundingClientRect().bottom;
    const index = blocks.findIndex(block => block.getBoundingClientRect().bottom > line);
    const block = blocks[index];
    const rect = block?.getBoundingClientRect();
    const anchor = block && {
      index,
      text: block.textContent.trim().slice(0, 80),
      delta: line - rect.top,
      height: rect.height,
    };
    return { top: dialog.scrollTop, anchor };
  }

  function restore(position, resized = false) {
    if (!(position?.top > 0)) {
      dialog.scrollTop = 0;
      return;
    }
    const { anchor } = position;
    const block = blocks[anchor?.index];
    const sameBlock = anchor?.text && block?.textContent.trim().slice(0, 80) === anchor.text;
    const rect = block?.getBoundingClientRect();
    const delta = resized && anchor?.height > 0 && anchor.delta > 0
      ? anchor.delta * rect?.height / anchor.height : anchor?.delta;
    dialog.scrollTop = sameBlock
      ? dialog.scrollTop + rect.top + delta - toolbar.getBoundingClientRect().bottom
      : position.top;
  }

  function saveVisibleBlock() {
    if (!dialog.open) return;
    const position = visiblePosition();
    offset = position.top;
    store(position);
  }

  requestAnimationFrame(() => {
    if (dialog.open && saved) restore(saved);
  });
  dialog.addEventListener('scroll', () => {
    if (!dialog.open) return;
    offset = dialog.scrollTop;
    clearTimeout(timer);
    timer = setTimeout(saveVisibleBlock, 200);
  }, { passive: true });
  dialog.addEventListener('close', () => {
    clearTimeout(timer);
    if (offset !== undefined && offset !== saved?.top) store({ top: offset });
  }, { once: true });
  return {
    save: saveVisibleBlock,
    reflow(change) {
      const position = visiblePosition();
      change();
      restore(position, true);
      saveVisibleBlock();
    },
  };
}
