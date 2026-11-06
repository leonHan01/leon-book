function createArticleColumns({ root, canEdit, checkpoint, notify, focusBlock, closeMenu, frameTask }) {
  const ROW = 'div[data-type=columns]', COLUMN = 'div[data-type=column]', CELL = 'td,th', MAX = 10;
  const t = (...args) => window.LeonL10n.text(...args);
  const owns = node => node && root.contains(node);
  const columns = row => [...row.children].filter(node => node.matches(COLUMN));
  const make = type => { const node = document.createElement('div'); node.dataset.type = type; return node; };
  const empty = () => { const node = document.createElement('p'); node.innerHTML = '<br>'; return node; };
  const container = node => node === root || node?.matches(`${COLUMN},${CELL}`);
  const placeholder = node => node?.matches('p') && !node.textContent.trim() && !node.querySelector(':not(br)');
  function weights(row) {
    const cells = columns(row), raw = cells.map(column => Math.max(0, parseFloat(column.style.width) || 100 / cells.length));
    const result = [], pending = new Set(raw.map((_, index) => index));
    let remaining = 100;
    // Keep a 2% floor even when imported widths do not sum to 100%.
    while (pending.size) {
      const total = [...pending].reduce((sum, index) => sum + raw[index], 0);
      const small = [...pending].filter(index => raw[index] / total * remaining < 2);
      if (!small.length) { for (const index of pending) result[index] = raw[index] / total * remaining; break; }
      for (const index of small) { result[index] = 2; remaining -= 2; pending.delete(index); }
    }
    return result;
  }
  function setWeights(row, values) {
    columns(row).forEach((column, index) => {
      const width = +values[index].toFixed(6) + '%';
      if (column.style.width !== width) column.style.width = width;
    });
  }
  // Repair imported/pasted layouts without dropping content or allowing nesting.
  function normalize() {
    for (const row of [...root.querySelectorAll(ROW)].reverse()) {
      if (!owns(row)) continue;
      if (row.parentElement !== root) {
        row.replaceWith(...[...row.childNodes].flatMap(node => node.matches?.(COLUMN) ? [...node.childNodes] : [node]));
        continue;
      }
      for (const node of [...row.childNodes]) {
        if (node.matches?.(COLUMN)) continue;
        if (node.nodeType === Node.TEXT_NODE && !node.textContent.trim()) { node.remove(); continue; }
        const column = make('column'); node.before(column); column.append(node);
      }
      let cells = columns(row);
      for (const extra of cells.slice(MAX)) { cells[MAX - 1].append(...extra.childNodes); extra.remove(); }
      cells = columns(row);
      if (cells.length < 2) { row.replaceWith(...cells.flatMap(column => [...column.childNodes])); continue; }
      for (const column of cells) if (!column.childNodes.length) column.append(empty());
      setWeights(row, weights(row));
    }
    for (const column of root.querySelectorAll(COLUMN)) {
      if (!column.parentElement.matches(ROW)) column.replaceWith(...column.childNodes);
    }
  }
  function blockFor(node) {
    if (!owns(node) || node === root) return null;
    if (node.nodeType !== Node.ELEMENT_NODE) node = node.parentElement;
    if (node.matches(`${COLUMN},${CELL}`)) return null;
    while (!container(node.parentElement)) node = node.parentElement;
    return node.matches(ROW) ? null : node;
  }
  function cleanup(column) {
    if (!column?.matches(COLUMN) || !owns(column)) return;
    const row = column.parentElement;
    if (!column.childNodes.length) column.remove();
    const cells = columns(row);
    if (cells.length < 2) row.replaceWith(...cells.flatMap(cell => [...cell.childNodes]));
    else setWeights(row, weights(row));
  }
  function canMove(source, target, side) {
    if (!canEdit() || !owns(source) || !owns(target) || source === target || source.contains(target)
        || !container(source.parentElement)) return false;
    if (side === 'inside') return target.matches(CELL) && (source.parentElement !== target || target.lastElementChild !== source);
    if (!['left', 'right'].includes(side)) return ['before', 'after'].includes(side) && container(target.parentElement);
    if (target.matches(ROW) || target.closest(CELL)) return false;
    const column = target.closest(COLUMN), row = column?.parentElement;
    if (!row) return target.parentElement === root;
    if (source.parentElement === column && column.children.length === 1) return false;
    // Moving a whole single-block column within a full row does not add a column.
    const removesColumn = source.parentElement.matches(COLUMN) && source.parentElement.parentElement === row && source.parentElement.children.length === 1;
    return columns(row).length - (removesColumn ? 1 : 0) < MAX;
  }
  function move(source, target, side) {
    if (!canMove(source, target, side)) return false;
    checkpoint(); closeMenu();
    const oldColumn = source.parentElement.matches(COLUMN) ? source.parentElement : null;
    const oldCell = source.parentElement.matches(CELL) ? source.parentElement : null;
    if (side === 'inside') {
      if (target.children.length === 1 && placeholder(target.firstElementChild)) target.firstElementChild.remove();
      target.append(source);
    } else if (side === 'before') target.before(source);
    else if (side === 'after') target.after(source);
    else {
      let column = target.closest(COLUMN), row = column?.parentElement;
      if (!row) {
        row = make('columns'); column = make('column'); target.before(row); row.append(column); column.append(target);
      }
      const next = make('column'); next.append(source);
      if (oldColumn?.parentElement === row && !oldColumn.childNodes.length) oldColumn.remove();
      const cells = columns(row), index = cells.indexOf(column), share = 100 / (cells.length + 1);
      const values = weights(row).map(value => value * (100 - share) / 100);
      values.splice(index + (side === 'right' ? 1 : 0), 0, share);
      if (side === 'left') column.before(next); else column.after(next);
      setWeights(row, values);
    }
    if (owns(oldCell) && !oldCell.children.length && !oldCell.textContent.trim()) oldCell.replaceChildren(empty());
    cleanup(oldColumn); normalize(); focusBlock(source); notify(); refresh(); return true;
  }

  // Controls live outside contenteditable, so serialization and undo contain only article content.
  const handle = document.createElement('button'); handle.id = 'article-block-handle'; handle.type = 'button';
  handle.textContent = '⠿'; handle.hidden = true;
  const guides = document.createElement('div'); guides.id = 'article-column-guides';
  const marker = document.createElement('div'); marker.id = 'article-block-drop'; marker.hidden = true;
  const status = document.createElement('div'); status.id = 'article-column-status'; status.hidden = true; status.setAttribute('role', 'status');
  document.body.append(handle, guides, marker, status);
  let hovered = null, activeRow = null, drag = null, destination = null, handleArea = null;
  function labels() { handle.title = t('拖动内容块：左右分栏，上下排序'); handle.setAttribute('aria-label', handle.title); }
  labels(); window.addEventListener('leonlanguagechange', labels);
  function hidden(node, value) { if (node.hidden !== value) node.hidden = value; }
  function attribute(node, name, value) { if (node.getAttribute(name) !== String(value)) node.setAttribute(name, value); }
  function rectStyle(node, rect) {
    for (const key of ['left', 'top', 'width', 'height']) {
      if (rect[key] === undefined) continue;
      const value = rect[key] + 'px';
      if (node.style[key] !== value) node.style[key] = value;
    }
  }
  function refresh() {
    if (!canEdit()) { reset(); return; }
    // Read all geometry before changing overlay styles. In a ten-column row,
    // each column is measured once instead of once for each adjacent divider.
    const handleRect = owns(hovered) ? hovered.getBoundingClientRect() : null;
    const row = owns(activeRow) ? activeRow : null;
    const cells = row ? columns(row) : [], bounds = row?.getBoundingClientRect();
    const boxes = cells.map(cell => cell.getBoundingClientRect()), values = row ? weights(row) : [];
    hidden(handle, !handleRect || handleRect.bottom < 0 || handleRect.top > innerHeight);
    handleArea = handleRect && !handle.hidden ? {
      left: Math.max(0, handleRect.left - 34), right: handleRect.left,
      top: Math.max(0, handleRect.top) - 4, bottom: Math.max(0, handleRect.top) + 36
    } : null;
    if (handleRect) rectStyle(handle, { left: Math.max(0, handleRect.left - 28), top: Math.max(0, handleRect.top) });
    if (!row) { if (guides.childElementCount) guides.replaceChildren(); activeRow = null; return; }
    if (guides.children.length !== cells.length - 1) {
      guides.replaceChildren(...cells.slice(1).map((_, index) => {
        const separator = document.createElement('div'); separator.className = 'article-column-separator'; separator.tabIndex = 0;
        separator.dataset.index = index; separator.setAttribute('role', 'separator'); separator.setAttribute('aria-orientation', 'vertical');
        separator.setAttribute('aria-label', t('拖动调整分栏宽度')); return separator;
      }));
    }
    [...guides.children].forEach((separator, index) => {
      rectStyle(separator, { left: (boxes[index].right + boxes[index + 1].left) / 2 - 5, top: bounds.top, width: 10, height: bounds.height });
      const total = values[index] + values[index + 1];
      attribute(separator, 'aria-valuenow', Math.round(values[index] / total * 100));
      const minimum = Math.min(total / 2, Math.max(2, total * .1)) / total * 100;
      attribute(separator, 'aria-valuemin', Math.round(minimum)); attribute(separator, 'aria-valuemax', Math.round(100 - minimum));
    });
  }
  const schedule = frameTask(refresh);
  // Keep the same block while crossing its gutter, including a little vertical
  // tolerance. Cached geometry avoids layout reads on every pointer movement.
  function nearHandle(event) {
    return handleArea && owns(hovered) && event.clientX >= handleArea.left && event.clientX <= handleArea.right
      && event.clientY >= handleArea.top && event.clientY <= handleArea.bottom;
  }
  root.addEventListener('pointermove', event => {
    if (drag || !canEdit() || nearHandle(event)) return;
    // Cell content exposes its own blocks; table padding/borders still offer
    // the whole-table handle, so tables remain movable as a unit.
    const nextBlock = blockFor(event.target) || (event.target.matches(CELL) ? event.target.closest('table') : null), nextRow = event.target.closest(ROW);
    if (hovered === nextBlock && activeRow === nextRow) return;
    hovered = nextBlock; activeRow = nextRow; schedule();
  }, { passive: true });
  document.addEventListener('pointermove', event => {
    if (!drag && (hovered || activeRow) && !root.contains(event.target) && !handle.contains(event.target) && !guides.contains(event.target) && !nearHandle(event)) {
      hovered = activeRow = null; schedule();
    }
  }, { passive: true });
  function begin(event, state) {
    if (event.button !== 0 || !canEdit()) return;
    event.preventDefault(); closeMenu(); schedule.cancel(); drag = { ...state, pointer: event.pointerId, capture: event.currentTarget };
    try { event.currentTarget.setPointerCapture(event.pointerId); } catch {}
    document.body.classList.add('article-layout-dragging');
  }
  handle.addEventListener('pointerdown', event => {
    if (owns(hovered)) begin(event, { type: 'block', source: hovered, startX: event.clientX, startY: event.clientY, moved: false });
  });
  guides.addEventListener('pointerdown', event => {
    const separator = event.target.closest('.article-column-separator');
    if (!separator || !owns(activeRow) || !canEdit() || event.button !== 0) return;
    checkpoint();
    begin(event, { type: 'resize', row: activeRow, index: +separator.dataset.index, startX: event.clientX,
      values: weights(activeRow), originals: columns(activeRow).map(column => column.style.width),
      width: columns(activeRow).reduce((sum, column) => sum + column.getBoundingClientRect().width, 0) });
  });
  function resized(values, index, delta) {
    const next = [...values], total = values[index] + values[index + 1];
    const minimum = Math.min(total / 2, Math.max(2, total * .1));
    next[index] = Math.max(minimum, Math.min(total - minimum, values[index] + delta));
    next[index + 1] = total - next[index]; return next;
  }
  guides.addEventListener('keydown', event => {
    if (!canEdit() || !owns(activeRow) || !['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
    event.preventDefault(); checkpoint();
    setWeights(activeRow, resized(weights(activeRow), +event.target.dataset.index, (event.key === 'ArrowLeft' ? -1 : 1) * (event.shiftKey ? 5 : 1)));
    notify(); refresh();
  });
  // Article and column children stay in vertical document order. Search their
  // lower edges without measuring every preceding block in a long article.
  function blockAtY(container, y, measure) {
    const children = container.children;
    let low = 0, high = children.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (measure(children[middle]).bottom < y) low = middle + 1;
      else high = middle;
    }
    return children[low] || container.lastElementChild;
  }
  function hit(x, y) {
    // Cache only within this hit test. Scrolling, image loading and editor
    // changes get fresh geometry on the next frame without a stale drag cache.
    const boxes = new Map();
    const measure = element => {
      if (!boxes.has(element)) boxes.set(element, element.getBoundingClientRect());
      return boxes.get(element);
    };
    const bounds = measure(root);
    if (x < bounds.left || x > bounds.right || y < bounds.top || y > bounds.bottom) return null;
    const node = document.elementFromPoint(x, y), row = node?.closest(ROW);
    let target = blockFor(node);
    if (row) {
      const rect = measure(row);
      if (y < rect.top + 7 || y > rect.bottom - 7) return { target: row, side: y < rect.top + 7 ? 'before' : 'after', box: rect };
    }
    const cell = node?.closest(CELL);
    if (owns(cell)) {
      const table = cell.closest('table'), tableBox = measure(table);
      const outerTable = table.parentElement === root || table.parentElement.matches(COLUMN);
      // Keep a narrow outer edge for arranging the entire table in the article.
      // Everywhere inside it targets the actual cell, including its padding.
      if (outerTable && (x <= tableBox.left + 6 || x >= tableBox.right - 6 || y <= tableBox.top + 6 || y >= tableBox.bottom - 6)) target = table;
      else {
        target = blockFor(node) || blockAtY(cell, y, measure);
        if (!target || (cell.children.length === 1 && placeholder(target))) {
          const box = measure(cell), inset = Math.min(10, box.width / 4, box.height / 4);
          const content = target ? measure(target) : null;
          return { target: cell, side: 'inside', box: { left: content?.left ?? box.left + inset,
            width: content?.width ?? box.width - inset * 2, bottom: content?.top ?? box.top + inset } };
        }
        const box = measure(target);
        return { target, side: y < box.top + box.height / 2 ? 'before' : 'after', box };
      }
    }
    if (row) {
      if (!target || target.matches(COLUMN)) {
        const column = columns(row).reduce((best, next) => {
          const distance = cell => { const box = measure(cell); return Math.abs(x - Math.max(box.left, Math.min(x, box.right))); };
          return !best || distance(next) < distance(best) ? next : best;
        }, null);
        target = blockAtY(column, y, measure);
      }
    }
    if (!target) target = blockAtY(root, y, measure);
    if (!target) return null;
    const rect = measure(target.closest(COLUMN) || target), blockRect = measure(target);
    const edge = Math.min(32, rect.width * .22);
    const side = target.matches(ROW) ? (y < blockRect.top + blockRect.height / 2 ? 'before' : 'after')
      : x <= rect.left + edge ? 'left' : x >= rect.right - edge ? 'right' : y < blockRect.top + blockRect.height / 2 ? 'before' : 'after';
    return { target, side, box: side === 'left' || side === 'right' ? rect : blockRect };
  }
  function updateDrag(event) {
    if (!drag || event.pointerId !== drag.pointer || !canEdit()) return;
    if (drag.type === 'resize') {
      setWeights(drag.row, resized(drag.values, drag.index, (event.clientX - drag.startX) / Math.max(1, drag.width) * 100)); refresh(); return;
    }
    if (!drag.moved && Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) < 4) return;
    drag.moved = true;
    destination = hit(event.clientX, event.clientY);
    if (!destination) { hidden(marker, true); hidden(status, true); return; }
    const { target, side } = destination;
    if (!canMove(drag.source, target, side)) {
      const atLimit = ['left', 'right'].includes(side) && target.closest(ROW)?.children.length >= MAX;
      if (atLimit) { const message = t('每行最多支持 10 个分栏'); if (status.textContent !== message) status.textContent = message; }
      hidden(marker, true); hidden(status, !atLimit);
      destination = null; return;
    }
    const box = destination.box;
    const vertical = side === 'left' || side === 'right';
    rectStyle(marker, { left: vertical ? (side === 'left' ? box.left : box.right) - 2 : box.left,
      top: vertical ? box.top : (side === 'before' ? box.top : box.bottom) - 2,
      width: vertical ? 4 : box.width, height: vertical ? box.height : 4 });
    hidden(marker, false); hidden(status, true);
  }
  const scheduleDrag = frameTask(updateDrag);
  document.addEventListener('pointermove', event => {
    if (drag?.pointer === event.pointerId) scheduleDrag({ pointerId: event.pointerId, clientX: event.clientX, clientY: event.clientY });
  }, { passive: true });
  function finish(cancel = false) {
    scheduleDrag.cancel();
    if (!drag) return;
    const state = drag, drop = destination; drag = destination = null;
    try { state.capture.releasePointerCapture(state.pointer); } catch {}
    document.body.classList.remove('article-layout-dragging'); marker.hidden = status.hidden = true;
    if (state.type === 'resize' && owns(state.row)) {
      if (cancel || !canEdit()) columns(state.row).forEach((column, index) => { column.style.width = state.originals[index]; });
      else notify();
    } else if (!cancel && state.moved && drop) move(state.source, drop.target, drop.side);
    schedule();
  }
  document.addEventListener('pointerup', event => { if (drag?.pointer === event.pointerId) { scheduleDrag.cancel(); updateDrag(event); finish(); } });
  document.addEventListener('pointercancel', () => finish(true));
  document.addEventListener('keydown', event => { if (event.key === 'Escape' && drag) { event.preventDefault(); finish(true); } });
  window.addEventListener('blur', () => finish(true));
  function reset() { finish(true); schedule.cancel(); hovered = activeRow = handleArea = null; handle.hidden = marker.hidden = status.hidden = true; guides.replaceChildren(); }
  window.addEventListener('resize', schedule);
  document.addEventListener('scroll', schedule, { capture: true, passive: true });
  new ResizeObserver(schedule).observe(root);
  // Do not let native backspace/delete merge separate columns at their edges.
  root.addEventListener('beforeinput', event => {
    if (!canEdit() || !['deleteContentBackward', 'deleteContentForward'].includes(event.inputType)) return;
    const selection = getSelection(); if (!selection?.isCollapsed || !selection.rangeCount) return;
    const range = selection.getRangeAt(0), node = range.startContainer.nodeType === Node.ELEMENT_NODE ? range.startContainer : range.startContainer.parentElement;
    const column = node.closest(COLUMN); if (!column) return;
    const boundary = document.createRange(); boundary.selectNodeContents(column);
    if (event.inputType === 'deleteContentBackward') boundary.setEnd(range.startContainer, range.startOffset);
    else boundary.setStart(range.startContainer, range.startOffset);
    const fragment = boundary.cloneContents();
    if (!fragment.textContent && !fragment.querySelector('img,audio,video,table,hr')) event.preventDefault();
  });
  return { normalize, reset };
}
