import { attachmentLimit, supportsMomentUpload, uploadBatchLimit, uploadFileCount } from '../shared/attachments.js';
import { keyOf, lookup, queueEdit, resolveEdit, revision, versions } from './sync.js';

const now = () => new Date().toISOString();

export function uuid() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = [...bytes].map(byte => byte.toString(16).padStart(2, '0')).join('');
  return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join('-');
}

export function validateUploadSelection(kind, original, files) {
  const existing = kind === 'moments' ? original?.images?.length ?? 0 : 0;
  if (existing + files.length > uploadFileCount) throw new Error('一次最多添加 9 个附件，微博以已有和新增的总数计。');
  let size = 0;
  for (const file of files) {
    if (kind === 'moments' && !supportsMomentUpload(file.name)) throw new Error('微博可添加常见图片、MP3 和 MP4。');
    if (new TextEncoder().encode(file.name).length > 250) throw new Error('附件文件名太长，请缩短后重新选择。');
    if (file.blob.size < 1 || file.blob.size > attachmentLimit) throw new Error('单个附件须大于 0 字节且最多 32 MiB。');
    size += file.blob.size;
  }
  if (size > uploadBatchLimit) throw new Error('一次最多上传 64 MiB，请分批添加。');
  return size;
}

export function saveEditor(state, kind, original, fields, files) {
  const creating = !original;
  const operationID = uuid();
  const key = creating ? (kind === 'articles' ? `mobile-${operationID}` : `local-${operationID}`) : keyOf(kind, original);
  const identity = lookup(kind, key);
  const pending = state.outbox.find(op => op.kind === kind && op.key === key);
  const previousFiles = pending?.files ?? [];
  const selected = files ?? previousFiles;
  if (files && kind !== 'todos') {
    let pendingBytes = validateUploadSelection(kind, original, selected);
    for (const op of state.outbox) {
      if (op.id !== pending?.id) for (const file of op.files ?? []) pendingBytes += file.blob.size;
    }
    if (pendingBytes > 128 * 1024 * 1024) throw new Error('手机已有 128 MiB 待上传附件，请先同步一部分。');
  }
  const isCreate = creating || pending?.method === `${kind}.create`;
  const base = isCreate
    ? (kind === 'articles' ? identity : {})
    : { ...identity, [versions[kind]]: revision(kind, original) };
  const patch = {};
  const previous = editableFields(kind, original);
  for (const [field, value] of Object.entries(fields)) {
    if (field !== 'format' && (creating || previous[field] !== value)) patch[field] = value;
  }
  if (Object.hasOwn(patch, 'body') || (kind === 'articles' && previous.format !== fields.format)) {
    patch.body = fields.body;
    patch.format = fields.format;
  }
  const filesChanged = selected.length !== previousFiles.length || selected.some((file, index) => file.id !== previousFiles[index]?.id);
  if (!Object.keys(patch).length && !filesChanged) return state;
  if (filesChanged && !selected.length && !isCreate && !Object.keys(patch).length &&
      pending && Object.keys(pending.params).every(field => Object.hasOwn(base, field))) {
    return resolveEdit(state, pending, original);
  }
  if (new TextEncoder().encode(JSON.stringify(patch)).length > 3 * 1024 * 1024) {
    throw new Error('内容太长，无法通过手机同步。请缩短内容或在 Mac 上编辑。');
  }
  const preview = {
    ...(kind === 'articles' ? { status: 'draft' } : {}),
    ...(kind === 'moments' ? { createdAt: now() } : {}),
    updatedAt: now(), ...original, ...identity, ...fields,
  };
  return queueEdit(state, kind, key, `${kind}.${isCreate ? 'create' : 'update'}`, { ...base, ...patch }, preview, () => operationID, files);
}

export function completeTodo(state, todo, completedAt) {
  return queueEdit(state, 'todos', todo.id, 'todos.complete', {
    id: todo.id, expectedRevision: todo.revision, completed: Boolean(completedAt),
  }, { ...todo, completedAt }, uuid);
}

export function editableFields(kind, item) {
  item ??= {};
  if (kind === 'articles') {
    const body = item.body ?? '';
    const wrapped = /^<article data-leon-format="html-v1">((?:<p>[^<>]*<\/p>)+)<\/article>$/.exec(body);
    if (!item.format && wrapped) {
      const entities = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"' };
      const paragraphs = Array.from(wrapped[1].matchAll(/<p>([^<>]*)<\/p>/g), match => match[1]);
      if (paragraphs.every(text => !/&(?!(?:amp|lt|gt|quot);)/.test(text))) {
        const plain = paragraphs.map(text => text.replace(/&(?:amp|lt|gt|quot);/g, entity => entities[entity])).join('\n');
        return { title: item.title ?? '', body: plain, format: 'text' };
      }
    }
    return { title: item.title ?? '', body, format: item.format ?? (/^\s*</.test(body) ? 'html' : 'text') };
  }
  if (kind === 'moments') return { text: item.text ?? '' };
  return { title: item.title ?? '', notes: item.notes ?? '', priority: item.priority ?? 1, dueDay: item.dueDay ?? null };
}
