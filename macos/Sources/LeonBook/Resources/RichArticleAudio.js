function createArticleAudio({ root, canEdit, documentID, send, uuid, checkpoint, notify, focusBlock, closeMenu }) {
  const pending = new Map();
  const button = document.querySelector('#toolbar [data-command=audio]');
  const selector = 'figure[data-type=audio]';
  function updateButton() {
    button.disabled = pending.size > 0;
    button.textContent = pending.size ? '正在导入音频…' : '插入音频';
  }
  function remember(block, replace = false, before = false) {
    if (!canEdit() || !block || !root.contains(block) || pending.size) return null;
    const requestID = uuid();
    pending.set(requestID, { block, replace, before, documentID: documentID(), original: block.outerHTML });
    closeMenu(); updateButton();
    return requestID;
  }
  function create(block, replace = false) {
    const requestID = remember(block, replace); if (!requestID) return false;
    send({ type: 'chooseAudio', requestID });
    return true;
  }
  function cancel(requestID) {
    const request = pending.get(requestID);
    pending.delete(requestID); updateButton();
    if (request && canEdit() && request.documentID === documentID() && root.contains(request.block)) focusBlock(request.block, true);
  }
  function complete(requestID, source, title) {
    return completeMany(requestID, [{ source, title }]);
  }
  function completeMany(requestID, items) {
    const request = pending.get(requestID);
    if (!request || !canEdit() || request.documentID !== documentID() || !root.contains(request.block)
        || request.block.outerHTML !== request.original || !Array.isArray(items) || !items.length
        || !items.every(item => /^\/media\/[^/]+\/[^/]+\.mp3$/i.test(item.source))) return false;
    pending.delete(requestID); updateButton(); checkpoint();
    const fragment = document.createDocumentFragment();
    for (const { source, title } of items) {
      const figure = document.createElement('figure');
      figure.dataset.type = 'audio'; figure.dataset.blockId = uuid();
      const player = document.createElement('audio');
      player.setAttribute('src', source); player.controls = true; player.preload = 'none';
      const caption = document.createElement('figcaption'); caption.textContent = title || '音频';
      figure.append(player, caption); fragment.append(figure);
    }
    const paragraph = document.createElement('p'); paragraph.innerHTML = '<br>'; fragment.append(paragraph);
    if (request.replace) request.block.replaceWith(fragment);
    else if (request.before) request.block.before(fragment);
    else request.block.after(fragment);
    notify(); focusBlock(paragraph);
    return true;
  }
  const mayContainAudio = transfer => [...(transfer?.items || [])].some(item => item.kind === 'file' && (!item.type || item.type === 'application/octet-stream' || /^audio\//i.test(item.type)));
  function clearDropHint() { delete root.dataset.audioDrop; }
  root.addEventListener('dragover', event => {
    if (!mayContainAudio(event.dataTransfer)) return;
    event.preventDefault();
    const accepts = canEdit() && !pending.size;
    event.dataTransfer.dropEffect = accepts ? 'copy' : 'none';
    if (accepts) root.dataset.audioDrop = 'true'; else clearDropHint();
  });
  root.addEventListener('dragleave', event => { if (!root.contains(event.relatedTarget)) clearDropHint(); });
  root.addEventListener('drop', event => {
    clearDropHint();
    const files = [...(event.dataTransfer?.files || [])];
    if (!files.length || !files.every(file => /\.mp3$/i.test(file.name))) return;
    event.preventDefault(); event.stopImmediatePropagation();
    if (!canEdit() || pending.size) return;
    let block = event.target;
    while (block && block !== root && block.parentElement !== root && !block.parentElement?.matches('td,th')) block = block.parentElement;
    if (!block || block === root) {
      block = [...root.children].find(child => child.getBoundingClientRect().bottom >= event.clientY) || root.lastElementChild;
    }
    if (!block) return;
    const rect = block.getBoundingClientRect();
    const replace = block.tagName === 'P' && !block.textContent.trim() && !block.querySelector('img,audio');
    const requestID = remember(block, replace, event.clientY < rect.top + rect.height / 2);
    // Native pasteboard URLs let the importer copy the file without buffering
    // or base64-encoding an entire recording in the web process.
    if (requestID) send({ type: 'dropAudio', requestID, names: files.map(file => file.name) });
  }, true);
  window.addEventListener('dragend', clearDropHint);
  root.addEventListener('click', event => {
    const figure = event.target.closest(selector);
    if (figure && canEdit() && !event.target.closest('audio')) figure.focus();
  });
  root.addEventListener('keydown', event => {
    const figure = event.target.closest(selector);
    if (!figure || !canEdit()) return;
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z') return;
    // Leave the player's keyboard controls to WebKit, away from text commands.
    event.stopImmediatePropagation();
    if (event.target !== figure) return;
    if (event.key === 'Backspace' || event.key === 'Delete') {
      event.preventDefault(); checkpoint(); figure.querySelector('audio')?.pause();
      const next = figure.nextElementSibling || figure.previousElementSibling;
      figure.remove(); notify(); focusBlock(next || root.firstElementChild);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const paragraph = document.createElement('p'); paragraph.innerHTML = '<br>';
      checkpoint(); figure.after(paragraph); notify(); focusBlock(paragraph);
    }
  }, true);
  return { create, complete, completeMany, cancel, reset() { pending.clear(); updateButton(); clearDropHint(); } };
}
