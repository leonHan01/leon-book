function createArticleAudio({ root, canEdit, documentID, send, uuid, checkpoint, notify, focusBlock, closeMenu }) {
  const pending = new Map();
  const button = document.querySelector('#toolbar [data-command=audio]');
  const selector = 'figure[data-type=audio]';
  function updateButton() {
    button.disabled = pending.size > 0;
    button.textContent = pending.size ? '正在导入音频…' : '插入音频';
  }
  function create(block, replace = false) {
    if (!canEdit() || !block || !root.contains(block) || pending.size) return false;
    const requestID = uuid();
    pending.set(requestID, { block, replace, documentID: documentID(), original: block.outerHTML });
    closeMenu(); updateButton(); send({ type: 'chooseAudio', requestID });
    return true;
  }
  function cancel(requestID) {
    const request = pending.get(requestID);
    pending.delete(requestID); updateButton();
    if (request && canEdit() && request.documentID === documentID() && root.contains(request.block)) focusBlock(request.block, true);
  }
  function complete(requestID, source, title) {
    const request = pending.get(requestID);
    if (!request || !canEdit() || request.documentID !== documentID() || !root.contains(request.block)
        || request.block.outerHTML !== request.original || !/^\/media\/[^/]+\/[^/]+\.mp3$/i.test(source)) return false;
    pending.delete(requestID); updateButton(); checkpoint();
    const figure = document.createElement('figure');
    figure.dataset.type = 'audio'; figure.dataset.blockId = uuid();
    const player = document.createElement('audio');
    player.setAttribute('src', source); player.controls = true; player.preload = 'none';
    const caption = document.createElement('figcaption'); caption.textContent = title || '音频';
    figure.append(player, caption);
    if (request.replace) request.block.replaceWith(figure); else request.block.after(figure);
    const paragraph = document.createElement('p'); paragraph.innerHTML = '<br>'; figure.after(paragraph);
    notify(); focusBlock(paragraph);
    return true;
  }
  root.addEventListener('click', event => {
    const figure = event.target.closest(selector);
    if (figure && canEdit() && !event.target.closest('audio')) figure.focus();
  });
  root.addEventListener('keydown', event => {
    const figure = event.target.closest(selector);
    if (!figure || !canEdit()) return;
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
  return { create, complete, cancel, reset() { pending.clear(); updateButton(); } };
}
