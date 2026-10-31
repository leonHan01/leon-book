function createArticleAudio({ root, canEdit, documentID, send, uuid, checkpoint, notify, focusBlock, closeMenu }) {
  const t = (...args) => window.LeonL10n.text(...args);
  const pending = new Map();
  window.addEventListener('leonlanguagechange', () => updateButton());
  const button = document.querySelector('#toolbar [data-command=audio]');
  const selector = 'figure[data-type=audio],figure[data-type=video]';
  function updateButton() {
    button.disabled = pending.size > 0;
    button.classList.toggle('is-loading', pending.size > 0);
    button.setAttribute('aria-busy', String(pending.size > 0));
    const label = button.querySelector('.tool-label') || button;
    label.textContent = pending.size ? t('正在导入媒体…') : t('插入音频');
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
    if (!Array.isArray(items)) return false;
    return completeMedia(requestID, items.map(item => ({ ...item, kind: 'audio' })));
  }
  const extensions = {
    image: /\.(png|jpe?g|gif|webp|bmp|tiff?|heic|heif)$/i,
    video: /\.(mp4|mov|m4v|webm)$/i,
    audio: /\.mp3$/i,
  };
  function completeMedia(requestID, items) {
    const request = pending.get(requestID);
    if (!request || !canEdit() || request.documentID !== documentID() || !root.contains(request.block)
        || request.block.outerHTML !== request.original || !Array.isArray(items) || !items.length
        || !items.every(item => /^\/media\/[^/]+\/[^/]+$/.test(item.source) && extensions[item.kind]?.test(item.source))) return false;
    pending.delete(requestID); updateButton(); checkpoint();
    const fragment = document.createDocumentFragment();
    for (const { source, title, kind } of items) {
      const figure = document.createElement('figure');
      figure.dataset.type = kind; figure.dataset.blockId = uuid();
      const player = document.createElement(kind === 'image' ? 'img' : kind);
      player.setAttribute('src', source);
      if (kind === 'image') player.setAttribute('alt', title || '');
      else { player.controls = true; player.preload = 'none'; }
      const caption = document.createElement('figcaption'); caption.textContent = title || '';
      figure.append(player, caption); fragment.append(figure);
    }
    const paragraph = document.createElement('p'); paragraph.innerHTML = '<br>'; fragment.append(paragraph);
    if (request.replace) request.block.replaceWith(fragment);
    else if (request.before) request.block.before(fragment);
    else request.block.after(fragment);
    notify(); focusBlock(paragraph);
    return true;
  }
  const mayContainMedia = transfer => [...(transfer?.items || [])].some(item => item.kind === 'file' && (!item.type || item.type === 'application/octet-stream' || /^(image|video|audio)\//i.test(item.type)))
    || [...(transfer?.types || [])].includes('Files');
  function clearDropHint() { delete root.dataset.audioDrop; }
  root.addEventListener('dragover', event => {
    if (!mayContainMedia(event.dataTransfer)) return;
    event.preventDefault();
    const accepts = canEdit() && !pending.size;
    event.dataTransfer.dropEffect = accepts ? 'copy' : 'none';
    if (accepts) root.dataset.audioDrop = 'true'; else clearDropHint();
  });
  root.addEventListener('dragleave', event => { if (!root.contains(event.relatedTarget)) clearDropHint(); });
  root.addEventListener('drop', event => {
    clearDropHint();
    const files = [...(event.dataTransfer?.files || [])];
    if (!files.length) return;
    event.preventDefault(); event.stopImmediatePropagation();
    if (!canEdit() || pending.size || !files.every(file => Object.values(extensions).some(pattern => pattern.test(file.name)))) return;
    let block = event.target;
    while (block && block !== root && block.parentElement !== root && !block.parentElement?.matches('td,th,div[data-type=column]')) block = block.parentElement;
    if (!block || block === root) {
      block = [...root.children].find(child => child.getBoundingClientRect().bottom >= event.clientY) || root.lastElementChild;
    }
    if (!block) return;
    const rect = block.getBoundingClientRect();
    const replace = block.tagName === 'P' && !block.textContent.trim() && !block.querySelector('img,audio,video');
    const requestID = remember(block, replace, event.clientY < rect.top + rect.height / 2);
    // Native pasteboard URLs let the importer copy the file without buffering
    // or base64-encoding an entire video/recording in the web process.
    if (requestID) send({ type: 'dropMedia', requestID, names: files.map(file => file.name) });
  }, true);
  window.addEventListener('dragend', clearDropHint);
  root.addEventListener('click', event => {
    const figure = event.target.closest(selector);
    if (figure && canEdit() && !event.target.closest('audio,video')) figure.focus();
  });
  root.addEventListener('keydown', event => {
    const figure = event.target.closest(selector);
    if (!figure || !canEdit()) return;
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z') return;
    // Leave the player's keyboard controls to WebKit, away from text commands.
    event.stopImmediatePropagation();
    if (event.target !== figure) return;
    if (event.key === 'Backspace' || event.key === 'Delete') {
      event.preventDefault(); checkpoint(); figure.querySelector('audio,video')?.pause();
      const next = figure.nextElementSibling || figure.previousElementSibling;
      figure.remove(); notify(); focusBlock(next || root.firstElementChild);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const paragraph = document.createElement('p'); paragraph.innerHTML = '<br>';
      checkpoint(); figure.after(paragraph); notify(); focusBlock(paragraph);
    }
  }, true);
  return { create, complete, completeMany, completeMedia, cancel, reset() { pending.clear(); updateButton(); clearDropHint(); } };
}
