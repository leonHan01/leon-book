(() => {
  'use strict';
  const t = (...args) => window.LeonL10n.text(...args);
  window.LeonL10n.bindChrome(document);
  const $ = id => document.getElementById(id);
  const viewport = $('viewport'), world = $('world'), layer = $('nodes'), svg = $('edges');
  const post = (type, data = {}) => window.webkit?.messageHandlers.canvas.postMessage({ type, ...data });
  const clone = value => JSON.parse(JSON.stringify(value));
  const uid = () => crypto.randomUUID ? crypto.randomUUID() : Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join('');
  const colors = { '1': '#dd7886', '2': '#da9b62', '3': '#cfb95c', '4': '#65ad94', '5': '#6aaec8', '6': '#a48acf' };
  const colorOf = value => colors[value] || (/^#[0-9a-f]{6}$/i.test(value || '') ? value : '');
  const isEditing = target => !!target?.closest('input,textarea,select,[contenteditable=true]');
  const webURL = value => { try { const url = new URL(value); return /^https?:$/.test(url.protocol) ? url.href : null; } catch { return null; } };
  const mediaURL = (path, source = '') => `leoncanvas://media/resource?path=${encodeURIComponent(path)}&source=${encodeURIComponent(source)}`;
  let boardID = '', doc = { nodes: [], edges: [], leonbook: { title: '', viewport: { x: 80, y: 80, zoom: 1 } } };
  let selection = new Set(), selectedEdge = null, connecting = null, gesture = null, space = false;
  let undo = [], redo = [], frame = 0, libraryKind = 'article', queryTimer, titleEditing = false, busy = false;
  const elements = new Map(), contentCache = new Map(), requested = new Set(), activated = new Set();
  let v = doc.leonbook.viewport;
  function local(event) { const r = viewport.getBoundingClientRect(); return { x: event.clientX - r.left, y: event.clientY - r.top }; }
  function point(event) { const p = local(event); return { x: (p.x - v.x) / v.zoom, y: (p.y - v.y) / v.zoom }; }
  function center() { return { x: (viewport.clientWidth / 2 - v.x) / v.zoom, y: (viewport.clientHeight / 2 - v.y) / v.zoom }; }
  let statusKey = '本地工作区';
  function setStatus(key) { statusKey = key; $('status').textContent = t(key); }
  function toast(message) { $('toast').textContent = message; $('toast').hidden = false; clearTimeout(toast.timer); toast.timer = setTimeout(() => $('toast').hidden = true, 6500); }
  function setBusy(value) {
    busy = value;
    $('boards').disabled = value; $('new-board').disabled = value; $('start').disabled = value;
    $('viewport').style.pointerEvents = value ? 'none' : ''; $('library').style.pointerEvents = value ? 'none' : '';
    $('title').disabled = value || !boardID;
  }
  function checkpoint() {
    undo.push(JSON.stringify(doc));
    let size = undo.reduce((n, item) => n + item.length, 0);
    while (undo.length > 50 || size > 8 * 1024 * 1024) size -= undo.shift().length;
    redo = []; updateTools();
  }
  function save() {
    if (!boardID || busy) return;
    doc.leonbook.viewport = { ...v };
    setStatus('正在保存…');
    post('save', { id: boardID, document: JSON.stringify(doc) });
  }
  function change(action) { checkpoint(); action(); save(); render(); }
  function history(direction) {
    const source = direction < 0 ? undo : redo, target = direction < 0 ? redo : undo;
    if (!source.length) return;
    target.push(JSON.stringify(doc)); doc = JSON.parse(source.pop()); v = doc.leonbook.viewport;
    $('title').value = doc.leonbook.title;
    selection.clear(); selectedEdge = null; connecting = null;
    resetCards(); save(); render();
  }
  function resetCards() { elements.forEach(el => el.remove()); elements.clear(); requested.clear(); activated.clear(); }
  function scheduleRender() { if (!frame) frame = requestAnimationFrame(() => { frame = 0; render(); }); }
  function selectNode(id, additive = false) {
    if (!additive) selection.clear();
    if (additive && selection.has(id)) selection.delete(id); else selection.add(id);
    selectedEdge = null; render();
  }
  function addNode(fields, position) {
    if (!boardID || busy) return;
    if (doc.nodes.length >= 1500) { toast(t('每张画布最多 1,500 张卡片，请新建画布。')); return; }
    const p = position || center(), group = fields.type === 'group';
    const node = { id: uid(), x: Math.round(p.x - (group ? 330 : 180)), y: Math.round(p.y - (group ? 230 : 130)), width: group ? 660 : 360, height: group ? 460 : 300, ...fields };
    change(() => { group ? doc.nodes.unshift(node) : doc.nodes.push(node); selection = new Set([node.id]); selectedEdge = null; });
    if (node.type === 'text' && !node.leonbook) elements.get(node.id)?.querySelector('textarea')?.focus();
    return node;
  }
  function removeSelection() {
    if (!selection.size && !selectedEdge) return;
    change(() => {
      doc.nodes = doc.nodes.filter(node => !selection.has(node.id));
      doc.edges = doc.edges.filter(edge => edge.id !== selectedEdge && !selection.has(edge.fromNode) && !selection.has(edge.toNode));
      selection.clear(); selectedEdge = null; connecting = null;
    });
  }
  function duplicate() {
    if (!selection.size || doc.nodes.length + selection.size > 1500) return;
    change(() => {
      const remap = new Map(), copies = doc.nodes.filter(node => selection.has(node.id)).map(node => {
        const copy = clone(node); copy.id = uid(); copy.x += 35; copy.y += 35; remap.set(node.id, copy.id); return copy;
      });
      const edges = doc.edges.filter(edge => remap.has(edge.fromNode) && remap.has(edge.toNode)).map(edge => ({ ...edge, id: uid(), fromNode: remap.get(edge.fromNode), toNode: remap.get(edge.toNode) }));
      doc.nodes.push(...copies); doc.edges.push(...edges); selection = new Set(copies.map(node => node.id));
    });
  }
  function connect(from, to, fromSide = 'right', toSide = 'left') {
    if (from === to || doc.edges.length >= 5000) return;
    if (doc.edges.some(edge => edge.fromNode === from && edge.toNode === to && edge.fromSide === fromSide && edge.toSide === toSide)) return;
    change(() => doc.edges.push({ id: uid(), fromNode: from, toNode: to, fromSide, toSide, toEnd: 'arrow' }));
  }
  function zoomTo(zoom, anchor = { x: viewport.clientWidth / 2, y: viewport.clientHeight / 2 }) {
    const next = Math.min(3, Math.max(.1, zoom));
    v.x = anchor.x - (anchor.x - v.x) / v.zoom * next; v.y = anchor.y - (anchor.y - v.y) / v.zoom * next; v.zoom = next;
    scheduleRender();
  }
  function fit() {
    if (!doc.nodes.length) { v = { x: 80, y: 80, zoom: 1 }; }
    else {
      const minX = Math.min(...doc.nodes.map(n => n.x)), minY = Math.min(...doc.nodes.map(n => n.y));
      const maxX = Math.max(...doc.nodes.map(n => n.x + n.width)), maxY = Math.max(...doc.nodes.map(n => n.y + n.height));
      v.zoom = Math.max(.1, Math.min(1.2, (viewport.clientWidth - 120) / (maxX - minX), (viewport.clientHeight - 200) / (maxY - minY)));
      v.x = viewport.clientWidth / 2 - (minX + maxX) / 2 * v.zoom; v.y = viewport.clientHeight / 2 + 20 - (minY + maxY) / 2 * v.zoom;
    }
    render(); save();
  }
  function updateTools() {
    $('undo').disabled = !undo.length; $('redo').disabled = !redo.length;
    $('selection-tools').hidden = !selection.size && !selectedEdge;
    const edge = doc.edges.find(e => e.id === selectedEdge), node = selection.size === 1 ? doc.nodes.find(n => selection.has(n.id)) : null;
    $('selection-label').textContent = edge ? t('连线') : t('%@ 张卡片', selection.size);
    $('label').hidden = !edge && node?.type !== 'group';
    if (document.activeElement !== $('label')) $('label').value = edge?.label || node?.label || '';
    $('color').value = (edge || node)?.color || '';
    $('connect').hidden = !node || node.type === 'group'; $('duplicate').hidden = !!edge;
  }
  function render() {
    world.style.transform = `translate(${v.x}px,${v.y}px) scale(${v.zoom})`;
    viewport.style.backgroundSize = `${24 * v.zoom}px ${24 * v.zoom}px`;
    viewport.style.backgroundPosition = `${v.x}px ${v.y}px`;
    viewport.classList.toggle('connecting', !!connecting);
    $('zoom-reset').textContent = `${Math.round(v.zoom * 100)}%`;
    $('empty-hint').hidden = !boardID || !!doc.nodes.length;
    const left = (-v.x - 180) / v.zoom, top = (-v.y - 180) / v.zoom;
    const right = (viewport.clientWidth - v.x + 180) / v.zoom, bottom = (viewport.clientHeight - v.y + 180) / v.zoom;
    const visible = new Set();
    for (const [index, node] of doc.nodes.entries()) {
      const focused = elements.get(node.id)?.contains(document.activeElement);
      if (!focused && (node.x + node.width < left || node.y + node.height < top || node.x > right || node.y > bottom)) continue;
      visible.add(node.id);
      let el = elements.get(node.id);
      if (!el) { el = makeCard(node); elements.set(node.id, el); }
      el.style.left = node.x + 'px'; el.style.top = node.y + 'px'; el.style.width = node.width + 'px'; el.style.height = node.height + 'px';
      el.style.setProperty('--node-color', colorOf(node.color) || 'var(--border)');
      el.classList.toggle('selected', selection.has(node.id));
      if (node.type === 'group') el.querySelector('.card-title').textContent = node.label || t('未命名分组');
      if (!el.isConnected) layer.append(el);
      el.style.zIndex = index;
    }
    for (const [id, el] of elements) if (!visible.has(id)) { el.remove(); elements.delete(id); activated.delete(id); }
    renderEdges(); updateTools();
  }
  function svgElement(tag, attributes = {}) {
    const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const [name, value] of Object.entries(attributes)) el.setAttribute(name, value);
    return el;
  }
  function anchor(node, side) {
    if (side === 'top') return { x: node.x + node.width / 2, y: node.y, dx: 0, dy: -1 };
    if (side === 'bottom') return { x: node.x + node.width / 2, y: node.y + node.height, dx: 0, dy: 1 };
    if (side === 'left') return { x: node.x, y: node.y + node.height / 2, dx: -1, dy: 0 };
    return { x: node.x + node.width, y: node.y + node.height / 2, dx: 1, dy: 0 };
  }
  function curve(a, b) {
    const distance = Math.max(45, Math.min(260, Math.hypot(a.x - b.x, a.y - b.y) * .45));
    return `M${a.x},${a.y} C${a.x + a.dx * distance},${a.y + a.dy * distance} ${b.x + b.dx * distance},${b.y + b.dy * distance} ${b.x},${b.y}`;
  }
  function renderEdges() {
    svg.replaceChildren();
    const defs = svgElement('defs'), marker = svgElement('marker', { id: 'arrow', viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' });
    marker.append(svgElement('path', { d: 'M0,0 L10,5 L0,10 z', fill: 'context-stroke' })); defs.append(marker); svg.append(defs);
    const byID = new Map(doc.nodes.map(node => [node.id, node]));
    for (const edge of doc.edges) {
      const from = byID.get(edge.fromNode), to = byID.get(edge.toNode); if (!from || !to) continue;
      const a = anchor(from, edge.fromSide || 'right'), b = anchor(to, edge.toSide || 'left'), d = curve(a, b);
      if (Math.max(a.x,b.x) < (-v.x-300)/v.zoom || Math.min(a.x,b.x) > (viewport.clientWidth-v.x+300)/v.zoom || Math.max(a.y,b.y) < (-v.y-300)/v.zoom || Math.min(a.y,b.y) > (viewport.clientHeight-v.y+300)/v.zoom) continue;
      const stroke = edge.id === selectedEdge ? '#7d8aeb' : colorOf(edge.color) || '#9ba8bc';
      const path = svgElement('path', { d, fill: 'none', stroke, 'stroke-width': edge.id === selectedEdge ? 3 : 2 });
      if (edge.toEnd !== 'none') path.setAttribute('marker-end', 'url(#arrow)');
      if (edge.fromEnd === 'arrow') path.setAttribute('marker-start', 'url(#arrow)');
      const hit = svgElement('path', { d, class: 'edge-hit', 'data-edge': edge.id }); svg.append(path, hit);
      if (edge.label) { const label = svgElement('text', { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 8, 'text-anchor': 'middle', 'data-edge': edge.id }); label.textContent = edge.label; svg.append(label); }
    }
    if (connecting) {
      const from = byID.get(connecting.id);
      if (from) { const a = anchor(from, connecting.side), b = connecting.point || { x: a.x + 80, y: a.y, dx: -a.dx, dy: -a.dy }; svg.append(svgElement('path', { d: curve(a, b), fill: 'none', stroke: '#7d8aeb', 'stroke-width': 2, 'stroke-dasharray': '6 5' })); }
    }
  }
  function button(label, action, title) {
    const el = document.createElement('button');
    const icons = {
      external: '<path d="M13 3h8v8M21 3 11 13M9 5H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4"/>',
      refresh: '<path d="M20 7v5h-5M20 12a8 8 0 1 0-2 6"/>',
    };
    if (icons[label]) {
      el.innerHTML = '<svg class="app-icon" viewBox="0 0 24 24" aria-hidden="true">' + icons[label] + '</svg>';
      el.setAttribute('aria-label', title);
    } else el.textContent = label;
    if (title) el.title = title;
    el.addEventListener('click', event => { event.stopPropagation(); action(event); }); return el;
  }
  function placeholder(body, title, message) {
    body.replaceChildren(); const wrap = document.createElement('div'); wrap.className = 'placeholder';
    const strong = document.createElement('strong'); strong.textContent = title;
    const detail = document.createElement('div'); detail.textContent = message; wrap.append(strong, detail); body.append(wrap); return wrap;
  }
  function makeCard(node) {
    const el = document.createElement('article'); el.className = 'card' + (node.type === 'group' ? ' group' : ''); el.dataset.id = node.id;
    const header = document.createElement('div'); header.className = 'card-header';
    const kind = document.createElement('span'); kind.className = 'card-type';
    kind.textContent = node.leonbook?.kind === 'article' ? t('文章') : node.leonbook?.kind === 'moment' ? t('微博') : ({ text: t('便签'), link: t('网页'), file: t('文件'), group: t('分组') })[node.type];
    const title = document.createElement('span'); title.className = 'card-title';
    title.textContent = contentCache.get(node.id)?.title || node.leonbook?.title || node.label || (node.type === 'link' ? new URL(node.url).hostname : node.file?.split('/').pop() || t('便签'));
    header.append(kind, title);
    if (node.leonbook?.kind === 'article') header.append(button('external', () => post('openArticle', { slug: node.leonbook.id }), t('打开原文')));
    else if (node.type === 'link') header.append(button('external', () => post('external', { url: node.url }), t('在浏览器中打开')));
    else if (node.type === 'file') header.append(button('external', () => post('openFile', { path: node.file }), t('在 Finder 中显示')));
    if (node.type === 'file' || node.leonbook) header.append(button('refresh', () => { requested.delete(node.id); contentCache.delete(node.id); fillBody(node, body); }, t('刷新原内容')));
    el.append(header);
    const body = document.createElement('div'); body.className = 'card-body'; el.append(body);
    if (node.type === 'group') body.style.pointerEvents = 'none';
    else fillBody(node, body);
    if (node.type !== 'group') for (const side of ['top', 'right', 'bottom', 'left']) {
      const port = document.createElement('button'); port.className = 'port'; port.dataset.side = side; port.title = t('拖动或点击，连接到另一张卡片'); port.setAttribute('aria-label', t('从%@侧连线', t(side))); el.append(port);
    }
    const resize = document.createElement('div'); resize.className = 'resize'; resize.title = t('拖动调整大小'); el.append(resize);
    return el;
  }
  function fillBody(node, body) {
    body.className = 'card-body'; body.replaceChildren();
    if (node.type === 'text' && !node.leonbook) {
      body.classList.add('note'); const textarea = document.createElement('textarea'); textarea.value = node.text || ''; textarea.placeholder = t('写下想法…'); textarea.setAttribute('aria-label', t('便签内容'));
      let editingStarted = false;
      textarea.addEventListener('focus', () => { editingStarted = false; selection = new Set([node.id]); selectedEdge = null; scheduleRender(); });
      textarea.addEventListener('input', () => { const live = doc.nodes.find(n => n.id === node.id); if (live) { if (!editingStarted) { checkpoint(); editingStarted = true; } live.text = textarea.value; save(); } });
      body.append(textarea); return;
    }
    if (node.type === 'link') {
      const wrap = placeholder(body, new URL(node.url).hostname, node.url);
      wrap.append(button(t('在画布中加载网页'), () => {
        activated.add(node.id); body.classList.add('embed'); body.replaceChildren(); const iframe = document.createElement('iframe');
        iframe.title = node.url; iframe.sandbox = 'allow-scripts allow-forms allow-same-origin'; iframe.referrerPolicy = 'no-referrer'; iframe.src = node.url; body.append(iframe);
        toast(t('如网页留白或拒绝嵌入，可点击卡片右上角在浏览器中打开。'));
      })); return;
    }
    const content = contentCache.get(node.id);
    if (!content) {
      placeholder(body, t('正在读取内容…'), '');
      if (!requested.has(node.id)) { requested.add(node.id); post('content', { id: boardID, nodeID: node.id }); }
      return;
    }
    if (content.error) { placeholder(body, t('内容暂不可用'), content.error); return; }
    if (content.kind === 'article') { body.append(sanitizedArticle(content.html, content.source)); return; }
    if (content.kind === 'moment') {
      const text = document.createElement('div'); text.style.whiteSpace = 'pre-wrap'; text.textContent = content.text; body.append(text);
      for (const media of content.media || []) appendMedia(body, media.kind, media.path, media.name);
      return;
    }
    if (['image', 'video', 'audio'].includes(content.kind)) { body.classList.add('media'); appendMedia(body, content.kind, content.path, content.title); return; }
    if (content.kind === 'pdf') {
      const wrap = placeholder(body, t('PDF 文档'), content.title);
      wrap.append(button(t('在画布中预览 PDF'), () => { body.classList.add('embed'); body.replaceChildren(); const iframe = document.createElement('iframe'); iframe.title = content.title; iframe.sandbox = ''; iframe.src = mediaURL(content.path); body.append(iframe); })); return;
    }
    const wrap = placeholder(body, t('文件附件'), content.title);
    wrap.append(button(t('在 Finder 中显示'), () => post('openFile', { path: content.path })));
  }
  function appendMedia(body, kind, path, name) {
    const tag = kind === 'image' ? 'img' : kind === 'video' ? 'video' : kind === 'audio' ? 'audio' : null;
    if (!tag) return;
    const media = document.createElement(tag); media.src = mediaURL(path); media.title = name || '';
    if (tag === 'img') { media.alt = name || t('图片'); media.loading = 'lazy'; }
    else { media.controls = true; media.preload = 'none'; }
    media.addEventListener('error', () => { const error = document.createElement('p'); error.textContent = t('媒体无法预览，请从卡片右上角打开原文件。'); error.className = 'placeholder'; media.replaceWith(error); }, { once: true });
    body.append(media);
  }
  function sanitizedArticle(html, source) {
    // Rebuild only semantic tags. Source HTML never gets inserted into the live DOM.
    const parsed = new DOMParser().parseFromString(html || '', 'text/html'), output = document.createDocumentFragment();
    const allowed = new Set('ARTICLE SECTION DIV P BR H1 H2 H3 H4 H5 H6 STRONG EM B I U S DEL MARK SPAN PRE CODE BLOCKQUOTE ASIDE UL OL LI TABLE THEAD TBODY TFOOT TR TD TH HR FIGURE FIGCAPTION IMG A'.split(' '));
    const blocked = new Set('SCRIPT STYLE IFRAME OBJECT EMBED FORM INPUT BUTTON TEXTAREA SELECT SVG MATH META LINK BASE TEMPLATE'.split(' '));
    function copy(node, parent) {
      if (node.nodeType === 3) { parent.append(document.createTextNode(node.textContent)); return; }
      if (node.nodeType !== 1 || blocked.has(node.tagName)) return;
      if (!allowed.has(node.tagName)) { for (const child of node.childNodes) copy(child, parent); return; }
      const el = document.createElement(node.tagName.toLowerCase());
      if (node.tagName === 'IMG') {
        const src = node.getAttribute('src') || '';
        el.src = webURL(src) || (/^data:image\/(png|jpeg|gif|webp);base64,/i.test(src) ? src : mediaURL(src, source));
        el.alt = node.getAttribute('alt') || ''; el.loading = 'lazy';
      }
      if (node.tagName === 'A') {
        const href = webURL(node.getAttribute('href') || '');
        if (href) { el.href = href; el.addEventListener('click', event => { event.preventDefault(); post('external', { url: href }); }); }
      }
      for (const attr of ['colspan', 'rowspan']) if (/^[1-9][0-9]?$/.test(node.getAttribute(attr) || '')) el.setAttribute(attr, node.getAttribute(attr));
      for (const child of node.childNodes) copy(child, el);
      parent.append(el);
    }
    for (const node of parsed.body.childNodes) copy(node, output);
    return output;
  }
  viewport.addEventListener('pointerdown', event => {
    if (!boardID || event.target.closest('nav,#navigation,#selection-tools,#toast,#welcome')) return;
    const card = event.target.closest('.card'), port = event.target.closest('.port');
    const edge = event.target.closest('[data-edge]');
    if (edge) { selection.clear(); selectedEdge = edge.dataset.edge; render(); return; }
    if (connecting && card && !port && connecting.id !== card.dataset.id) {
      connect(connecting.id, card.dataset.id, connecting.side); connecting = null; render(); return;
    }
    const p = point(event), l = local(event);
    if (port) {
      event.preventDefault(); connecting = { id: card.dataset.id, side: port.dataset.side }; gesture = { mode: 'connect' };
    } else if (space || event.button === 1 || (!card && event.button === 0 && !event.target.closest('button,input,textarea,select'))) {
      event.preventDefault();
      if (event.shiftKey) { gesture = { mode: 'marquee', start: p, local: l }; selection.clear(); selectedEdge = null; }
      else { gesture = { mode: 'pan', start: l, x: v.x, y: v.y, moved: false }; viewport.classList.add('panning'); }
    } else if (card) {
      if (event.target.closest('button,input,textarea,video,audio,iframe,a')) return;
      const node = doc.nodes.find(n => n.id === card.dataset.id); if (!node) return;
      if (event.target.closest('.resize')) { gesture = { mode: 'resize', node, start: p, width: node.width, height: node.height }; }
      else if (event.target.closest('.card-header')) {
        event.preventDefault();
        if (!selection.has(node.id) || event.shiftKey) selectNode(node.id, event.shiftKey);
        if (!selection.has(node.id)) return;
        const moving = doc.nodes.filter(n => selection.has(n.id) || (node.type === 'group' && n.x >= node.x && n.y >= node.y && n.x + n.width <= node.x + node.width && n.y + n.height <= node.y + node.height));
        gesture = { mode: 'move', start: p, originals: moving.map(n => ({ node: n, x: n.x, y: n.y })) };
      } else { selectNode(node.id, event.shiftKey); return; }
    } else return;
    viewport.setPointerCapture(event.pointerId);
  });
  viewport.addEventListener('pointermove', event => {
    const p = point(event);
    if (connecting) { connecting.point = { ...p, dx: -1, dy: 0 }; scheduleRender(); }
    if (!gesture) return;
    if (['move', 'resize'].includes(gesture.mode) && !gesture.changed) {
      if (Math.abs(p.x - gesture.start.x) + Math.abs(p.y - gesture.start.y) < 2) return;
      checkpoint(); gesture.changed = true;
    }
    if (gesture.mode === 'pan') { const l = local(event); const dx = l.x - gesture.start.x, dy = l.y - gesture.start.y; gesture.moved ||= Math.abs(dx) + Math.abs(dy) > 3; v.x = gesture.x + dx; v.y = gesture.y + dy; }
    if (gesture.mode === 'move') for (const item of gesture.originals) { item.node.x = Math.round(Math.max(-1e7, Math.min(1e7, item.x + p.x - gesture.start.x))); item.node.y = Math.round(Math.max(-1e7, Math.min(1e7, item.y + p.y - gesture.start.y))); }
    if (gesture.mode === 'resize') { gesture.node.width = Math.round(Math.max(200, Math.min(20000, gesture.width + p.x - gesture.start.x))); gesture.node.height = Math.round(Math.max(140, Math.min(20000, gesture.height + p.y - gesture.start.y))); }
    if (gesture.mode === 'marquee') {
      const l = local(event), rect = $('marquee'); rect.hidden = false;
      rect.style.left = Math.min(l.x, gesture.local.x) + 'px'; rect.style.top = Math.min(l.y, gesture.local.y) + 'px'; rect.style.width = Math.abs(l.x - gesture.local.x) + 'px'; rect.style.height = Math.abs(l.y - gesture.local.y) + 'px';
      selection = new Set(doc.nodes.filter(n => n.x >= Math.min(p.x, gesture.start.x) && n.y >= Math.min(p.y, gesture.start.y) && n.x + n.width <= Math.max(p.x, gesture.start.x) && n.y + n.height <= Math.max(p.y, gesture.start.y)).map(n => n.id));
    }
    scheduleRender();
  });
  function endGesture(event) {
    if (!gesture) return;
    if (gesture.mode === 'connect') {
      const target = document.elementFromPoint(event.clientX, event.clientY), card = target?.closest('.card');
      if (card && connecting && card.dataset.id !== connecting.id) { connect(connecting.id, card.dataset.id, connecting.side, target.closest('.port')?.dataset.side || 'left'); connecting = null; }
    } else if (gesture.mode === 'pan' && !gesture.moved) { selection.clear(); selectedEdge = null; connecting = null; }
    if (['move', 'resize', 'pan'].includes(gesture.mode)) save();
    gesture = null; $('marquee').hidden = true; viewport.classList.remove('panning'); render();
    if (viewport.hasPointerCapture(event.pointerId)) viewport.releasePointerCapture(event.pointerId);
  }
  viewport.addEventListener('pointerup', endGesture);
  viewport.addEventListener('pointercancel', endGesture);
  viewport.addEventListener('dblclick', event => {
    if (boardID && !event.target.closest('.card,button,nav,#navigation,#selection-tools,#welcome')) addNode({ type: 'text', text: '' }, point(event));
  });
  let wheelTimer;
  viewport.addEventListener('wheel', event => {
    if (!boardID || event.target.closest('#tools,#navigation,#selection-tools')) return;
    if (!event.ctrlKey && !event.metaKey && event.target.closest('.card-body')) return;
    event.preventDefault();
    if (event.ctrlKey || event.metaKey) zoomTo(v.zoom * Math.exp(-event.deltaY * .007), local(event));
    else { v.x -= event.deltaX; v.y -= event.deltaY; scheduleRender(); }
    clearTimeout(wheelTimer); wheelTimer = setTimeout(save, 180);
  }, { passive: false });
  let pinchZoom = 1;
  viewport.addEventListener('gesturestart', event => { event.preventDefault(); pinchZoom = v.zoom; }, { passive: false });
  viewport.addEventListener('gesturechange', event => { event.preventDefault(); zoomTo(pinchZoom * event.scale, local(event)); }, { passive: false });
  viewport.addEventListener('gestureend', event => { event.preventDefault(); save(); }, { passive: false });
  document.addEventListener('keydown', event => {
    if (!boardID || busy || isEditing(event.target) || $('url-dialog').open) return;
    const cmd = event.metaKey || event.ctrlKey, key = event.key.toLowerCase();
    if (key === ' ') { event.preventDefault(); space = true; }
    else if (key === 'escape') { connecting = null; selection.clear(); selectedEdge = null; render(); }
    else if (key === 'delete' || key === 'backspace') { event.preventDefault(); removeSelection(); }
    else if (cmd && key === 'z') { event.preventDefault(); history(event.shiftKey ? 1 : -1); }
    else if (cmd && key === 'd') { event.preventDefault(); duplicate(); }
    else if (cmd && key === 'a') { event.preventDefault(); selection = new Set(doc.nodes.map(n => n.id)); selectedEdge = null; render(); }
    else if (cmd && key === 's') { event.preventDefault(); save(); }
    else if (cmd && ['+', '=', '-'].includes(key)) { event.preventDefault(); zoomTo(v.zoom * (key === '-' ? .8 : 1.25)); save(); }
    else if (!cmd && key === 'f') fit();
    else if (!cmd && key === 'n') addNode({ type: 'text', text: '' });
    else if (!cmd && key === 'g') addNode({ type: 'group', label: t('新分组'), color: '6' });
    else if (!cmd && key === 'l') showURL();
  });
  document.addEventListener('keyup', event => { if (event.key === ' ') space = false; });
  window.addEventListener('blur', () => { space = false; if (boardID) save(); });
  document.addEventListener('paste', event => {
    if (!boardID || isEditing(event.target) || $('url-dialog').open) return;
    const text = event.clipboardData.getData('text/plain'); if (!text) return;
    event.preventDefault(); const url = webURL(text.trim()); addNode(url ? { type: 'link', url } : { type: 'text', text });
  });
  viewport.addEventListener('dragover', event => { if (boardID) event.preventDefault(); });
  viewport.addEventListener('drop', event => {
    if (!boardID) return; event.preventDefault();
    if (event.dataTransfer.files.length) { toast(t('请点击“文件”，选择要加入画布的本地素材。')); return; }
    const text = event.dataTransfer.getData('text/uri-list').split('\n').find(line => line && !line.startsWith('#')) || event.dataTransfer.getData('text/plain');
    if (text) { const url = webURL(text.trim()); addNode(url ? { type: 'link', url } : { type: 'text', text }, point(event)); }
  });
  function showURL() { $('url-input').value = ''; $('url-dialog').showModal(); $('url-input').focus(); }
  function requestLibrary() { $('results').textContent = t('正在搜索…'); post('library', { kind: libraryKind, query: $('search').value }); }
  $('new-board').onclick = $('start').onclick = () => { save(); setBusy(true); post('create'); };
  $('boards').onchange = () => { if ($('boards').value) { save(); setBusy(true); post('open', { id: $('boards').value }); } };
  $('title').onfocus = () => { if (!titleEditing) checkpoint(); titleEditing = true; };
  $('title').oninput = () => { doc.leonbook.title = $('title').value || t('未命名画布'); save(); };
  $('title').onblur = () => titleEditing = false;
  for (const name of ['import', 'export']) $(name).onclick = () => { document.querySelector('.more').open = false; save(); post(name); };
  $('delete-board').onclick = () => { document.querySelector('.more').open = false; save(); post('delete'); };
  $('retry').onclick = () => post('retry');
  $('show-library').onclick = () => { $('library').hidden = !$('library').hidden; if (!$('library').hidden) requestLibrary(); };
  $('close-library').onclick = () => $('library').hidden = true;
  document.querySelectorAll('[data-kind]').forEach(el => el.onclick = () => { libraryKind = el.dataset.kind; document.querySelectorAll('[data-kind]').forEach(b => b.classList.toggle('active', b === el)); requestLibrary(); });
  $('search').oninput = () => { clearTimeout(queryTimer); queryTimer = setTimeout(requestLibrary, 180); };
  $('note').onclick = () => addNode({ type: 'text', text: '' }); $('link').onclick = showURL;
  $('file').onclick = () => post('attachment'); $('group').onclick = () => addNode({ type: 'group', label: t('新分组'), color: '6' });
  $('undo').onclick = () => history(-1); $('redo').onclick = () => history(1);
  $('remove').onclick = removeSelection; $('duplicate').onclick = duplicate;
  $('connect').onclick = () => { connecting = { id: [...selection][0], side: 'right' }; toast(t('点击另一张卡片完成连线，Escape 取消。')); render(); };
  $('color').onchange = () => change(() => { for (const node of doc.nodes) if (selection.has(node.id)) node.color = $('color').value; const edge = doc.edges.find(e => e.id === selectedEdge); if (edge) edge.color = $('color').value; });
  $('label').onfocus = checkpoint;
  $('label').oninput = () => { const item = doc.edges.find(e => e.id === selectedEdge) || doc.nodes.find(n => selection.has(n.id)); if (item) { item.label = $('label').value; save(); render(); } };
  $('zoom-out').onclick = () => { zoomTo(v.zoom * .8); save(); }; $('zoom-in').onclick = () => { zoomTo(v.zoom * 1.25); save(); };
  $('zoom-reset').onclick = () => { zoomTo(1); save(); }; $('fit').onclick = fit;
  $('cancel-url').onclick = () => $('url-dialog').close();
  $('url-form').onsubmit = event => { event.preventDefault(); const url = webURL($('url-input').value); if (url) { addNode({ type: 'link', url, width: 460, height: 380 }); $('url-dialog').close(); } };
  new ResizeObserver(scheduleRender).observe(viewport);
  window.LeonCanvas = {
    receive(action, payload) {
      if (action === 'catalog') {
        $('boards').replaceChildren();
        if (!payload.items.length) $('boards').add(new Option(t('尚无画布'), ''));
        for (const item of payload.items) $('boards').add(new Option(item.title, item.id));
        $('boards').value = boardID;
      } else if (action === 'load') {
        boardID = payload.id; doc = JSON.parse(payload.document); v = doc.leonbook.viewport;
        selection.clear(); selectedEdge = null; connecting = null; gesture = null; undo = []; redo = []; titleEditing = false;
        setBusy(false); contentCache.clear(); resetCards(); $('boards').value = boardID; $('title').value = doc.leonbook.title; $('title').disabled = false;
        $('welcome').hidden = true; for (const id of ['tools', 'navigation', 'hint']) $(id).hidden = false;
        setStatus('已保存到本地'); $('retry').hidden = true; render();
      } else if (action === 'empty') {
        boardID = ''; doc.nodes = []; doc.edges = []; selection.clear(); selectedEdge = null; resetCards(); render(); $('welcome').hidden = false;
        for (const id of ['tools', 'navigation', 'hint', 'selection-tools', 'library']) $(id).hidden = true;
        $('title').value = ''; $('title').disabled = true; setStatus('本地工作区');
      } else if (action === 'saved') {
        if (payload.forked) { boardID = payload.id; doc.leonbook.title = payload.title; $('title').value = payload.title; toast(t('检测到其他窗口的修改，已将本次内容另存为冲突副本。')); }
        if (payload.id !== boardID) return;
        const option = [...$('boards').options].find(o => o.value === boardID); if (option) option.textContent = doc.leonbook.title;
        setStatus(payload.pending ? '正在保存…' : '已保存到本地'); $('retry').hidden = true;
      } else if (action === 'library') {
        if (payload.kind !== libraryKind || payload.query !== $('search').value) return;
        $('results').replaceChildren();
        if (!payload.items.length) $('results').textContent = t('没有匹配的内容');
        for (const item of payload.items) {
          const el = button('', () => {
            const ref = { kind: item.kind, id: item.id, title: item.title || t('微博') };
            addNode(item.kind === 'article' ? { type: 'file', file: item.file, leonbook: ref, width: 400, height: 440 } : { type: 'text', text: '', leonbook: ref, height: 340 });
          });
          el.className = 'result'; const title = document.createElement('strong'); title.textContent = item.title || t('微博'); const subtitle = document.createElement('span'); subtitle.textContent = item.subtitle; el.append(title, subtitle); $('results').append(el);
        }
      } else if (action === 'content') {
        if (payload.id !== boardID || !doc.nodes.some(n => n.id === payload.nodeID)) return;
        contentCache.delete(payload.nodeID); contentCache.set(payload.nodeID, payload);
        let size = [...contentCache.values()].reduce((total, item) => total + (item.html?.length || 0) + (item.text?.length || 0), 0);
        while (contentCache.size > 64 || (size > 6 * 1024 * 1024 && contentCache.size > 1)) {
          const key = contentCache.keys().next().value, old = contentCache.get(key);
          size -= (old.html?.length || 0) + (old.text?.length || 0); contentCache.delete(key); requested.delete(key);
        }
        const node = doc.nodes.find(n => n.id === payload.nodeID), el = elements.get(payload.nodeID);
        if (el) { if (payload.title) el.querySelector('.card-title').textContent = payload.title; fillBody(node, el.querySelector('.card-body')); }
      } else if (action === 'addFile') {
        if (payload.id === boardID) addNode({ type: 'file', file: payload.file, leonbook: { kind: 'attachment', id: payload.file, title: payload.title }, width: 420, height: 340 });
      } else if (action === 'error') { setBusy(false); setStatus('操作未完成'); $('retry').hidden = false; $('boards').value = boardID; toast(payload.message); }
    },
    // Small deterministic surface also used by the headless WebKit checks.
    snapshot: () => clone(doc), addNode, connect, fit,
    state: () => ({ id: boardID, visibleCards: elements.size, selection: [...selection] })
  };
  window.addEventListener('leonlanguagechange', () => { resetCards(); render(); setStatus(statusKey); });
  post('ready');
})();
