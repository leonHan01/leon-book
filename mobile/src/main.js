import { App } from '@capacitor/app';
import { Capacitor } from '@capacitor/core';
import DOMPurify from 'dompurify';
import './style.css';
import { mediaPath, recordAttachments, uploadName } from '../shared/attachments.js';
import { clearAttachmentCache, loadState, saveState } from './storage.js';
import { attachmentCard, cacheUploadedAttachments, pendingAttachmentCard } from './attachments.js';
import { emptyState, keyOf, lookup, pairDevice, parsePairing, request, resolveEdit, SyncEngine } from './sync.js';
import { completeTodo, editableFields, saveEditor, uuid, validateUploadSelection } from './editor.js';

const root = document.querySelector('#app');
const labels = { articles: '文章', moments: '微博', todos: '待办' };
let state, active = 'articles', query = '', busy = false, notice = '';
let modal, modalDismiss;
let foreground = !document.hidden, autoRequested = false, autoTimer, nextAutoAt = 0;

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else if (value === true) node.setAttribute(key, '');
    else if (value !== undefined && value !== null && value !== false) node.setAttribute(key, value);
  }
  node.append(...children.flat());
  return node;
}

const button = (label, click, opts = {}) => el('button', { type: 'button', onclick: click, ...opts }, label);
const dateLabel = value => value && Number.isFinite(new Date(value).getTime())
  ? new Intl.DateTimeFormat('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(value))
  : '';
const operation = (kind, item) => state.outbox.find(op => op.kind === kind && op.key === keyOf(kind, item));

async function commit(next, options) { await saveState(next, options); state = next; }

function articleBody(item, renderAttachment) {
  const fields = editableFields('articles', item);
  const body = el('div', { class: 'article-body' });
  if (fields.format === 'html') {
    const fragment = DOMPurify.sanitize(fields.body, {
      RETURN_DOM_FRAGMENT: true,
      ALLOWED_TAGS: ['article', 'section', 'div', 'span', 'p', 'br', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
        'blockquote', 'ul', 'ol', 'li', 'pre', 'code', 'strong', 'b', 'em', 'i', 's', 'u', 'mark',
        'hr', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'a', 'figure', 'figcaption', 'img', 'audio', 'video', 'source'],
      ALLOWED_ATTR: ['src', 'href', 'alt'], ALLOW_ARIA_ATTR: false, ALLOW_DATA_ATTR: false,
    });
    for (const node of fragment.querySelectorAll('img, audio, video, a')) {
      const value = node.getAttribute('src') ?? node.querySelector('source[src]')?.getAttribute('src') ?? node.getAttribute('href');
      const attachment = renderAttachment?.(mediaPath(value));
      if (attachment) node.replaceWith(attachment);
      else if (node.localName === 'a') node.removeAttribute('href');
      else node.replaceWith(document.createTextNode(node.getAttribute('alt') ?? ''));
    }
    // Only the attachment widget may assign URLs, after authenticated downloads.
    for (const node of fragment.querySelectorAll('[src], [href]')) {
      node.removeAttribute('src');
      node.removeAttribute('href');
    }
    body.append(fragment);
  } else {
    body.classList.add('preserve-lines');
    body.textContent = fields.body;
  }
  return body;
}

function itemContent(kind, item) {
  if (kind === 'articles') return articleBody(item);
  if (kind === 'moments') return el('div', { class: 'preserve-lines' }, item.text || '这条微博没有文字。');
  const meta = [item.completedAt ? '已完成' : '未完成', item.dueDay, ['低优先级', '普通优先级', '高优先级'][item.priority]].filter(Boolean);
  return el('div', {}, el('p', { class: 'muted' }, meta.join(' · ')), el('p', { class: 'preserve-lines' }, item.notes || ''));
}

function modalOpen(title, build) {
  modal?.close();
  const content = el('section', { class: 'sheet-content' });
  const dialog = el('dialog', { class: 'sheet', 'aria-label': title },
    el('header', { class: 'sheet-header' }, el('h2', {}, title), button('关闭', () => modalDismiss(), { class: 'quiet' })), content);
  const dismiss = () => {
    if (dialog.dataset.saving === 'true') return;
    if (dialog.dataset.dirty === 'true' && !confirm('放弃这次尚未保存的编辑？')) return;
    dialog.close();
  };
  dialog.addEventListener('cancel', event => { event.preventDefault(); dismiss(); });
  dialog.addEventListener('close', () => {
    dialog.remove();
    if (modal === dialog) { modal = null; modalDismiss = null; }
    flushAutoSync();
  });
  modal = dialog;
  modalDismiss = dismiss;
  document.body.append(dialog);
  build(content, dialog);
  dialog.showModal();
}

function formError(form, message) { form.querySelector('[role="alert"]').textContent = message; }

function bindForm(form, dialog, action, trackEdits = true) {
  if (trackEdits) form.addEventListener('input', () => { dialog.dataset.dirty = 'true'; });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (dialog.dataset.saving === 'true') return;
    const submit = form.querySelector('[type="submit"]');
    dialog.dataset.saving = 'true';
    submit.disabled = true;
    formError(form, '');
    try {
      if (await action(new FormData(form)) === false) return;
      dialog.close();
      render();
    } catch (error) {
      formError(form, error?.message || '保存失败，请重试。');
    } finally {
      submit.disabled = false;
      dialog.dataset.saving = 'false';
    }
  });
}

function field(label, input) { return el('label', { class: 'field' }, el('span', {}, label), input); }
function textarea(name, value, props) {
  const node = el('textarea', { name, rows: 5, ...props });
  node.value = value;
  return node;
}

function attachmentPicker(kind, original, startingFiles, dialog) {
  let files = [...startingFiles];
  const list = el('div', { class: 'selected-files' });
  const message = el('p', { class: 'error', role: 'status' });
  const input = el('input', { type: 'file', multiple: true, accept: kind === 'moments'
    ? '.jpg,.jpeg,.png,.gif,.webp,.avif,.heic,.heif,.mp3,.mp4' : null });
  function renderFiles() {
    list.replaceChildren(...files.map(file => el('div', { class: 'selected-file' },
      el('span', {}, file.name), button('移除', () => {
        files = files.filter(current => current.id !== file.id);
        dialog.dataset.dirty = 'true';
        message.textContent = '';
        renderFiles();
      }, { 'aria-label': `移除 ${file.name}` }))));
  }
  input.addEventListener('change', () => {
    const additions = Array.from(input.files, file => ({ id: uuid(), name: uploadName(file.name), blob: file }));
    input.value = '';
    if (!additions.length) return;
    try {
      const combined = [...files, ...additions];
      validateUploadSelection(kind, original, combined);
      files = combined;
      dialog.dataset.dirty = 'true';
      message.textContent = '';
      renderFiles();
    } catch (error) { message.textContent = error.message; }
  });
  renderFiles();
  return { element: el('section', { class: 'attachments' }, field('添加附件', input), list, message), files: () => files };
}

function edit(kind, original, conflict) {
  const draft = conflict?.local ?? original;
  const initial = editableFields(kind, draft);
  const article = kind === 'articles';
  const formTitle = conflict ? '手动合并' : `${original ? '编辑' : '新建'}${labels[kind]}`;
  modalOpen(formTitle, (content, dialog) => {
    const form = el('form', { class: 'editor' });
    const picker = kind === 'todos' ? null : attachmentPicker(kind, original,
      conflict?.op.files ?? (original && operation(kind, original)?.files) ?? [], dialog);
    if (kind !== 'moments') {
      form.append(field('标题', el('input', { name: 'title', value: initial.title, required: true, maxlength: kind === 'todos' ? 200 : undefined })));
    }
    if (article) {
      form.append(field(initial.format === 'html' ? '正文（HTML）' : '正文',
        textarea('body', initial.body, { required: true, rows: 12, class: initial.format === 'html' ? 'source' : undefined })));
      if (initial.format === 'html') form.append(el('p', { class: 'muted' }, '这篇 Mac 文章使用富文本。仅改标题时会保留原正文。'));
    } else if (kind === 'moments') {
      form.append(field('正文', textarea('text', initial.text, { maxlength: Math.max(5000, initial.text.length), rows: 9 })));
    } else {
      const priority = el('select', { name: 'priority' }, ['低', '普通', '高'].map((label, index) =>
        el('option', { value: index, selected: index === initial.priority }, label)));
      form.append(field('备注', textarea('notes', initial.notes, {})), el('div', { class: 'field-pair' },
        field('优先级', priority), field('截止日期', el('input', { type: 'date', name: 'dueDay', value: initial.dueDay ?? '' }))));
      if (conflict?.op.method === 'todos.complete') {
        form.replaceChildren(field('状态', el('select', { name: 'completed' },
          el('option', { value: 'open', selected: !draft.completedAt }, '未完成'),
          el('option', { value: 'done', selected: !!draft.completedAt }, '已完成'))));
      }
    }
    if (conflict) {
      const remote = el('details', { class: 'remote-reference' },
        el('summary', {}, '查看 Mac 版本'), el('p', {}, conflict.remote.title || ''), itemContent(kind, conflict.remote));
      if (article && (initial.format === 'html' || editableFields(kind, conflict.remote).format === 'html')) {
        remote.append(field('Mac 正文源码', textarea('remoteBody', conflict.remote.body, { readonly: true, class: 'source' })));
      }
      form.prepend(remote);
    }
    if (picker) form.append(picker.element);
    form.append(el('p', { class: 'error', role: 'alert' }),
      el('button', { type: 'submit', class: 'primary' }, conflict ? '保存合并结果' : '保存'));
    content.append(form);
    bindForm(form, dialog, async values => {
      const base = conflict ? resolveEdit(state, conflict.op, conflict.remote) : state;
      let next;
      if (conflict?.op.method === 'todos.complete') {
        const completed = values.get('completed') === 'done';
        next = completed === Boolean(original.completedAt) ? base : completeTodo(base, original, completed ? new Date().toISOString() : null);
      } else {
        let fields;
        if (article) fields = { title: values.get('title').trim(), body: values.get('body'), format: initial.format };
        else if (kind === 'moments') fields = { text: values.get('text') };
        else fields = { title: values.get('title').trim(), notes: values.get('notes'), priority: Number(values.get('priority')), dueDay: values.get('dueDay') || null };
        const files = picker?.files();
        if (fields.title === '' || fields.body?.trim() === '' || (fields.text?.trim() === '' && !original?.images?.length && !files?.length)) {
          throw new Error('请填写完整的内容。');
        }
        next = saveEditor(base, kind, original, fields, files);
      }
      await commit(next);
      notice = '已保存到本机。';
    });
  });
}

async function fetchRemote(op) {
  if (!state.pairing) throw new Error('请先连接 Mac。');
  if (op.method.endsWith('.create') && op.kind !== 'articles') return null;
  const reply = await request(state.pairing, 'read', { method: `${op.kind}.get`, params: lookup(op.kind, op.key) });
  if (reply.error?.code === 'not_found') return null;
  if (reply.error) throw new Error(reply.error.message);
  return reply.result;
}

function conflictDialog(op, local) {
  const isConflict = ['conflict', 'not_found', 'already_exists'].includes(op.error.code);
  modalOpen(isConflict ? '处理同步冲突' : '处理同步失败', (content, dialog) => {
    const message = el('p', {}, op.error.message);
    const remoteCard = el('section', { class: 'version-card' }, el('h3', {}, 'Mac'), el('p', { class: 'muted' }, '正在读取…'));
    const localCard = el('section', { class: 'version-card' }, el('h3', {}, '这部手机'),
      local.title ? el('strong', {}, local.title) : '', itemContent(op.kind, local));
    if (op.files?.length) localCard.append(...op.files.map(file => pendingAttachmentCard(file, dialog)));
    const actions = el('div', { class: 'sheet-actions' });
    const error = el('p', { class: 'error', role: 'alert' });
    content.append(message, el('div', { class: 'versions' }, localCard, remoteCard), actions, error);
    const act = action => async () => {
      if (dialog.dataset.saving === 'true') return;
      dialog.dataset.saving = 'true';
      error.textContent = '';
      try { await action(); }
      catch (problem) { error.textContent = problem?.message || '操作失败，请重试。'; }
      finally { dialog.dataset.saving = 'false'; }
    };
    const finish = async (next, message) => {
      await commit(next);
      notice = message;
      dialog.close();
      render();
    };
    function load() {
      actions.replaceChildren();
      error.textContent = '';
      return fetchRemote(op).then(remote => {
        if (!dialog.open) return;
        remoteCard.replaceChildren(el('h3', {}, 'Mac'));
        if (remote) {
          if (remote.title) remoteCard.append(el('strong', {}, remote.title));
          remoteCard.append(itemContent(op.kind, remote));
        } else {
          remoteCard.append(el('p', { class: 'muted' }, op.method.endsWith('.create') ? '原操作没有可对照的记录。' : 'Mac 上已没有这条记录。'));
        }
        const uncertain = op.error.code === 'write_unknown';
        const copyable = op.kind !== 'moments' || Boolean(local.text?.trim() || op.files?.length);
        if (isConflict || uncertain) {
          actions.append(button('保留手机副本', act(async () => {
            if (uncertain && !confirm('请先在 Mac 核对上次保存结果。继续会新建一条内容，可能产生副本。')) return;
            const latest = await fetchRemote(op);
            const base = resolveEdit(state, op, latest);
            const fields = editableFields(op.kind, local);
            if (op.kind !== 'moments') fields.title += '（手机副本）';
            await finish(saveEditor(base, op.kind, null, fields, op.files), '手机副本已保存到本机，等待同步。');
          }), { class: 'primary', disabled: !copyable }));
        }
        if (remote && isConflict) {
          actions.append(button('手动合并', () => edit(op.kind, remote, { op, local, remote })));
        }
        if (!isConflict && !uncertain) {
          actions.append(button('重新编辑', act(async () => {
            // The Mac rejected this payload without writing. Queue a new ID
            // with its original base version so any meanwhile edit still conflicts.
            const originalParams = { ...op.params };
            const next = structuredClone(state);
            const retry = next.outbox.find(candidate => candidate.id === op.id);
            retry.id = uuid();
            if (op.method === 'articles.create') {
              retry.key = `mobile-${retry.id}`;
              originalParams.slug = retry.key;
              next.articles.find(item => item.slug === op.key).slug = retry.key;
            }
            retry.params = originalParams;
            retry.attempted = false;
            delete retry.error;
            delete retry.transferError;
            await commit(next);
            render();
            if (retry.method === 'todos.complete') {
              dialog.close();
              notice = '已重新排队，请在 Mac 上处理提示后再次同步。';
              render();
            } else {
              edit(op.kind, next[op.kind].find(item => keyOf(op.kind, item) === retry.key));
            }
          })));
        }
        actions.append(button(remote ? '采用 Mac 版本' : '清除这条本地修改', act(async () => {
          if (!confirm('确认清除这条尚未同步的手机修改？')) return;
          await finish(resolveEdit(state, op, await fetchRemote(op)), '已更新本机内容。');
        })));
      }).catch(problem => {
        if (!dialog.open) return;
        remoteCard.replaceChildren(el('h3', {}, 'Mac'), el('p', { class: 'muted' }, '暂时无法读取 Mac 版本。'));
        error.textContent = problem.message;
        actions.append(button('重新读取', load));
      });
    }
    // showModal is called after the content is built.
    queueMicrotask(load);
  });
}

function detail(kind, item) {
  const op = operation(kind, item);
  if (op?.error) { conflictDialog(op, item); return; }
  modalOpen(item.title || labels[kind], (content, dialog) => {
    const date = dateLabel(item.createdAt || item.updatedAt);
    if (date) content.append(el('p', { class: 'muted' }, date));
    const refs = new Map(recordAttachments(kind, item).map(ref => [ref.path, ref]));
    const pairing = state.pairing;
    const key = keyOf(kind, item);
    const renderAttachment = path => {
      const ref = refs.get(path);
      if (!ref) return null;
      refs.delete(path);
      return attachmentCard({ ref, kind, key, pairing, dialog });
    };
    content.append(kind === 'articles' ? articleBody(item, renderAttachment) : itemContent(kind, item));
    const remaining = [...refs.keys()].map(renderAttachment);
    for (const file of op?.files ?? []) remaining.push(pendingAttachmentCard(file, dialog));
    if (remaining.length) {
      content.append(el('section', { class: 'attachments', 'aria-label': '附件' }, el('h3', {}, '附件'), remaining));
    }
    if (op?.attempted) content.append(el('p', { class: 'muted' }, '这条编辑等待 Mac 确认。'));
    const actions = el('div', { class: 'sheet-actions' },
      button('编辑', () => edit(kind, item), { class: 'primary', disabled: op?.attempted || op?.method === 'todos.complete' }));
    if (kind === 'todos') actions.append(button(item.completedAt ? '重新打开' : '标为完成', async () => {
      const dialog = modal;
      if (dialog.dataset.saving === 'true') return;
      dialog.dataset.saving = 'true';
      try {
        await commit(completeTodo(state, item, item.completedAt ? null : new Date().toISOString()));
        notice = '已保存到本机。';
        dialog.close();
        render();
      } catch (error) { content.append(el('p', { class: 'error', role: 'alert' }, error.message)); }
      finally { dialog.dataset.saving = 'false'; }
    }, { disabled: Boolean(op) }));
    content.append(actions);
  });
}

function pairing() {
  modalOpen('连接 Mac', (content, dialog) => {
    const platform = Capacitor.getPlatform();
    const nameInput = el('input', { name: 'device', value: platform === 'ios' ? 'iPhone' : platform === 'android' ? 'Android 手机' : '浏览器', maxlength: 64 });
    const paste = el('input', { name: 'payload', type: 'password', autocomplete: 'off', required: true });
    const connectButton = el('button', { type: 'submit', class: 'primary' }, '连接');
    const form = el('form', { class: 'editor' },
      el('p', { class: 'muted' }, '打开 Mac 的「设置 → 手机同步」，生成一次性二维码。首次使用这台 Mac 时，请先安装并信任同步证书。'),
      field('设备名称', nameInput),
      field('粘贴配对信息', paste), el('p', { class: 'error', role: 'alert' }), connectButton);
    async function connect(payload, name) {
      const parsed = parsePairing(payload);
      if (Capacitor.isNativePlatform() && !parsed.url.startsWith('https://')) throw new Error('手机连接需要使用 Mac 输出的 HTTPS 地址。');
      const switching = Boolean(state.pairing && state.pairing.workspaceID !== parsed.workspaceID);
      if (switching && state.outbox.length) throw new Error('请先同步或处理原工作区的手机修改，再切换工作区。');
      if (switching && !confirm('切换工作区后将清除手机上的旧工作区缓存。继续？')) return false;
      if (parsed.code && !name.trim()) throw new Error('请填写设备名称。');
      const connection = parsed.code ? await pairDevice(parsed, name.trim()) : parsed;
      if (!parsed.code) {
        const identity = await request(connection, 'hello');
        if (identity.workspaceID !== parsed.workspaceID) throw new Error('Mac 返回了其他工作区。');
      }
      await commit({ ...(switching ? emptyState() : state), pairing: connection, lastSyncError: null }, { clearAttachments: switching });
      notice = '已连接 Mac。';
      dialog.addEventListener('close', () => sync(), { once: true });
    }
    if (Capacitor.isNativePlatform()) {
      const scan = button('扫描配对码', async () => {
        if (dialog.dataset.saving === 'true') return;
        dialog.dataset.saving = 'true';
        scan.disabled = connectButton.disabled = true;
        formError(form, '');
        try {
          const { CapacitorBarcodeScanner, CapacitorBarcodeScannerTypeHint } = await import('@capacitor/barcode-scanner');
          const result = await CapacitorBarcodeScanner.scanBarcode({
            hint: CapacitorBarcodeScannerTypeHint.QR_CODE, scanInstructions: '对准 Mac 上的 LeonBook 配对二维码',
            cancelButtonAccessibilityLabel: '取消扫码',
          });
          if (result.ScanResult && await connect(result.ScanResult, nameInput.value) !== false) {
            dialog.close();
            render();
          }
        } catch (error) {
          if (!/cancel/i.test(error?.message ?? '')) formError(form, error?.message || '无法扫码，请检查相机权限或粘贴配对信息。');
        } finally {
          scan.disabled = connectButton.disabled = false;
          dialog.dataset.saving = 'false';
        }
      }, { class: 'primary' });
      nameInput.closest('label').after(scan);
    }
    content.append(form);
    bindForm(form, dialog, values => connect(values.get('payload'), nameInput.value), false);
    if (state.pairing) {
      const result = el('p', { class: 'muted', role: 'status' });
      const clear = button('清除附件缓存', async () => {
        clear.disabled = true;
        try {
          await clearAttachmentCache();
          result.textContent = '附件缓存已清除。连接 Mac 后可重新下载。';
        } catch { result.textContent = '暂时无法清除附件缓存，请重试。'; }
        finally { clear.disabled = false; }
      });
      content.append(el('div', { class: 'sheet-actions' }, clear), result);
    }
  });
}

function requestAutoSync() {
  if (!state?.pairing) return;
  autoRequested = true;
  flushAutoSync();
}

function flushAutoSync() {
  if (!autoRequested || !foreground || busy || modal?.open || autoTimer) return;
  autoTimer = setTimeout(() => {
    autoTimer = undefined;
    if (autoRequested && foreground && !busy && !modal?.open) sync();
  }, Math.max(400, nextAutoAt - Date.now()));
}

async function sync({ onlyOperationID } = {}) {
  if (busy || modal?.open || !state.pairing) return;
  autoRequested = false;
  clearTimeout(autoTimer);
  autoTimer = undefined;
  nextAutoAt = Date.now() + 8_000;
  busy = true;
  notice = '正在与 Mac 同步…';
  render();
  const engine = new SyncEngine(state, commit, async (action, args) => {
    const result = await request(state.pairing, action, args);
    if (result.result && action === 'push' && args.files?.length) {
      await cacheUploadedAttachments(state.pairing, args.method, result.result, args.files);
    }
    return result;
  });
  try {
    await engine.run({ onlyOperationID });
    const failures = state.outbox.filter(op => op.error).length;
    notice = failures ? `同步完成，${failures} 条修改待处理。` : '已与 Mac 同步。';
    if (engine.todosDisabled) notice += 'Mac 已关闭待办模块，手机保留现有待办。';
  } catch (error) {
    notice = error?.message || '同步暂时失败。';
    try { await commit({ ...state, lastSyncError: notice }); }
    catch { /* Keep the visible error if local storage is unavailable too. */ }
  } finally {
    busy = false;
    render();
    flushAutoSync();
  }
}

function syncStatus() {
  modalOpen('同步状态', (content, dialog) => {
    if (state.lastSync) content.append(el('p', { class: 'muted' }, `上次同步 ${dateLabel(state.lastSync)}`));
    if (state.lastSyncError) content.append(el('p', { class: 'error', role: 'status' }, state.lastSyncError));
    if (!state.outbox.length) content.append(el('p', { class: 'muted' }, '没有待同步的修改。'));
    const afterClose = task => {
      dialog.addEventListener('close', task, { once: true });
      dialog.close();
    };
    for (const op of state.outbox) {
      const item = state[op.kind].find(record => keyOf(op.kind, record) === op.key);
      const failure = op.error?.message ?? op.transferError;
      const row = el('div', { class: 'sync-item' },
        el('strong', {}, item?.title || item?.text || labels[op.kind]),
        el('p', { class: failure ? 'error' : 'muted' }, failure || (op.attempted ? '等待 Mac 确认' : '待同步')));
      if (op.error && item) row.append(button('处理', () => detail(op.kind, item)));
      else if (state.pairing && op.transferError) {
        row.append(button('重试此条', () => afterClose(() => sync({ onlyOperationID: op.id }))));
      }
      content.append(row);
    }
    if (state.pairing) content.append(button('立即同步', () => afterClose(() => sync()), { class: 'primary' }));
  });
}

function recordList(container) {
  const filter = query.trim().toLocaleLowerCase();
  const items = state[active].filter(item => [item.title, item.text, item.notes, item.excerpt, ...(item.tags ?? [])]
    .filter(Boolean).join(' ').toLocaleLowerCase().includes(filter));
  if (!items.length) {
    container.replaceChildren(el('section', { class: 'empty' }, el('h2', {}, filter ? '没有匹配内容' : `还没有${labels[active]}`),
      el('p', {}, filter ? '试试其他关键词。' : '新建一条内容，或连接 Mac 同步已有资料。')));
    return;
  }
  container.replaceChildren(...items.map(item => {
    const op = operation(active, item);
    const badge = op?.error ? (['conflict', 'not_found', 'already_exists'].includes(op.error.code) ? '有冲突' : '待处理')
      : op?.transferError ? '同步失败' : op ? '待同步' : active === 'articles' && item.status === 'draft' ? '草稿'
      : active === 'todos' && item.completedAt ? '已完成' : '';
    const heading = item.title || item.text || '无文字微博';
    const summary = active === 'articles' ? item.excerpt : active === 'todos' ? item.notes : null;
    const metadata = [active === 'todos' ? item.dueDay : dateLabel(item.createdAt || item.updatedAt), badge].filter(Boolean);
    const record = button('', () => detail(active, item), { class: 'record', disabled: busy });
    record.append(
      el('strong', { class: 'record-title' }, heading),
      summary ? el('span', { class: 'record-summary' }, summary) : '',
      metadata.length ? el('span', { class: op?.error || op?.transferError ? 'record-meta error' : 'record-meta' }, metadata.join(' · ')) : '');
    return record;
  }));
}

function render() {
  const list = el('div', { class: 'records' });
  const search = el('input', { class: 'search', type: 'search', 'aria-label': `搜索${labels[active]}`, placeholder: `搜索${labels[active]}`, value: query,
    oninput: event => { query = event.target.value; recordList(list); } });
  const heading = el('header', { class: 'top' },
    el('div', { class: 'brand' }, el('span', { class: 'brand-icon', 'aria-hidden': 'true' }, 'L'), 'LeonBook'),
    button(state.pairing ? '配对设置' : '连接 Mac', pairing, { class: 'quiet', disabled: busy }));
  const failed = state.outbox.filter(op => op.error || op.transferError).length;
  const pending = state.outbox.length - failed;
  const status = el('div', { class: 'status' },
    el('div', {}, el('span', { 'aria-live': 'polite' }, notice || state.lastSyncError || (state.lastSync ? `上次同步 ${dateLabel(state.lastSync)}`
      : state.pairing ? '等待首次同步' : '当前仅在本机保存')),
    el('div', { class: failed ? 'error' : 'muted' }, `待同步 ${pending} · 失败 ${failed}`)),
    el('div', { class: 'sync-actions' }, button('同步状态', syncStatus, { disabled: busy }),
      state.pairing ? button('同步', () => sync(), { disabled: busy }) : ''));
  const tabs = el('nav', { class: 'tabs', 'aria-label': '资料分类' }, Object.entries(labels).map(([kind, label]) =>
    button(label, () => { active = kind; query = ''; render(); }, { 'aria-current': kind === active ? 'page' : null })));
  root.replaceChildren(heading, el('main', {}, status,
    el('div', { class: 'list-head' }, el('h1', {}, labels[active]), button('＋ 新建', () => edit(active), { class: 'primary', disabled: busy })),
    search, list), tabs);
  recordList(list);
}

async function start() {
  try {
    state = await loadState() ?? emptyState();
    if (state.version !== 1) throw new Error('这份本机资料需要更新版本的 LeonBook。');
    render();
    if (Capacitor.getPlatform() === 'android') {
      await App.addListener('backButton', () => {
        if (modalDismiss) modalDismiss();
        else App.minimizeApp();
      });
    }
    if (Capacitor.isNativePlatform()) {
      await App.addListener('appStateChange', ({ isActive }) => {
        foreground = isActive;
        if (isActive) requestAutoSync();
      });
    } else {
      document.addEventListener('visibilitychange', () => {
        foreground = !document.hidden;
        if (foreground) requestAutoSync();
      });
    }
    window.addEventListener('online', requestAutoSync);
    if (foreground) requestAutoSync();
  } catch (error) {
    root.replaceChildren(el('p', { class: 'boot error', role: 'alert' }, error?.message || '无法打开本机资料。'));
  }
}

start();
