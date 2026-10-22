function createArticleCaret({ root, canEdit, frameTask }) {
  const caret = document.createElement('div'), measure = document.createElement('span');
  caret.id = 'article-caret'; caret.hidden = true; caret.setAttribute('aria-hidden', 'true');
  measure.id = 'article-caret-measure'; measure.textContent = '\u200b'; measure.setAttribute('aria-hidden', 'true');
  document.body.append(caret, measure);
  let composing = false, windowFocused = true, dragging = false;
  const elementFor = node => node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
  const firstRect = range => [...range.getClientRects()].find(rect => rect.height > 0);

  function hide() {
    caret.hidden = true;
    root.classList.remove('article-caret-visible');
  }
  // Reading a collapsed text Range does not include the extra line spacing.
  // Resolve element-boundary selections without inserting markers into the
  // editable DOM: even temporary markers can disturb undo and IME composition.
  function boundaryRect(node, atEnd) {
    while (node?.nodeType === Node.ELEMENT_NODE && node.childNodes.length) node = atEnd ? node.lastChild : node.firstChild;
    if (!node || elementFor(node).closest('[contenteditable=false],img,hr')) return null;
    const range = document.createRange();
    if (node.nodeType === Node.TEXT_NODE) range.setStart(node, atEnd ? node.length : 0);
    else if (node.nodeName === 'BR') range.selectNode(node);
    else return null;
    if (node.nodeName !== 'BR') range.collapse(true);
    const rect = firstRect(range);
    return rect ? { rect, element: elementFor(node) } : null;
  }
  function geometry(range) {
    const node = range.startContainer, element = elementFor(node), rect = firstRect(range);
    if (rect) return { rect, element };
    if (node.nodeType === Node.ELEMENT_NODE) {
      const next = node.childNodes[range.startOffset], previous = node.childNodes[range.startOffset - 1];
      const result = boundaryRect(next, false) || boundaryRect(previous, true);
      if (result) return result;
    }
    // An empty block without a BR has no Range rectangle. Measure the same font
    // outside the document, then place it in the block's first line box.
    const block = element.closest('p,h1,h2,h3,h4,pre,aside,blockquote,li,td,th,figcaption');
    if (!block || block.textContent || block.querySelector('img,table,hr')) return null;
    const style = getComputedStyle(block);
    measure.style.font = style.font; measure.style.lineHeight = 'normal';
    const probe = document.createRange(); probe.selectNodeContents(measure);
    const height = firstRect(probe)?.height;
    if (!height) return null;
    const bounds = block.getBoundingClientRect(), lineHeight = parseFloat(style.lineHeight) || height;
    const top = bounds.top + parseFloat(style.borderTopWidth) + parseFloat(style.paddingTop) + (lineHeight - height) / 2;
    const left = style.direction === 'rtl'
      ? bounds.right - parseFloat(style.borderRightWidth) - parseFloat(style.paddingRight)
      : bounds.left + parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft);
    return { rect: { top, left, height, bottom: top + height }, element: block };
  }
  function update() {
    const selection = getSelection();
    if (!canEdit() || composing || !windowFocused || dragging || !root.contains(document.activeElement)
        || !selection?.isCollapsed || !selection.rangeCount || !root.contains(selection.anchorNode)
        || elementFor(selection.anchorNode).closest('[contenteditable=false]')) { hide(); return; }
    const result = geometry(selection.getRangeAt(0));
    if (!result || result.rect.bottom <= 0 || result.rect.top >= innerHeight) { hide(); return; }
    const { rect, element } = result;
    caret.style.left = rect.left + 'px'; caret.style.top = rect.top + 'px'; caret.style.height = rect.height + 'px';
    caret.style.color = getComputedStyle(element).color;
    caret.hidden = false; root.classList.add('article-caret-visible');
    for (const animation of caret.getAnimations()) animation.currentTime = 0;
  }
  const schedule = frameTask(update);
  const reset = () => { schedule.cancel(); hide(); };
  document.addEventListener('selectionchange', schedule);
  root.addEventListener('input', schedule);
  root.addEventListener('focusin', schedule);
  root.addEventListener('focusout', reset);
  root.addEventListener('compositionstart', () => { composing = true; reset(); });
  root.addEventListener('compositionend', () => { composing = false; schedule(); });
  root.addEventListener('pointerdown', () => { dragging = true; reset(); });
  window.addEventListener('pointerup', () => { dragging = false; schedule(); });
  window.addEventListener('pointercancel', () => { dragging = false; schedule(); });
  window.addEventListener('blur', () => { windowFocused = false; dragging = false; reset(); });
  window.addEventListener('focus', () => { windowFocused = true; schedule(); });
  window.addEventListener('pagehide', reset);
  window.addEventListener('resize', schedule);
  document.addEventListener('scroll', schedule, { capture: true, passive: true });
  new ResizeObserver(schedule).observe(root);
  new MutationObserver(records => {
    if (records.some(record => record.target !== root || record.type !== 'attributes')) schedule();
  }).observe(root, { subtree: true, childList: true, characterData: true, attributes: true });
  return { refresh() { reset(); schedule(); } };
}
