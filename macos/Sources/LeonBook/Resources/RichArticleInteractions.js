function createArticleInteractions(api) {
  const t = (...args) => window.LeonL10n.text(...args);
  const { root, canEdit, checkpoint, notify, focusBlock, captureSelection, restoreSelection, execute, send, uuid, closeMenu, frameTask } = api;
  function panel(id, html, label) {
    const element = document.createElement('div'); element.id = id; element.className = 'editor-popover'; element.hidden = true;
    element.setAttribute('role', 'toolbar'); element.setAttribute('aria-label', label); element.innerHTML = html; document.body.append(element); window.LeonL10n.bindChrome(element); return element;
  }
  const picker = panel('table-picker', '<div class="tool-label">插入表格 · <span class="size-label">2 × 2</span></div><div class="table-grid"></div><div class="table-dimensions"><input type="number" min="1" max="30" value="2" aria-label="行数">行<input type="number" min="1" max="12" value="2" aria-label="列数">列<button class="insert-table">插入</button></div>', '选择表格行列数');
  picker.setAttribute('role', 'dialog');
  const tableTools = panel('table-tools', '<div class="tool-label"></div><div class="tool-actions"><button data-table="row-before" title="上方插入行"><svg class="popover-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20V4m-6 6 6-6 6 6"/></svg>加行</button><button data-table="row-after" title="下方插入行"><svg class="popover-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4v16m-6-6 6 6 6-6"/></svg>加行</button><button data-table="row-delete" class="danger">删行</button><button data-table="column-before" title="左侧插入列"><svg class="popover-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 12H4m6-6-6 6 6 6"/></svg>加列</button><button data-table="column-after" title="右侧插入列"><svg class="popover-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12h16m-6-6 6 6-6 6"/></svg>加列</button><button data-table="column-delete" class="danger">删列</button></div>', '表格操作');
  const imageTools = panel('image-tools', '<output></output><button data-image="preview">放大</button><button data-image="caption">说明</button><button data-image="replace">替换</button><button data-image="delete" class="danger">删除</button>', '图片操作');
  const grip = document.createElement('div'); grip.id = 'column-grip'; grip.hidden = true; grip.setAttribute('role', 'separator'); grip.setAttribute('aria-label', '拖动调整列宽'); document.body.append(grip);
  function quickAdd(id, label) {
    const button = document.createElement('button'); button.id = id; button.type = 'button'; button.className = 'table-quick-add'; button.hidden = true;
    button.title = label; button.setAttribute('aria-label', label); button.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 3v10M3 8h10"/></svg>';
    button.addEventListener('mousedown', event => event.preventDefault()); button.addEventListener('pointerenter', () => clearTimeout(tableTimer));
    document.body.append(button); return button;
  }
  const rowAdd = quickAdd('table-add-row', '在表格底部添加一行'), columnAdd = quickAdd('table-add-column', '在此处添加一列');
  const frame = document.createElement('div'); frame.id = 'image-frame'; frame.className = 'editor-overlay'; frame.hidden = true; frame.innerHTML = '<span class="image-resize" data-side="-1" role="separator" aria-label="拖动调整图片宽度"></span><span class="image-resize" data-side="1" role="separator" aria-label="拖动调整图片宽度"></span>'; document.body.append(frame);
  const preview = document.createElement('div'); preview.id = 'image-preview'; preview.className = 'editor-overlay'; preview.hidden = true; preview.setAttribute('role', 'dialog'); preview.setAttribute('aria-label', '图片预览'); preview.setAttribute('aria-modal', 'true'); preview.innerHTML = '<button title="关闭预览" aria-label="关闭预览"><svg class="popover-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="m6 6 12 12M6 18 18 6"/></svg></button><img alt="">'; document.body.append(preview);
  const progress = document.createElement('div'); progress.id = 'image-progress'; progress.hidden = true; progress.setAttribute('role', 'status'); document.body.append(progress);
  let activeCell = null, quickRowTable = null, quickColumnCell = null, selectedImage = null, insertion = null, drag = null, tableTimer, progressTimer, pickerRows = 2, pickerColumns = 2, previewFocus = null;
  const replacements = new Map();
  for (const chrome of [grip, rowAdd, columnAdd, frame, preview]) window.LeonL10n.bindChrome(chrome);
  function place(element, rect, gap = 7) {
    const minimum = Math.max(8, document.getElementById('toolbar').getBoundingClientRect().bottom + 5);
    const top = rect.top - element.offsetHeight - gap;
    element.style.left = Math.max(8, Math.min(rect.left, innerWidth - element.offsetWidth - 8)) + 'px';
    element.style.top = Math.max(8, Math.min(top >= minimum ? top : rect.bottom + gap, innerHeight - element.offsetHeight - 8)) + 'px';
  }
  function owns(element) { return element && root.contains(element); }
  function hideQuickAdds() { rowAdd.hidden = columnAdd.hidden = true; quickRowTable = quickColumnCell = null; }
  function tableControl(target) { return tableTools.contains(target) || rowAdd.contains(target) || columnAdd.contains(target) || target === grip; }
  function scheduleTableHide() { if (tableTools.hidden && grip.hidden && rowAdd.hidden && columnAdd.hidden) return; clearTimeout(tableTimer); tableTimer = setTimeout(() => { tableTools.hidden = grip.hidden = true; hideQuickAdds(); }, 180); }
  function positionQuickAdds() {
    if (!canEdit() || selectedImage || !picker.hidden || !preview.hidden || !getSelection().isCollapsed) { hideQuickAdds(); return; }
    const minimum = Math.max(8, document.getElementById('toolbar').getBoundingClientRect().bottom + 5);
    if (owns(quickRowTable)) {
      const rect = quickRowTable.getBoundingClientRect();
      rowAdd.hidden = rect.bottom < minimum || rect.bottom > innerHeight - 11 || rect.right < 0 || rect.left > innerWidth;
      if (!rowAdd.hidden) { rowAdd.style.left = Math.max(3, Math.min(rect.left - 11, innerWidth - 25)) + 'px'; rowAdd.style.top = rect.bottom - 11 + 'px'; }
    } else rowAdd.hidden = true;
    if (owns(quickColumnCell)) {
      const table = quickColumnCell.closest('table'), rect = table.getBoundingClientRect(), edge = quickColumnCell.getBoundingClientRect().right;
      const top = Math.max(minimum, rect.top - 11);
      columnAdd.hidden = edge < 11 || edge > innerWidth - 11 || rect.bottom < top + 22 || top > innerHeight - 25;
      if (!columnAdd.hidden) { columnAdd.style.left = edge - 11 + 'px'; columnAdd.style.top = top + 'px'; }
    } else columnAdd.hidden = true;
  }
  function showQuickAdds(cell) {
    if (!canEdit() || !owns(cell)) { hideQuickAdds(); return; }
    clearTimeout(tableTimer); quickRowTable = cell.closest('table');
    if (quickColumnCell?.closest('table') !== quickRowTable) quickColumnCell = null;
    positionQuickAdds();
  }
  function rows(table) { return [...table.rows]; }
  function columns(table) { return Math.max(1, ...rows(table).map(row => row.cells.length)); }
  function columnGroup(table, count = columns(table)) {
    let group = [...table.children].find(element => element.tagName === 'COLGROUP');
    if (!group) { group = document.createElement('colgroup'); table.prepend(group); }
    if (group.children.length !== count) {
      group.replaceChildren(...Array.from({ length: count }, () => { const col = document.createElement('col'); col.style.width = 100 / count + '%'; return col; }));
    }
    return group;
  }
  function emptyCell(header = false) { const cell = document.createElement(header ? 'th' : 'td'); cell.innerHTML = '<p><br></p>'; return cell; }
  function appendRow(table) {
    if (!canEdit() || !owns(table)) return;
    checkpoint(); const section = table.tBodies[0] || table.createTBody(), row = section.insertRow();
    row.append(...Array.from({ length: columns(table) }, () => emptyCell()));
    focusBlock(row.cells[0]); notify(); showTable(row.cells[0]);
  }
  function removeTable(table) {
    const paragraph = document.createElement('p'); paragraph.innerHTML = '<br>'; table.replaceWith(paragraph); activeCell = null; tableTools.hidden = grip.hidden = true; hideQuickAdds(); focusBlock(paragraph);
  }
  function editTable(action) {
    if (!canEdit() || !owns(activeCell)) return;
    checkpoint(); const cell = activeCell, row = cell.parentElement, table = cell.closest('table'), rowList = rows(table), index = rowList.indexOf(row), column = cell.cellIndex;
    if (action.startsWith('row-')) {
      if (action === 'row-delete') {
        if (rowList.length === 1) removeTable(table);
        else { const next = rowList[index + 1] || rowList[index - 1]; row.remove(); activeCell = next.cells[Math.min(column, next.cells.length - 1)]; focusBlock(activeCell); }
      } else {
        const next = document.createElement('tr'), header = action === 'row-before' && row.parentElement.tagName === 'THEAD';
        next.append(...Array.from({ length: columns(table) }, () => emptyCell(header)));
        if (action === 'row-before') row.before(next);
        else if (row.parentElement.tagName === 'THEAD') { const body = table.tBodies[0] || table.createTBody(); body.prepend(next); }
        else row.after(next);
        activeCell = next.cells[column]; focusBlock(activeCell);
      }
    } else if (action === 'column-delete' && columns(table) === 1) removeTable(table);
    else {
      for (const item of rowList) {
        if (action === 'column-delete') item.cells[column]?.remove();
        else {
          const offset = Math.min(item.cells.length, column + (action === 'column-after' ? 1 : 0));
          item.insertBefore(emptyCell(item.parentElement.tagName === 'THEAD'), item.cells[offset] || null);
        }
      }
      columnGroup(table); activeCell = row.cells[Math.min(column + (action === 'column-after' ? 1 : 0), row.cells.length - 1)]; focusBlock(activeCell);
    }
    notify(); if (owns(activeCell)) showTable(activeCell);
  }
  function showTable(cell) {
    if (!canEdit() || !owns(cell) || !getSelection().isCollapsed || selectedImage) { tableTools.hidden = true; hideQuickAdds(); return; }
    clearTimeout(tableTimer); activeCell = cell; const table = cell.closest('table');
    tableTools.querySelector('.tool-label').textContent = t('表格 · 第 %@ 行，第 %@ 列', cell.parentElement.rowIndex + 1, cell.cellIndex + 1);
    tableTools.hidden = false; place(tableTools, table.getBoundingClientRect(), 16); showQuickAdds(cell);
  }
  rowAdd.addEventListener('click', () => {
    if (rowAdd.hidden || !owns(quickRowTable)) return;
    quickColumnCell = null; columnAdd.hidden = true; appendRow(quickRowTable);
  });
  columnAdd.addEventListener('click', () => {
    if (columnAdd.hidden || !canEdit() || !owns(quickColumnCell)) return;
    activeCell = quickColumnCell; quickColumnCell = null; columnAdd.hidden = true; editTable('column-after');
  });
  function drawPicker() {
    picker.querySelector('.size-label').textContent = pickerRows + ' × ' + pickerColumns;
    const inputs = picker.querySelectorAll('input'); inputs[0].value = pickerRows; inputs[1].value = pickerColumns;
    for (const button of picker.querySelectorAll('.table-grid button')) button.classList.toggle('active', +button.dataset.row <= pickerRows && +button.dataset.column <= pickerColumns);
  }
  function chooseTable(block) {
    insertion = { block, selection: captureSelection() }; closeMenu(); pickerRows = pickerColumns = 2; drawPicker();
    picker.hidden = false; tableTools.hidden = true; hideQuickAdds(); place(picker, block.getBoundingClientRect());
  }
  function insertTable() {
    if (!canEdit() || !owns(insertion?.block)) { picker.hidden = true; return; }
    restoreSelection(insertion.selection); picker.hidden = true;
    execute('table', { rows: pickerRows, columns: pickerColumns }); insertion = null;
  }
  for (let row = 1; row <= 6; row++) for (let column = 1; column <= 8; column++) {
    const button = document.createElement('button'); button.dataset.row = row; button.dataset.column = column;
    button.setAttribute('aria-label', t('%@ 行 %@ 列', row, column)); button.title = t('%@ 行 %@ 列', row, column);
    button.addEventListener('pointerenter', () => { pickerRows = row; pickerColumns = column; drawPicker(); });
    button.addEventListener('click', () => { pickerRows = row; pickerColumns = column; insertTable(); }); picker.querySelector('.table-grid').append(button);
  }
  picker.querySelector('.insert-table').addEventListener('click', insertTable);
  for (const [index, input] of [...picker.querySelectorAll('input')].entries()) input.addEventListener('change', () => { const value = Math.max(1, Math.min(index ? 12 : 30, +input.value || 1)); if (index) pickerColumns = value; else pickerRows = value; drawPicker(); });
  tableTools.addEventListener('mousedown', event => event.preventDefault());
  tableTools.addEventListener('click', event => { const action = event.target.closest('[data-table]')?.dataset.table; if (action) editTable(action); });
  picker.addEventListener('mousedown', event => { if (!event.target.matches('input')) event.preventDefault(); });
  function contentWidth(image) { const parent = image.parentElement, style = getComputedStyle(parent); return Math.max(1, parent.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)); }
  function positionImage() {
    if (!owns(selectedImage) || !canEdit()) { selectedImage = null; frame.hidden = imageTools.hidden = true; return; }
    const rect = selectedImage.getBoundingClientRect();
    frame.hidden = rect.bottom < 0 || rect.top > innerHeight;
    Object.assign(frame.style, { left: rect.left + 'px', top: rect.top + 'px', width: rect.width + 'px', height: rect.height + 'px' });
    imageTools.hidden = frame.hidden; if (!imageTools.hidden) place(imageTools, rect);
    imageTools.querySelector('output').textContent = Math.round(rect.width / contentWidth(selectedImage) * 100) + '%';
  }
  function selectImage(image) {
    selectedImage = image; tableTools.hidden = grip.hidden = true; hideQuickAdds();
    const range = document.createRange(); range.selectNode(image); getSelection().removeAllRanges(); getSelection().addRange(range); checkpoint(); positionImage();
  }
  function showPreview(image) {
    previewFocus = document.activeElement; preview.querySelector('img').src = image.src; preview.querySelector('img').alt = image.alt;
    preview.hidden = false; preview.querySelector('button').focus({ preventScroll: true });
  }
  function closePreview() { preview.hidden = true; preview.querySelector('img').removeAttribute('src'); previewFocus?.focus({ preventScroll: true }); }
  function captionImage(image) {
    let figure = image.closest('figure');
    if (!figure) {
      figure = document.createElement('figure');
      const paragraph = image.closest('p,h1,h2,h3,h4');
      if (paragraph) {
        const before = document.createRange(); before.selectNodeContents(paragraph); before.setEndBefore(image);
        const after = document.createRange(); after.selectNodeContents(paragraph); after.setStartAfter(image);
        const first = paragraph.cloneNode(false), last = paragraph.cloneNode(false); delete last.dataset.blockId;
        first.append(before.cloneContents()); last.append(after.cloneContents()); figure.append(image);
        paragraph.replaceWith(...(first.textContent || first.querySelector('img') ? [first] : []), figure, ...(last.textContent || last.querySelector('img') ? [last] : []));
      } else { image.replaceWith(figure); figure.append(image); }
    }
    let caption = figure.querySelector('figcaption');
    if (!caption) { caption = document.createElement('figcaption'); figure.append(caption); }
    focusBlock(caption, true); notify(); positionImage();
  }
  function completeImageReplacement(requestID, source) {
    const image = replacements.get(requestID); replacements.delete(requestID);
    if (!canEdit() || !owns(image) || !/^data:image\/(png|jpeg|gif|webp);base64,/i.test(source || '')) return false;
    checkpoint(); delete image.dataset.originalSrc; image.src = source; notify(); selectedImage = image; positionImage(); return true;
  }
  imageTools.addEventListener('mousedown', event => event.preventDefault());
  imageTools.addEventListener('click', event => {
    const action = event.target.closest('[data-image]')?.dataset.image; if (!action || !owns(selectedImage) || !canEdit()) return;
    const image = selectedImage;
    if (action === 'preview') { showPreview(image); return; }
    checkpoint();
    if (action === 'caption') captionImage(image);
    if (action === 'replace') { const requestID = uuid(); replacements.set(requestID, image); send({ type: 'chooseImage', requestID }); }
    if (action === 'delete') {
      const parent = image.closest('figure') || image.parentElement, target = image.closest('figure') || image;
      target.remove(); if (owns(parent) && !parent.childNodes.length) parent.innerHTML = parent === root ? '<p><br></p>' : '<br>';
      selectedImage = null; frame.hidden = imageTools.hidden = true; focusBlock(owns(parent) ? parent : root.firstElementChild); notify();
    }
  });
  preview.addEventListener('click', event => { if (event.target === preview || event.target.closest('button')) closePreview(); });
  function imageProgress(count, failed = false) {
    clearTimeout(progressTimer); progress.hidden = !count && !failed; progress.textContent = failed ? t('图片未能粘贴，请重试') : t('正在处理图片…');
    if (failed) progressTimer = setTimeout(() => { progress.hidden = true; }, 2500);
  }
  function beginDrag(event, data) { hoverTable.cancel(); checkpoint(); drag = data; hideQuickAdds(); event.preventDefault(); try { event.target.setPointerCapture(event.pointerId); } catch {} }
  grip.addEventListener('pointerdown', event => {
    if (!canEdit() || !owns(activeCell)) return;
    const table = activeCell.closest('table'), index = activeCell.cellIndex, width = table.getBoundingClientRect().width;
    if (index >= columns(table) - 1) return;
    const original = [...table.children].find(node => node.tagName === 'COLGROUP')?.cloneNode(true) || null;
    checkpoint(); const group = columnGroup(table), weights = [...group.children].map(col => parseFloat(col.style.width) || 100 / columns(table));
    const total = weights.reduce((sum, value) => sum + value, 0), values = weights.map(value => value / total * 100);
    [...group.children].forEach((col, offset) => { col.style.width = values[offset] + '%'; });
    beginDrag(event, { type: 'column', table, index, start: event.clientX, width, values, group, original });
  });
  frame.addEventListener('pointerdown', event => {
    const handle = event.target.closest('.image-resize'); if (!handle || !canEdit() || !owns(selectedImage)) return;
    beginDrag(event, { type: 'image', image: selectedImage, start: event.clientX, side: +handle.dataset.side, width: selectedImage.getBoundingClientRect().width, container: contentWidth(selectedImage), original: selectedImage.style.width });
  });
  const moveDrag = frameTask(event => {
    if (!drag) return;
    if (drag.type === 'image') { drag.image.style.width = Math.max(10, Math.min(100, (drag.width + (event.clientX - drag.start) * drag.side) / drag.container * 100)) + '%'; positionImage(); }
    else {
      const { index, values, group } = drag, sum = values[index] + values[index + 1], delta = (event.clientX - drag.start) / drag.width * 100;
      const next = Math.max(Math.min(8, sum / 3), Math.min(sum - Math.min(8, sum / 3), values[index] + delta));
      group.children[index].style.width = next + '%'; group.children[index + 1].style.width = sum - next + '%';
      grip.style.left = event.clientX - 4 + 'px';
    }
  });
  document.addEventListener('pointermove', event => { if (drag) moveDrag(event); }, { passive: true });
  function endDrag(cancel = false) {
    if (!drag) return;
    if (cancel) moveDrag.cancel(); else moveDrag.flush();
    if (cancel) {
      if (drag.type === 'image') drag.image.style.width = drag.original;
      else if (drag.original) drag.group.replaceWith(drag.original); else drag.group.remove();
    }
    drag = null; if (!cancel) notify(); positionImage();
  }
  document.addEventListener('pointerup', () => endDrag()); document.addEventListener('pointercancel', () => endDrag(true));
  const hoverTable = frameTask(event => {
    if (drag || !canEdit() || !owns(event.target)) return;
    if (event.buttons || !getSelection().isCollapsed) { tableTools.hidden = grip.hidden = true; hideQuickAdds(); return; }
    const cell = event.target.closest('td,th');
    if (cell) {
      if (cell !== activeCell || tableTools.hidden) showTable(cell);
      const rect = cell.getBoundingClientRect(), index = cell.cellIndex, siblings = cell.parentElement.cells;
      quickColumnCell = index < siblings.length - 1 && Math.abs(event.clientX - rect.right) < 14 ? cell
        : index > 0 && Math.abs(event.clientX - rect.left) < 14 ? siblings[index - 1] : null;
      if (quickColumnCell) {
        const label = t('在第 %@、%@ 列之间添加一列', quickColumnCell.cellIndex + 1, quickColumnCell.cellIndex + 2);
        columnAdd.title = label; columnAdd.setAttribute('aria-label', label);
      }
      positionQuickAdds();
      const edge = Math.abs(event.clientX - rect.right) < 7 && index < siblings.length - 1;
      grip.hidden = !edge || !!selectedImage;
      if (!grip.hidden) { activeCell = cell; Object.assign(grip.style, { left: rect.right - 4 + 'px', top: rect.top + 'px', height: rect.height + 'px' }); }
    } else { grip.hidden = true; scheduleTableHide(); }
  });
  root.addEventListener('pointermove', event => { if (!drag && canEdit() && (event.target.closest('td,th') || !tableTools.hidden || !grip.hidden || quickRowTable)) hoverTable(event); }, { passive: true });
  tableTools.addEventListener('pointerenter', () => clearTimeout(tableTimer));
  root.addEventListener('pointerleave', event => { hoverTable.cancel(); if (!tableControl(event.relatedTarget)) scheduleTableHide(); });
  for (const control of [tableTools, rowAdd, columnAdd, grip]) control.addEventListener('pointerleave', event => {
    if (!root.contains(event.relatedTarget) && !tableControl(event.relatedTarget)) scheduleTableHide();
  });
  root.addEventListener('click', event => {
    const image = event.target.closest('img');
    if (canEdit() && event.target.closest('figure[data-type=whiteboard]')) { selectedImage = null; frame.hidden = imageTools.hidden = true; return; }
    if (image) { event.preventDefault(); if (canEdit()) selectImage(image); else showPreview(image); }
    else { selectedImage = null; frame.hidden = imageTools.hidden = true; const cell = event.target.closest('td,th'); if (cell) showTable(cell); }
  });
  root.addEventListener('dblclick', event => { const image = event.target.closest('img'); if (image) { event.preventDefault(); showPreview(image); } });
  root.addEventListener('load', event => { if (event.target === selectedImage) positionImage(); }, true);
  root.addEventListener('input', frameTask(positionImage));
  const scheduleSelectionTools = frameTask(showQuickAdds);
  document.addEventListener('selectionchange', () => {
    const selection = getSelection();
    if (!selection.isCollapsed) { scheduleSelectionTools.cancel(); tableTools.hidden = true; hideQuickAdds(); return; }
    const element = selection.anchorNode?.nodeType === Node.ELEMENT_NODE ? selection.anchorNode : selection.anchorNode?.parentElement;
    const cell = element && root.contains(element) ? element.closest('td,th') : null;
    if (cell) scheduleSelectionTools(cell); else { scheduleSelectionTools.cancel(); hideQuickAdds(); }
  });
  root.addEventListener('beforeinput', event => {
    const selection = getSelection(), caption = selection?.anchorNode && (selection.anchorNode.nodeType === Node.ELEMENT_NODE ? selection.anchorNode : selection.anchorNode.parentElement).closest('figcaption');
    if (!canEdit() || event.inputType !== 'insertParagraph' || !caption) return;
    event.preventDefault(); event.stopImmediatePropagation(); checkpoint();
    const paragraph = document.createElement('p'); paragraph.innerHTML = '<br>'; caption.closest('figure').after(paragraph); focusBlock(paragraph);
    selectedImage = null; frame.hidden = imageTools.hidden = true; notify();
  }, true);
  document.addEventListener('keydown', event => {
    if (!preview.hidden) {
      if (event.key === 'Escape') { event.preventDefault(); closePreview(); }
      if (event.key === 'Tab') { event.preventDefault(); preview.querySelector('button').focus(); }
      return;
    }
    if (!picker.hidden) {
      if (event.key === 'Escape') { event.preventDefault(); picker.hidden = true; restoreSelection(insertion?.selection); insertion = null; }
      else if (event.key === 'Enter') { event.preventDefault(); event.stopPropagation(); insertTable(); }
      else if (event.key === 'Tab') event.stopPropagation();
      else if (!event.target.matches('input') && ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(event.key)) {
        event.preventDefault(); event.stopPropagation(); pickerRows = Math.max(1, Math.min(30, pickerRows + (event.key === 'ArrowDown' ? 1 : event.key === 'ArrowUp' ? -1 : 0)));
        pickerColumns = Math.max(1, Math.min(12, pickerColumns + (event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0))); drawPicker();
      }
    }
    else if (event.key === 'Escape' && selectedImage) { selectedImage = null; frame.hidden = imageTools.hidden = true; }
  }, true);
  document.addEventListener('pointerdown', event => {
    if (!picker.hidden && !picker.contains(event.target) && !document.getElementById('commands').contains(event.target)) { picker.hidden = true; insertion = null; }
    if (!root.contains(event.target) && !imageTools.contains(event.target) && !frame.contains(event.target) && !preview.contains(event.target)) { selectedImage = null; frame.hidden = imageTools.hidden = true; }
  });
  function position() { if (!tableTools.hidden && owns(activeCell)) place(tableTools, activeCell.closest('table').getBoundingClientRect(), 16); if (!picker.hidden && owns(insertion?.block)) place(picker, insertion.block.getBoundingClientRect()); positionImage(); positionQuickAdds(); if (!grip.hidden && owns(activeCell)) { const rect = activeCell.getBoundingClientRect(); Object.assign(grip.style, { left: rect.right - 4 + 'px', top: rect.top + 'px', height: rect.height + 'px' }); } }
  const schedulePosition = frameTask(position);
  window.addEventListener('scroll', schedulePosition, { passive: true }); window.addEventListener('resize', schedulePosition);
  new ResizeObserver(schedulePosition).observe(root);
  function reset() { hoverTable.cancel(); schedulePosition.cancel(); scheduleSelectionTools.cancel(); endDrag(true); picker.hidden = tableTools.hidden = imageTools.hidden = frame.hidden = grip.hidden = progress.hidden = true; hideQuickAdds(); if (!preview.hidden) closePreview(); activeCell = selectedImage = insertion = null; replacements.clear(); clearTimeout(tableTimer); clearTimeout(progressTimer); }
  return { chooseTable, appendRow, imageProgress, completeImageReplacement, reset };
}
