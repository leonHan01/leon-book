import { App } from '@capacitor/app';
import { Capacitor } from '@capacitor/core';
import DOMPurify from 'dompurify';
import appIcon from './assets/leonbook-icon.png';
import './style.css';
import { attachmentKind, mediaPath, recordAttachments, uploadName } from '../shared/attachments.js';
import { articleSourcePath, defaultArticleFolder, validArticleDestination } from '../shared/article-placement.js';
import { inlineArticleID } from '../shared/inline-article-images.js';
import { clearAttachmentCache, loadArticleDrafts, loadState, removeArticleDraft, saveArticleDraft, saveState } from './storage.js';
import { attachmentCard, cacheUploadedAttachments, pendingAttachmentCard, previewImageBlob } from './attachments.js';
import { articleFolderPath, buildArticleDirectory, parentFolderPath } from './article-directories.js';
import { searchArticles, searchText } from './article-search.js';
import { browsingViewKey, loadBrowsingState, saveBrowsingState, setBrowsingPosition } from './browsing-state.js';
import { emptyState, keyOf, pairDevice, parsePairing, readRecord, request, resolveEdit, SyncEngine, upgradeSyncState } from './sync.js';
import { completeTodo, editableFields, mergeEditorFields, saveEditor, uuid, validateUploadSelection } from './editor.js';
import { imagePreviews, loadPhoto } from './attachment-images.js';
import { rememberReadingPosition } from './reading-position.js';
import { showPhotoGallery } from './photo-gallery.js';
import { autosaveArticleDraft } from './article-draft.js';
import { createArticleRichEditor } from './article-rich-editor.js';

const root = document.querySelector('#app');
const labels = { articles: '文章', moments: '微博', todos: '待办' };
let state, browsing, renderedBrowsing, busy = false, notice = '', browsingTimer;
let modal, modalDismiss, momentFeed, gallery, readerImages;
let updateSyncView;
let updateSyncDetails;
let articleDrafts = new Map(), draftButton, activeArticleDraft;
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

function storeBrowsingPosition() {
  clearTimeout(browsingTimer);
  if (!browsing || modal?.open || gallery?.open) return;
  const top = window.scrollY;
  const headerBottom = root.querySelector('.top')?.getBoundingClientRect().bottom ?? 0;
  let position = { top };
  if (top > 0) {
    for (const row of root.querySelectorAll('[data-browse-key]')) {
      const rect = row.getBoundingClientRect();
      if (rect.bottom <= headerBottom || rect.top >= window.innerHeight) continue;
      position = { top, key: row.dataset.browseKey, offset: rect.top };
      break;
    }
  }
  setBrowsingPosition(browsing, browsingViewKey(browsing), position);
  saveBrowsingState(state.pairing?.workspaceID, browsing);
}

function restoreBrowsingPosition() {
  const position = browsing.positions.get(browsingViewKey(browsing));
  const row = position?.key && [...root.querySelectorAll('[data-browse-key]')]
    .find(row => row.dataset.browseKey === position.key);
  const top = row && Number.isFinite(position.offset)
    ? window.scrollY + row.getBoundingClientRect().top - position.offset : position?.top ?? 0;
  window.scrollTo(0, top);
}

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
      if (!fragment.contains(node)) continue;
      const value = node.getAttribute('src') ?? node.querySelector('source[src]')?.getAttribute('src') ?? node.getAttribute('href');
      const alt = node.getAttribute('alt') ?? node.querySelector('img')?.getAttribute('alt');
      const path = mediaPath(value) ?? (node.localName === 'img' && inlineArticleID(value) ? value : null);
      const attachment = renderAttachment?.(path, alt);
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

function modalOpen(title, build, { reader = false, beforeClose, beforeDismiss, onClose } = {}) {
  if (!modal?.open) storeBrowsingPosition();
  modal?.close();
  const content = el('section', { class: 'sheet-content' });
  const back = button(reader ? '‹ 返回' : '关闭', () => dismiss(), { class: 'quiet', 'aria-label': reader ? '返回文章列表' : undefined });
  const header = reader
    ? el('header', { class: 'sheet-header reader-toolbar' }, back, el('span', { class: 'reader-toolbar-title' }, title))
    : el('header', { class: 'sheet-header' }, el('h2', {}, title), back);
  const dialog = el('dialog', { class: reader ? 'sheet article-reader' : 'sheet', 'aria-label': title }, header, content);
  const dismiss = async () => {
    if (dialog.dataset.saving === 'true') return;
    if (dialog.dataset.dirty === 'true' && !confirm('放弃这次尚未保存的编辑？')) return;
    if (beforeDismiss) {
      dialog.dataset.saving = 'true';
      try {
        if (!await beforeDismiss()) return;
      } finally { dialog.dataset.saving = 'false'; }
    }
    beforeClose?.();
    dialog.close();
  };
  const dismissFromSystem = () => {
    const menu = reader && dialog.querySelector('.reader-menu[open]');
    if (!menu) { dismiss(); return; }
    menu.open = false;
    menu.querySelector('summary').focus({ preventScroll: true });
  };
  dialog.addEventListener('cancel', event => { event.preventDefault(); dismissFromSystem(); });
  dialog.addEventListener('close', () => {
    dialog.remove();
    if (modal === dialog) { modal = null; modalDismiss = null; }
    onClose?.();
    updateImageNetwork();
    flushAutoSync();
  });
  modal = dialog;
  modalDismiss = dismissFromSystem;
  document.body.append(dialog);
  build(content, dialog, header);
  dialog.showModal();
  updateImageNetwork();
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
    const values = new FormData(form);
    form.inert = true;
    try {
      if (await action(values) === false) return;
      dialog.close();
      render();
    } catch (error) {
      formError(form, error?.message || '保存失败，请重试。');
    } finally {
      submit.disabled = false;
      form.inert = false;
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

function attachmentPicker(kind, original, startingFiles, dialog, {
  onChange = () => {}, onRemove = () => {}, includes = () => true,
} = {}) {
  let files = [...startingFiles];
  const list = el('div', { class: 'selected-files' });
  const message = el('p', { class: 'error', role: 'status' });
  const input = el('input', { type: 'file', multiple: true, accept: kind === 'moments'
    ? '.jpg,.jpeg,.png,.gif,.webp,.avif,.heic,.heif,.mp3,.mp4' : null });
  function renderFiles() {
    list.replaceChildren(...files.filter(includes).map(file => el('div', { class: 'selected-file' },
      el('span', {}, file.name), button('移除', () => {
        files = files.filter(current => current.id !== file.id);
        onRemove(file);
        dialog.dataset.dirty = 'true';
        message.textContent = '';
        onChange();
        renderFiles();
      }, { 'aria-label': `移除 ${file.name}` }))));
  }
  function add(selected, inline = false) {
    const additions = Array.from(selected, file => ({ id: uuid(), name: uploadName(file.name), blob: file, ...(inline ? { inline: true } : {}) }));
    if (!additions.length) return [];
    if (inline && additions.some(file => attachmentKind(file.name) !== 'image')) throw new Error('请选择 JPG、PNG、GIF、WebP、AVIF 或 HEIC 图片。');
    validateUploadSelection(kind, original, [...files.filter(includes), ...additions]);
    files.push(...additions);
    dialog.dataset.dirty = 'true';
    message.textContent = '';
    onChange();
    renderFiles();
    return additions;
  }
  input.addEventListener('change', () => {
    try { add(input.files); }
    catch (error) { message.textContent = error.message; }
    finally { input.value = ''; }
  });
  renderFiles();
  return { element: el('section', { class: 'attachments' }, field('添加附件', input), list, message),
    files: () => files.filter(includes), find: id => files.find(file => file.id === id), renderFiles, add };
}

const draftWorkspace = () => state.pairing?.workspaceID ?? '';
const draftID = (article, conflict) => conflict ? 'merge:' + conflict.op.id : article ? 'article:' + article.slug : 'new';

async function refreshArticleDrafts() {
  articleDrafts = new Map((await loadArticleDrafts(draftWorkspace())).map(draft => [draft.id, draft]));
}

function updateDraftButton() {
  if (!draftButton) return;
  draftButton.hidden = !articleDrafts.size;
  draftButton.disabled = busy;
}

function openArticleDrafts() {
  modalOpen('本地草稿', content => {
    const drafts = [...articleDrafts.values()].sort((a, b) => b.savedAt - a.savedAt);
    for (const draft of drafts) {
      const label = draft.fields.title.trim() || '未命名文章';
      content.append(button(label, () => {
        const article = state.articles.find(item => item.slug === draft.base?.slug);
        const op = article && operation('articles', article);
        if (op?.error && draft.id === 'merge:' + op.id) {
          editArticle(draft.base, { op, local: article, remote: draft.base }, draft);
        } else {
          editArticle(op?.error || op?.attempted ? null : article, null, draft);
        }
      }, { class: 'draft-entry' }));
    }
  });
}

function editArticle(original, conflict, selectedDraft) {
  const id = selectedDraft?.id ?? draftID(original, conflict);
  const restored = selectedDraft ?? articleDrafts.get(id);
  const baseArticle = original ? restored?.base ?? original : null;
  const fields = restored?.fields ?? (conflict
    ? mergeEditorFields('articles', conflict.remote, conflict.op) : editableFields('articles', original));
  const startingFiles = restored?.files ?? conflict?.op.files ?? (original && operation('articles', original)?.files) ?? [];
  const chooseFolder = !conflict && (!original || operation('articles', original)?.method === 'articles.create');
  const key = [draftWorkspace(), id];
  let rich, session;
  modalOpen(conflict ? '手动合并' : original ? '编辑文章' : '新建文章', (content, dialog) => {
    const form = el('form', { class: 'editor article-editor-form' });
    const title = el('input', { name: 'title', value: fields.title, required: true });
    const status = el('p', { class: 'muted', 'aria-live': 'polite' });
    const discard = button('丢弃本地草稿', async () => {
      if (dialog.dataset.saving === 'true' || !confirm('丢弃这份本地草稿？')) return;
      dialog.dataset.saving = 'true';
      await session.settle();
      try {
        await removeArticleDraft(key);
        articleDrafts.delete(id);
        updateDraftButton();
        dialog.close();
      } catch {
        status.textContent = '无法丢弃草稿，请重试。';
        status.classList.add('error');
        session.resume();
      } finally { dialog.dataset.saving = 'false'; }
    }, { class: 'quiet', hidden: !restored });

    let folder;
    const layout = el('div', { class: 'article-editor-fields' }, field('标题', title));
    if (chooseFolder) {
      const directory = buildArticleDirectory(state.articles, state.articleFolders ?? []);
      const selected = restored?.folder ?? (original ? articleFolderPath(original) : browsing.folder);
      const paths = [...new Set([...directory.keys(), selected])]
        .filter(path => path !== defaultArticleFolder && validArticleDestination(path)).sort((a, b) => a.localeCompare(b));
      const destination = paths.includes(selected) ? selected : defaultArticleFolder;
      folder = el('select', { name: 'articleFolder' }, [defaultArticleFolder, ...paths].map(path =>
        el('option', { value: path, selected: path === destination }, path.split('/').join(' / '))));
      layout.append(field('保存目录', folder));
    }
    if (conflict) form.append(el('details', { class: 'remote-reference' },
      el('summary', {}, '查看 Mac 版本'), itemContent('articles', conflict.remote)));
    if (original && baseArticle?.updatedAt !== original.updatedAt) {
      form.append(el('p', { class: 'muted' }, '这份草稿保存后，若 Mac 已修改文章，同步时会提示处理冲突。'));
    } else if (!original && restored?.base) {
      form.append(el('p', { class: 'muted' }, '原文章暂时无法编辑，保存这份草稿会新建文章。'));
    }
    form.append(layout);

    let inline = new Set();
    function changed() {
      inline = rich.inlineIDs();
      picker.renderFiles();
      dialog.dataset.dirty = 'false';
      discard.hidden = false;
      session.changed();
    }
    const picker = attachmentPicker('articles', original, startingFiles, dialog, {
      includes: file => !file.inline || inline.has(file.id),
      onRemove: file => { if (file.inline) rich.removeImage(file.id); },
      onChange: changed,
    });
    const refs = new Map(recordAttachments('articles', original ?? restored?.base).map(ref => [ref.path, ref]));
    const pairing = state.pairing;
    const imageInput = el('input', { type: 'file', name: 'inlineImages', multiple: true, hidden: true,
      accept: '.jpg,.jpeg,.png,.gif,.webp,.avif,.heic,.heif' });
    rich = createArticleRichEditor(fields, {
      chooseImages: () => imageInput.click(),
      onChange: changed,
      async resolveImage(path, signal) {
        const inlineID = inlineArticleID(path);
        if (inlineID) {
          const file = picker.find(inlineID);
          return file && previewImageBlob(file.blob, file.name);
        }
        const ref = refs.get(mediaPath(path));
        if (!ref || ref.kind !== 'image') return null;
        const blob = await loadPhoto(pairing, 'articles', original?.slug ?? restored?.base?.slug, { ref }, signal,
          () => foreground && !busy && navigator.onLine);
        return blob && previewImageBlob(blob, ref.name);
      },
    });
    inline = rich.inlineIDs();
    picker.renderFiles();
    const pendingImageError = el('p', { class: 'error', role: 'status' });
    imageInput.addEventListener('change', () => {
      try {
        const files = picker.add(imageInput.files, true);
        if (files.length) rich.insertImages(files);
        pendingImageError.textContent = '';
      } catch (error) { pendingImageError.textContent = error.message; }
      finally { imageInput.value = ''; }
    });

    session = autosaveArticleDraft(() => ({
      id, base: baseArticle ?? restored?.base ?? null, savedAt: Date.now(), folder: folder?.value,
      fields: { title: title.value, ...rich.body() }, files: picker.files(),
    }), async snapshot => {
      await saveArticleDraft(key, snapshot);
      articleDrafts.set(id, snapshot);
      updateDraftButton();
    }, (message, error) => {
      status.textContent = message;
      status.classList.toggle('error', Boolean(error));
    }, Boolean(restored));
    activeArticleDraft = session;

    title.addEventListener('input', changed);
    folder?.addEventListener('change', changed);
    form.append(rich.element, imageInput, pendingImageError, picker.element, status, el('p', { class: 'error', role: 'alert' }),
      el('button', { type: 'submit', class: 'primary' }, conflict ? '保存合并结果' : '保存文章'), discard);
    content.append(form);
    bindForm(form, dialog, async values => {
      const title = values.get('title').trim();
      const body = rich.body();
      if (!title || !rich.hasContent()) throw new Error('请填写标题，并在正文输入文字或插图。');
      const base = conflict ? resolveEdit(state, conflict.op, baseArticle) : state;
      const next = saveEditor(base, 'articles', baseArticle, { title, ...body }, picker.files(), {
        articleDestination: folder ? values.get('articleFolder') : undefined,
      });
      await session.settle();
      try {
        await commit(next, { removeDraft: key });
        articleDrafts.delete(id);
        updateDraftButton();
        notice = '已保存到本机。';
      } catch (error) {
        session.resume();
        throw error;
      }
    }, false);
  }, {
    beforeDismiss: () => session.flush(),
    onClose() {
      rich.dispose();
      if (activeArticleDraft === session) activeArticleDraft = null;
    },
  });
}

function edit(kind, original, conflict) {
  if (kind === 'articles') { editArticle(original, conflict); return; }
  const draft = conflict?.local ?? original;
  const initial = conflict ? mergeEditorFields(kind, conflict.remote, conflict.op) : editableFields(kind, original);
  const formTitle = conflict ? '手动合并' : `${original ? '编辑' : '新建'}${labels[kind]}`;
  modalOpen(formTitle, (content, dialog) => {
    const form = el('form', { class: 'editor' });
    const picker = kind === 'todos' ? null : attachmentPicker(kind, original,
      conflict?.op.files ?? (original && operation(kind, original)?.files) ?? [], dialog);
    if (kind !== 'moments') {
      form.append(field('标题', el('input', { name: 'title', value: initial.title, required: true, maxlength: kind === 'todos' ? 200 : undefined })));
    }
    if (kind === 'moments') {
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
      form.prepend(remote);
    }
    if (picker) form.append(picker.element);
    form.append(el('p', { class: 'error', role: 'alert' }),
      el('button', { type: 'submit', class: 'primary' }, conflict ? '保存合并结果' : '保存'));
    content.append(form);
    const initialValues = conflict ? new FormData(form) : null;
    bindForm(form, dialog, async values => {
      const base = conflict ? resolveEdit(state, conflict.op, conflict.remote) : state;
      let next;
      if (conflict?.op.method === 'todos.complete') {
        const completed = values.get('completed') === 'done';
        next = completed === Boolean(original.completedAt) ? base : completeTodo(base, original, completed ? new Date().toISOString() : null);
      } else {
        let fields;
        if (kind === 'moments') fields = { text: values.get('text') };
        else fields = { title: values.get('title').trim(), notes: values.get('notes'), priority: Number(values.get('priority')), dueDay: values.get('dueDay') || null };
        // Form controls may normalize line endings and the editor trims titles.
        // Keep the original field value when the merge form was left unchanged.
        if (initialValues) {
          for (const key of Object.keys(fields)) {
            if (key !== 'format' && values.get(key) === initialValues.get(key)) fields[key] = initial[key];
          }
        }
        const files = picker?.files();
        if (fields.title === '' || (fields.text?.trim() === '' && !original?.images?.length && !files?.length)) {
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
  return readRecord((action, args) => request(state.pairing, action, args), op.kind, op.key);
}

function conflictDialog(op, local) {
  const isRestored = op.error.code === 'workspace_restored';
  const isConflict = hasConflict(op);
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
            if ((uncertain || isRestored) && !confirm('请先在 Mac 核对上次保存结果。继续会新建一条内容，可能产生副本。')) return;
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
              const article = next.articles.find(item => item.slug === op.key);
              article.slug = retry.key;
              article.sourceRelativePath = articleSourcePath(originalParams.destinationFolder ?? defaultArticleFolder, retry.key);
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
  const readOnly = busy;
  if (op?.error && !readOnly) { conflictDialog(op, item); return; }
  if (kind === 'articles') { readArticle(item, op, readOnly); return; }
  modalOpen(item.title || labels[kind], (content, dialog) => {
    const date = dateLabel(item.createdAt || item.updatedAt);
    if (date) content.append(el('p', { class: 'muted' }, date));
    if (readOnly) content.append(el('p', { class: 'muted' }, '当前查看的是本机版本。同步结束后，从列表重新打开可编辑或查看更新。'));
    const refs = new Map(recordAttachments(kind, item).map(ref => [ref.path, ref]));
    const pairing = state.pairing;
    const key = keyOf(kind, item);
    const photos = kind === 'moments' ? momentPhotoSources(item, op) : [];
    let photoDownloads = Promise.resolve();
    const queueImage = kind === 'moments' ? task => { photoDownloads = photoDownloads.then(task); } : undefined;
    const openPhoto = id => {
      const index = photos.findIndex(photo => (photo.id ?? photo.ref.path) === id);
      return index >= 0 ? blob => openPhotoViewer('moments', item.id, photos, index, blob) : undefined;
    };
    const renderAttachment = path => {
      const ref = refs.get(path);
      if (!ref) return null;
      refs.delete(path);
      return attachmentCard({ ref, kind, key, pairing, dialog, offlineOnly: readOnly, queueImage, openImage: openPhoto(path) });
    };
    if (kind !== 'moments' || item.text?.trim()) content.append(itemContent(kind, item));
    const remaining = [...refs.keys()].map(renderAttachment);
    for (const file of op?.files ?? []) remaining.push(pendingAttachmentCard(file, dialog, openPhoto(file.id)));
    if (remaining.length) {
      content.append(el('section', { class: 'attachments', 'aria-label': '附件' }, el('h3', {}, '附件'), remaining));
    }
    if (readOnly) return;
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

const readerSizes = { small: ['小', '1rem'], standard: ['标准', '1.075rem'], large: ['大', '1.25rem'], extra: ['特大', '1.45rem'] };
const readerSizeKey = 'leonbook-reader-size';

function addReaderTools(dialog, toolbar, body, position, editArticle) {
  let size = 'standard';
  try {
    const saved = localStorage.getItem(readerSizeKey);
    if (Object.hasOwn(readerSizes, saved)) size = saved;
  } catch { /* Default to standard text size. */ }
  const applySize = value => dialog.style.setProperty('--reader-font-size', readerSizes[value][1]);
  applySize(size);
  const fontSize = el('select', { onchange: event => {
    size = event.target.value;
    position.reflow(() => applySize(size));
    try { localStorage.setItem(readerSizeKey, size); } catch { /* Keep the size for this reader session. */ }
  } }, Object.entries(readerSizes).map(([value, [label]]) =>
    el('option', { value, selected: value === size }, label)));
  const settings = el('details', { class: 'reader-menu' }, el('summary', {}, '更多'),
    el('div', { class: 'reader-menu-panel' }, field('阅读字号', fontSize), editArticle ? button('编辑文章', editArticle) : ''));
  const headings = [...body.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(heading => heading.textContent.trim());
  const menus = [];
  if (headings.length) {
    const firstLevel = Math.min(...headings.map(heading => Number(heading.tagName[1])));
    const outline = el('details', { class: 'reader-menu' }, el('summary', {}, '目录'));
    const links = headings.map(heading => {
      const level = Number(heading.tagName[1]) - firstLevel;
      const link = button(heading.textContent.trim(), () => {
        outline.open = false;
        heading.tabIndex = -1;
        heading.focus({ preventScroll: true });
        dialog.scrollBy(0, heading.getBoundingClientRect().top - toolbar.getBoundingClientRect().bottom - 10);
        position.save();
      });
      link.style.setProperty('--heading-indent', `${level * 0.55}rem`);
      return link;
    });
    outline.append(el('nav', { class: 'reader-menu-panel reader-outline', 'aria-label': '文章章节' }, links));
    menus.push(outline);
  }
  menus.push(settings);
  toolbar.append(el('div', { class: 'reader-actions' }, menus));
  dialog.addEventListener('pointerdown', event => {
    for (const menu of menus) if (menu.open && !menu.contains(event.target)) menu.open = false;
  });
  for (const menu of menus) {
    menu.addEventListener('toggle', () => {
      if (menu.open) for (const other of menus) if (other !== menu) other.open = false;
    });
  }
}

function readArticle(item, op, readOnly) {
  const title = item.title || labels.articles;
  const pairing = state.pairing;
  const refs = recordAttachments('articles', item);
  const available = new Map(refs.map(ref => [ref.path, ref]));
  const remaining = new Set(available.keys());
  const files = op?.files ?? [];
  const inlineFiles = new Map(files.map(file => [file.id, file]));
  const usedInline = new Set();
  const photos = [];
  let previews;
  let position;
  modalOpen(title, (content, dialog, toolbar) => {
    previews = imagePreviews({ pairing, kind: 'articles', root: dialog, networkEnabled: canDownloadReaderImages() });
    readerImages = previews;

    const date = dateLabel(item.createdAt || item.updatedAt);
    const badge = recordBadge('articles', item, op);
    const heading = el('header', { class: 'reader-heading' },
      date || badge ? el('p', { class: 'reader-meta' }, [date, badge].filter(Boolean).join(' · ')) : '',
      el('h1', {}, title));
    content.append(heading);
    const titleObserver = new IntersectionObserver(([entry]) => {
      toolbar.classList.toggle('reader-heading-scrolled', !entry.isIntersecting);
    }, { root: dialog });
    titleObserver.observe(heading);
    dialog.addEventListener('close', () => titleObserver.disconnect(), { once: true });
    if (readOnly) content.append(el('p', { class: 'muted' }, '正在同步，当前显示手机上已保存的正文。'));

    function photoTile(ref, alt, blob) {
      const index = photos.length;
      photos.push({ ref, blob });
      return previews.add({
        key: item.slug, ref, blob, className: 'article-image', aspectRatio: ratio => ratio,
        label: `全屏查看 ${alt || ref.name}`,
        open: (image, tile) => openPhotoViewer('articles', item.slug, photos, index, image, tile),
      });
    }
    const attachment = ref => attachmentCard({
      ref, kind: 'articles', key: item.slug, pairing, dialog, offlineOnly: readOnly,
    });
    const body = articleBody(item, (path, alt) => {
      const inlineID = inlineArticleID(path);
      const file = inlineFiles.get(inlineID);
      if (file && attachmentKind(file.name) === 'image') {
        usedInline.add(inlineID);
        return photoTile({ name: file.name }, alt, file.blob);
      }
      const ref = available.get(path);
      if (!ref) return null;
      const first = remaining.delete(path);
      if (ref.kind === 'image') return photoTile(ref, alt);
      return first ? attachment(ref) : null;
    });
    for (const table of body.querySelectorAll('table')) {
      const scroll = el('div', { class: 'reader-table-scroll', tabindex: 0, role: 'region', 'aria-label': '横向滚动表格' });
      table.replaceWith(scroll);
      scroll.append(table);
    }
    content.append(body);

    const extraPhotos = refs.filter(ref => ref.kind === 'image' && remaining.has(ref.path)).map(ref => photoTile(ref));
    for (const file of files) {
      if (!usedInline.has(file.id) && attachmentKind(file.name) === 'image') extraPhotos.push(photoTile({ name: file.name }, undefined, file.blob));
    }
    if (extraPhotos.length) content.append(el('section', { class: 'reader-extra-photos' }, el('h2', {}, '图片'), extraPhotos));

    const exportable = refs.filter(ref => ref.kind === 'image' || remaining.has(ref.path));
    if (exportable.length || files.length) {
      const attachments = el('details', { class: 'reader-files' }, el('summary', {}, `附件 · ${exportable.length + files.length}`));
      attachments.addEventListener('toggle', () => {
        if (dialog.open && attachments.open && attachments.childElementCount === 1) {
          attachments.append(el('div', { class: 'attachments' },
            exportable.map(attachment), files.map(file => pendingAttachmentCard(file, dialog))));
        }
      });
      content.append(attachments);
    }
    position = rememberReadingPosition(dialog, body, pairing?.workspaceID, item);
    addReaderTools(dialog, toolbar, body, position, !readOnly && !op?.attempted ? () => {
      position.save();
      edit('articles', item);
    } : null);
  }, { reader: true, beforeClose() { position.save(); }, onClose() {
    previews?.dispose();
    if (readerImages === previews) readerImages = null;
    restoreBrowsingPosition();
  } });
}

function pairing() {
  modalOpen('连接 Mac', (content, dialog) => {
    const platform = Capacitor.getPlatform();
    const nameInput = el('input', { name: 'device', value: platform === 'ios' ? 'iPhone' : platform === 'android' ? 'Android 手机' : '浏览器', maxlength: 64 });
    const paste = el('input', { name: 'payload', type: 'password', autocomplete: 'off', required: true });
    const connectButton = el('button', { type: 'submit', class: 'primary' }, '连接');
    const form = el('form', { class: 'editor' },
      el('p', { class: 'muted' }, '手机和 Mac 连上同一个 Wi-Fi。在 Mac 的「设置 → 手机同步」启动同步，生成二维码后用手机扫码。'),
      field('设备名称', nameInput),
      field('粘贴配对信息', paste), el('p', { class: 'error', role: 'alert' }), connectButton);
    async function connect(payload, name) {
      const parsed = parsePairing(payload);
      const switching = Boolean(state.pairing && state.pairing.workspaceID !== parsed.workspaceID);
      if (switching && state.outbox.length) throw new Error('请先同步或处理原工作区的手机修改，再切换工作区。');
      if (switching && !confirm('切换工作区后将清除手机上的旧工作区缓存。继续？')) return false;
      if (parsed.code && !name.trim()) throw new Error('请填写设备名称。');
      const connection = parsed.code ? await pairDevice(parsed, name.trim()) : parsed;
      if (!parsed.code) {
        const identity = await request(connection, 'hello');
        if (identity.workspaceID !== parsed.workspaceID) throw new Error('Mac 返回了其他工作区。');
      }
      const adoptLocalDrafts = !state.pairing ? connection.workspaceID : undefined;
      await commit({ ...(switching ? emptyState() : state), pairing: connection, lastSyncError: null, lastSyncErrorCode: null },
        { clearAttachments: switching, adoptLocalDrafts });
      if (switching || adoptLocalDrafts) await refreshArticleDrafts();
      if (switching) {
        clearTimeout(browsingTimer);
        browsing = loadBrowsingState(connection.workspaceID);
      } else {
        saveBrowsingState(connection.workspaceID, browsing);
      }
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
  if (!autoRequested || !foreground || !navigator.onLine || busy || modal?.open || gallery?.open || autoTimer) return;
  autoTimer = setTimeout(() => {
    autoTimer = undefined;
    if (autoRequested && foreground && navigator.onLine && !busy && !modal?.open && !gallery?.open) sync();
  }, Math.max(400, nextAutoAt - Date.now()));
}

async function sync({ onlyOperationID } = {}) {
  if (busy || modal?.open || gallery?.open || !state.pairing) return;
  autoRequested = false;
  clearTimeout(autoTimer);
  autoTimer = undefined;
  nextAutoAt = Date.now() + 8_000;
  busy = true;
  notice = '';
  updateSyncView();
  const engine = new SyncEngine(state, commit, async (action, args) => {
    const result = await request(state.pairing, action, args);
    if (result.result && action === 'push' && args.files?.length) {
      await cacheUploadedAttachments(state.pairing, args.method, result.result, args.files);
    }
    return result;
  });
  try {
    await engine.run({ onlyOperationID });
    if (engine.todosDisabled) notice = 'Mac 已关闭待办模块，手机保留现有待办。';
  } catch (error) {
    const failedState = { ...state, lastSyncError: error?.message || '同步暂时失败。', lastSyncErrorCode: error?.code ?? null };
    try { await commit(failedState); }
    catch { state = failedState; }
  } finally {
    busy = false;
    updateSyncView(true);
    flushAutoSync();
  }
}

const hasConflict = op => ['conflict', 'not_found', 'already_exists', 'workspace_restored'].includes(op?.error?.code);

function syncOverview() {
  const conflicts = state.outbox.filter(hasConflict).length;
  const failed = state.outbox.filter(op => !hasConflict(op) && (op.error || op.transferError)).length;
  const pending = state.outbox.length - conflicts - failed;
  const queued = [
    pending ? `${pending} 条待同步` : '',
    conflicts ? `${conflicts} 条冲突` : '',
    failed ? `${failed} 条失败` : '',
  ].filter(Boolean).join(' · ');
  const last = state.lastSync ? `上次同步 ${dateLabel(state.lastSync)}` : '';
  let title;
  if (busy) title = '正在与 Mac 同步…';
  else if (!state.pairing) title = '内容保存在手机上';
  else if (!navigator.onLine) title = '手机处于离线状态';
  else if (state.lastSyncErrorCode === 'pairing_expired') title = '需要重新配对 Mac';
  else if (['mac_unreachable', 'sync_timeout'].includes(state.lastSyncErrorCode)) title = 'Mac 暂时不可达';
  else if (state.lastSyncErrorCode === 'mac_busy') title = 'Mac 正忙，稍后再试';
  else if (state.lastSyncError) title = '同步未完成';
  else if (conflicts) title = '有同步冲突待处理';
  else if (failed) title = '有修改同步失败';
  else if (pending) title = '已保存到手机，等待同步';
  else title = state.lastSync ? '已与 Mac 同步。' : '等待首次同步';
  return { title, queued, last, attention: !busy && Boolean(state.lastSyncError || conflicts || failed) };
}

function syncStatus() {
  let refresh;
  modalOpen('同步状态', (content, dialog) => {
    const heading = el('p', { class: 'sync-detail-title', role: 'status' });
    const details = el('div', { class: 'sync-detail' });
    content.append(heading, details);
    const afterClose = task => {
      dialog.addEventListener('close', task, { once: true });
      dialog.close();
    };
    refresh = () => {
      const { title, last, attention } = syncOverview();
      heading.textContent = title;
      heading.classList.toggle('error', attention);
      details.replaceChildren();
      if (last) details.append(el('p', { class: 'muted' }, last));
      if (state.lastSyncError && !busy) details.append(el('p', { class: 'error' }, state.lastSyncError));
      if (notice) details.append(el('p', { class: 'muted' }, notice));
      if (!state.outbox.length && !busy) details.append(el('p', { class: 'muted' }, '没有待同步的修改。'));
      for (const op of state.outbox) {
        const item = state[op.kind].find(record => keyOf(op.kind, record) === op.key);
        const failure = op.error?.message ?? op.transferError;
        const row = el('div', { class: 'sync-item' },
          el('strong', {}, item?.title || item?.text || labels[op.kind]),
          el('p', { class: failure ? 'error' : 'muted' },
            failure || (op.attempted ? '等待 Mac 确认' : '待同步')));
        if (op.error && item) row.append(button('处理', () => detail(op.kind, item), { disabled: busy }));
        else if (state.pairing && op.transferError) {
          row.append(button('重试此条', () => afterClose(() => sync({ onlyOperationID: op.id })), { disabled: busy }));
        }
        details.append(row);
      }
      if (!state.pairing || state.lastSyncErrorCode === 'pairing_expired') {
        details.append(button(state.pairing ? '重新配对' : '连接 Mac', () => afterClose(pairing), { class: 'primary' }));
      } else {
        const action = state.lastSyncError || state.outbox.some(op => op.transferError) ? '重试同步' : '立即同步';
        details.append(button(action, () => afterClose(() => sync()), { class: 'primary', disabled: busy }));
      }
    };
    updateSyncDetails = refresh;
    refresh();
  }, { onClose() { if (updateSyncDetails === refresh) updateSyncDetails = null; } });
}

function recordBadge(kind, item, op) {
  if (op?.error) return hasConflict(op) ? '有冲突' : '待处理';
  if (op?.transferError) return '同步失败';
  if (op) return '待同步';
  if (kind === 'articles' && item.status === 'draft') return '草稿';
  if (kind === 'todos' && item.completedAt) return '已完成';
  return '';
}

function canLoadMomentImages() {
  return foreground && !busy && !modal?.open && !gallery?.open && navigator.onLine;
}

function canDownloadReaderImages() {
  return foreground && !busy && !gallery?.open && navigator.onLine;
}

function updateImageNetwork() {
  momentFeed?.images.setNetworkEnabled(canLoadMomentImages());
  readerImages?.setNetworkEnabled(canDownloadReaderImages());
}

function momentPhotoSources(item, op) {
  const photos = recordAttachments('moments', item).filter(ref => ref.kind === 'image').map(ref => ({ ref }));
  for (const file of op?.files ?? []) {
    if (attachmentKind(file.name) === 'image') photos.push({ id: file.id, ref: { name: file.name }, blob: file.blob });
  }
  return photos;
}

function openPhotoViewer(kind, key, photos, index, blob, anchor) {
  if (gallery?.open) return;
  const pairing = state.pairing;
  const selected = photos[index];
  const sheet = modal?.open ? modal : null;
  if (!sheet) storeBrowsingPosition();
  const sheetPosition = sheet && [sheet.scrollLeft, sheet.scrollTop];
  const anchorTop = anchor?.getBoundingClientRect().top;
  const viewer = showPhotoGallery(photos, index, (photo, signal) => loadPhoto(
    pairing, kind, key, photo === selected && blob ? { ...photo, blob } : photo, signal,
    () => foreground && !busy && navigator.onLine,
  ), () => {
    if (gallery !== viewer) return;
    gallery = null;
    restoreBrowsingPosition();
    if (sheet?.open) {
      sheet.scrollTo(...sheetPosition);
      if (anchor?.isConnected) sheet.scrollBy(0, anchor.getBoundingClientRect().top - anchorTop);
    }
    updateImageNetwork();
    flushAutoSync();
  });
  gallery = viewer;
  updateImageNetwork();
}

function renderMomentFeed(container, items) {
  const images = imagePreviews({ pairing: state.pairing, kind: 'moments', networkEnabled: canLoadMomentImages() });
  const cards = items.map(item => {
    const op = operation('moments', item);
    const photos = momentPhotoSources(item, op);
    const text = item.text?.trim();
    const badge = recordBadge('moments', item, op);
    const date = dateLabel(item.createdAt || item.updatedAt);
    const caption = text || (!photos.length ? (item.images?.length || op?.files?.length ? '附件微博' : '无文字微博') : '');
    const card = el('article', {
      class: 'moment-card', 'data-browse-key': `moment:${item.id}`, onclick: event => {
        if (!event.target.closest('button')) detail('moments', item);
      },
    });
    if (photos.length) {
      card.append(el('span', { class: 'moment-photos' },
        photos.map((photo, index) => images.add({
          ...photo, key: item.id, label: `查看第 ${index + 1} 张图片，共 ${photos.length} 张`,
          className: index === 0 ? 'moment-image moment-image-lead' : 'moment-image',
          aspectRatio: index === 0 ? ratio => Math.max(2 / 3, Math.min(ratio, 16 / 9)) : undefined,
          open: blob => openPhotoViewer('moments', item.id, photos, index, blob),
        }))));
    }
    const body = button('', () => detail('moments', item), {
      class: 'moment-card-body',
      'aria-label': [text?.slice(0, 120) || '微博详情', date, badge].filter(Boolean).join('，'),
    });
    if (caption) body.append(el('span', { class: 'moment-caption' }, caption));
    if (date || badge) {
      body.append(el('span', { class: 'moment-meta' },
        date ? el('span', {}, date) : '',
        badge ? el('span', { class: op?.error || op?.transferError ? 'error' : '' }, badge) : ''));
    } else if (!caption) body.append(el('span', { class: 'moment-meta' }, '查看详情'));
    card.append(body);
    return card;
  });
  const grid = el('div', { class: 'moments-waterfall' }, cards);
  container.replaceChildren(grid);
  const { gridAutoRows, columnGap } = getComputedStyle(grid);
  const rowHeight = parseFloat(gridAutoRows);
  const gap = parseFloat(columnGap);
  const rowSpan = card => `span ${Math.ceil((card.offsetHeight + gap) / rowHeight)}`;
  const spans = cards.map(rowSpan);
  cards.forEach((card, index) => { card.style.gridRowEnd = spans[index]; });
  const resize = new ResizeObserver(entries => {
    for (const { target } of entries) target.style.gridRowEnd = rowSpan(target);
  });
  for (const card of cards) resize.observe(card);
  momentFeed = { images, dispose() { resize.disconnect(); images.dispose(); } };
}

function openArticleFolder(path) {
  storeBrowsingPosition();
  browsing.folder = path;
  browsing.queries.articles = '';
  render({ restore: true });
}

function renderArticleBreadcrumbs(container) {
  const articleFolder = browsing.folder;
  const parents = [];
  for (let path = parentFolderPath(articleFolder); path; path = parentFolderPath(path)) parents.unshift(path);
  if (articleFolder) parents.unshift('');
  const name = path => path.split('/').at(-1) || '全部目录';
  const divider = () => el('span', { 'aria-hidden': 'true' }, '/');
  container.replaceChildren(
    ...parents.flatMap(path => [
      button(name(path), () => openArticleFolder(path), { class: 'quiet' }),
      divider(),
    ]),
    el('span', { 'aria-current': 'location' }, name(articleFolder)),
  );
}

function recordList(container, articleDirectory) {
  momentFeed?.dispose();
  momentFeed = null;
  const kind = browsing.tab;
  const filter = searchText(browsing.queries[kind]);
  const folder = articleDirectory?.get(browsing.folder);
  const folders = folder && !filter ? folder.folders : [];
  const withinFolder = folder?.path && browsing.scope === 'folder';
  const matches = folder && filter ? searchArticles(state.articles, filter, withinFolder ? folder.path : '') : null;
  const items = matches ? [...matches.keys()] : filter
    ? state[kind].filter(item => searchText([item.title, item.text, item.notes, ...(item.tags ?? [])].filter(Boolean).join(' ')).includes(filter))
    : folder?.articles ?? state[kind];
  if (!items.length && !folders.length) {
    const title = filter ? '没有匹配内容' : folder?.path ? '这个目录是空的' : `还没有${labels[kind]}`;
    const hint = filter ? (withinFolder ? '试试其他关键词，或搜索全部文章。' : '试试其他关键词。')
      : folder?.path ? '' : '新建一条内容，或连接 Mac 同步已有资料。';
    container.replaceChildren(el('section', { class: 'empty' }, el('h2', {}, title), hint ? el('p', {}, hint) : ''));
    return;
  }
  if (kind === 'moments') {
    renderMomentFeed(container, items);
    return;
  }
  const links = folders.map(({ name, path }) => {
    const link = button('', () => openArticleFolder(path), { class: 'article-folder', 'data-browse-key': `folder:${path}` });
    link.append(el('span', { class: 'folder-icon', 'aria-hidden': 'true' }),
      el('span', {}, name), el('span', { 'aria-hidden': 'true' }, '›'));
    return link;
  });
  const records = items.map(item => {
    const op = operation(kind, item);
    const badge = recordBadge(kind, item, op);
    const heading = item.title;
    const snippet = matches?.get(item);
    const summary = snippet || (kind === 'articles' ? item.excerpt : item.notes);
    const metadata = [kind === 'todos' ? item.dueDay : dateLabel(item.createdAt || item.updatedAt), badge].filter(Boolean);
    const record = button('', () => detail(kind, item), { class: 'record', 'data-browse-key': `record:${keyOf(kind, item)}` });
    record.append(
      el('strong', { class: 'record-title' }, heading),
      matches ? el('span', { class: 'record-directory' }, articleFolderPath(item)) : '',
      summary ? el('span', { class: snippet ? 'record-snippet' : 'record-summary' }, summary) : '',
      metadata.length ? el('span', { class: op?.error || op?.transferError ? 'record-meta error' : 'record-meta' }, metadata.join(' · ')) : '');
    return record;
  });
  container.replaceChildren(...links, ...records);
}

function render({ restore = false } = {}) {
  if (!restore && renderedBrowsing === browsing) storeBrowsingPosition();
  renderedBrowsing = browsing;
  const active = browsing.tab;
  let articleDirectory;
  const list = el('div', { class: 'records' });
  const breadcrumbs = active === 'articles' ? el('nav', { class: 'article-breadcrumbs', 'aria-label': '文章目录' }) : null;
  const searchLabel = breadcrumbs ? '搜索文章标题和正文' : `搜索${labels[active]}`;
  const scopeOptions = { all: '全部文章', folder: '当前目录及子目录' };
  const scope = breadcrumbs ? el('div', { class: 'article-search-scope', role: 'group', 'aria-label': '文章搜索范围' },
    Object.entries(scopeOptions).map(([value, label]) => button(label, () => {
      if (browsing.scope === value) return;
      storeBrowsingPosition();
      browsing.scope = value;
      refreshSearch();
    }, { 'data-scope': value }))) : null;
  const setQuery = (event) => {
    if (event.isComposing || browsing.queries[active] === event.target.value) return;
    storeBrowsingPosition();
    browsing.queries[active] = event.target.value;
    refreshSearch();
  };
  const search = el('input', { class: 'search', type: 'search', 'aria-label': searchLabel, placeholder: searchLabel,
    value: browsing.queries[active], oninput: setQuery, oncompositionend: setQuery });
  function refreshSearch() {
    if (scope) {
      scope.hidden = !browsing.folder || !browsing.queries.articles.trim();
      for (const control of scope.children) control.setAttribute('aria-pressed', control.dataset.scope === browsing.scope);
    }
    recordList(list, articleDirectory);
    restoreBrowsingPosition();
    saveBrowsingState(state.pairing?.workspaceID, browsing);
  }
  const connectButton = button(state.pairing ? '配对设置' : '连接 Mac', pairing, { class: 'quiet' });
  const heading = el('header', { class: 'top' },
    el('div', { class: 'brand' }, el('img', { class: 'brand-icon', src: appIcon, alt: '' }), 'LeonBook'), connectButton);
  const statusTitle = el('strong', { class: 'sync-summary-title', 'aria-live': 'polite' });
  const statusDetail = el('span', { class: 'sync-summary-detail muted' });
  const status = button('', syncStatus, { class: 'sync-summary', 'aria-haspopup': 'dialog' });
  status.append(el('span', {}, statusTitle, statusDetail), el('span', { 'aria-hidden': 'true' }, '›'));
  const newButton = button('＋ 新建', () => edit(active), { class: 'primary' });
  draftButton = active === 'articles' ? button('本地草稿', openArticleDrafts, { class: 'local-drafts-button' }) : null;
  const listActions = el('div', { class: 'list-actions' }, draftButton ?? '', newButton);
  const tabs = el('nav', { class: 'tabs', 'aria-label': '资料分类' }, Object.entries(labels).map(([kind, label]) =>
    button(label, () => {
      if (kind === active) return;
      storeBrowsingPosition();
      browsing.tab = kind;
      render({ restore: true });
    }, { 'aria-current': kind === active ? 'page' : null })));
  root.replaceChildren(heading, el('main', {}, status,
    el('div', { class: 'list-head' }, el('h1', {}, labels[active]), listActions),
    search, scope ?? '', breadcrumbs ?? '', list), tabs);
  updateSyncView = (refreshRecords = false) => {
    connectButton.disabled = busy;
    newButton.disabled = busy;
    updateDraftButton();
    const { title, queued, last, attention } = syncOverview();
    if (statusTitle.textContent !== title) statusTitle.textContent = title;
    statusTitle.classList.toggle('error', attention);
    statusDetail.textContent = queued || (!busy && notice) || last;
    statusDetail.hidden = !statusDetail.textContent;
    updateSyncDetails?.();
    if (refreshRecords) {
      if (list.hasChildNodes()) storeBrowsingPosition();
      if (breadcrumbs) {
        articleDirectory = buildArticleDirectory(state.articles, state.articleFolders ?? []);
        while (!articleDirectory.has(browsing.folder)) browsing.folder = parentFolderPath(browsing.folder);
        renderArticleBreadcrumbs(breadcrumbs);
      }
      refreshSearch();
    }
    updateImageNetwork();
  };
  updateSyncView(true);
}

async function start() {
  try {
    state = await loadState() ?? emptyState();
    if (state.version !== 1) throw new Error('这份本机资料需要更新版本的 LeonBook。');
    const upgraded = upgradeSyncState(state);
    if (upgraded !== state) await commit(upgraded);
    await refreshArticleDrafts();
    browsing = loadBrowsingState(state.pairing?.workspaceID);
    if ('scrollRestoration' in history) history.scrollRestoration = 'manual';
    render({ restore: true });
    window.addEventListener('scroll', () => {
      clearTimeout(browsingTimer);
      browsingTimer = setTimeout(storeBrowsingPosition, 180);
    }, { passive: true });
    window.addEventListener('pagehide', storeBrowsingPosition);
    window.addEventListener('pagehide', () => { void activeArticleDraft?.flush(); });
    document.addEventListener('visibilitychange', () => { if (document.hidden) void activeArticleDraft?.flush(); });
    if (Capacitor.getPlatform() === 'android') {
      await App.addListener('backButton', () => {
        if (gallery?.open) gallery.close();
        else if (modalDismiss) modalDismiss();
        else if (browsing.queries[browsing.tab].trim()) {
          storeBrowsingPosition();
          browsing.queries[browsing.tab] = '';
          render({ restore: true });
        }
        else if (browsing.tab === 'articles' && browsing.folder) openArticleFolder(parentFolderPath(browsing.folder));
        else App.minimizeApp();
      });
    }
    if (Capacitor.isNativePlatform()) {
      await App.addListener('appStateChange', ({ isActive }) => {
        foreground = isActive;
        if (!foreground) {
          storeBrowsingPosition();
          void activeArticleDraft?.flush();
        }
        updateImageNetwork();
        if (isActive) requestAutoSync();
      });
    } else {
      document.addEventListener('visibilitychange', () => {
        foreground = !document.hidden;
        if (!foreground) storeBrowsingPosition();
        updateImageNetwork();
        if (foreground) requestAutoSync();
      });
    }
    window.addEventListener('online', () => { updateSyncView(); requestAutoSync(); });
    window.addEventListener('offline', () => updateSyncView());
    if (foreground) requestAutoSync();
  } catch (error) {
    root.replaceChildren(el('p', { class: 'boot error', role: 'alert' }, error?.message || '无法打开本机资料。'));
  }
}

start();
