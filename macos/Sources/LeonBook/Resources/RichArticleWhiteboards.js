function createArticleWhiteboards({ root, canEdit, documentID, send, uuid, checkpoint, notify, focusBlock, closeMenu, frameTask }) {
  const pending = new Map();
  let selected = null;
  const selector = 'figure[data-type="whiteboard"][data-whiteboard-source]';
  const validSource = value => /^\/media\/whiteboards\/[a-f0-9]{64}\.excalidraw$/.test(value || '');
  const tools = document.createElement('div'); tools.id = 'whiteboard-tools'; tools.hidden = true;
  tools.setAttribute('role', 'toolbar'); tools.setAttribute('aria-label', '画板操作');
  tools.innerHTML = '<button data-board-action="edit">编辑画板</button><button data-board-action="delete">删除</button>';
  document.body.append(tools);
  function position() {
    if (!canEdit() || !selected || !root.contains(selected)) { tools.hidden = true; return; }
    const rect = selected.getBoundingClientRect();
    tools.hidden = rect.bottom < 0 || rect.top > innerHeight;
    tools.style.left = Math.max(8, Math.min(innerWidth - 170, rect.right - 170)) + 'px';
    tools.style.top = Math.max(8, Math.min(innerHeight - 42, rect.top + 8)) + 'px';
  }
  const schedulePosition = frameTask(position);
  function request(block, isNew, replace = false) {
    if (!canEdit() || !block || !root.contains(block) || pending.size) return false;
    const source = isNew ? '' : block.dataset.whiteboardSource;
    if (!isNew && !validSource(source)) return false;
    const requestID = uuid();
    pending.set(requestID, { block, isNew, replace, source, documentID: documentID(), original: block.outerHTML });
    closeMenu(); tools.hidden = true;
    send({ type: 'editWhiteboard', requestID, source });
    return true;
  }
  function complete(requestID, source, preview) {
    const request = pending.get(requestID);
    if (!request || !canEdit() || request.documentID !== documentID() || !root.contains(request.block)
        || request.block.outerHTML !== request.original || !validSource(source)
        || preview !== source.replace(/\.excalidraw$/, '.png')) return false;
    pending.delete(requestID);
    checkpoint();
    const figure = request.isNew ? document.createElement('figure') : request.block;
    if (request.isNew) {
      figure.dataset.blockId = uuid(); figure.dataset.type = 'whiteboard';
      figure.append(document.createElement('img'));
      const caption = document.createElement('figcaption'); caption.textContent = 'Excalidraw 画板'; figure.append(caption);
      if (request.replace) request.block.replaceWith(figure); else request.block.after(figure);
    }
    figure.dataset.whiteboardSource = source;
    const image = figure.querySelector('img');
    delete image.dataset.originalSrc; image.src = preview; image.alt = 'Excalidraw 画板';
    if (!figure.nextElementSibling) { const paragraph = document.createElement('p'); paragraph.innerHTML = '<br>'; figure.after(paragraph); }
    notify(); selected = figure; position();
    focusBlock(figure.nextElementSibling);
    return true;
  }
  function remove() {
    if (!canEdit() || !selected || !root.contains(selected)) return;
    checkpoint(); const next = selected.nextElementSibling || selected.previousElementSibling;
    selected.remove(); selected = null; tools.hidden = true;
    notify(); focusBlock(next && root.contains(next) ? next : root.firstElementChild);
  }
  root.addEventListener('click', event => {
    selected = event.target.closest(selector); position();
  });
  root.addEventListener('dblclick', event => {
    const board = event.target.closest(selector);
    if (board && canEdit()) { event.preventDefault(); event.stopImmediatePropagation(); request(board, false); }
  }, true);
  tools.addEventListener('mousedown', event => event.preventDefault());
  tools.addEventListener('click', event => {
    const action = event.target.closest('[data-board-action]')?.dataset.boardAction;
    if (action === 'edit') request(selected, false);
    if (action === 'delete') remove();
  });
  root.addEventListener('keydown', event => {
    const board = event.target.closest(selector);
    if (!board || !canEdit()) return;
    if (event.key === 'Enter') { event.preventDefault(); request(board, false); }
    if (event.key === 'Backspace' || event.key === 'Delete') { event.preventDefault(); selected = board; remove(); }
  });
  window.addEventListener('scroll', schedulePosition, { passive: true });
  window.addEventListener('resize', schedulePosition);
  return {
    create: (block, replace) => request(block, true, replace), complete,
    cancel: requestID => pending.delete(requestID),
    reset() { pending.clear(); selected = null; tools.hidden = true; }
  };
}
