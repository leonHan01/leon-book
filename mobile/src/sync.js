export const collections = ['articles', 'moments', 'todos'];
export function emptyState() {
  return { version: 1, pairing: null, articles: [], moments: [], todos: [], outbox: [], lastSync: null };
}
export function keyOf(kind, item) { return kind === 'articles' ? item.slug : item.id; }
export function parsePairing(text) {
  let value, url;
  try { value = JSON.parse(text); url = new URL(value.url); }
  catch { throw new Error('配对信息无效，请复制 Mac 终端输出的完整 JSON。'); }
  const loopback = ['127.0.0.1', '[::1]'].includes(url.hostname);
  if (!(url.protocol === 'https:' || (url.protocol === 'http:' && loopback)) || url.username || url.password ||
      url.pathname !== '/' || url.search || url.hash ||
      typeof value.token !== 'string' || !/^[\w-]{32,128}$/.test(value.token) ||
      typeof value.workspaceID !== 'string' || !/^[\w-]{16,128}$/.test(value.workspaceID)) {
    throw new Error('配对信息无效，请复制 Mac 终端输出的完整 JSON。');
  }
  return { url: url.origin, token: value.token, workspaceID: value.workspaceID };
}

export const versions = { articles: 'expectedUpdatedAt', moments: 'expectedUpdatedAt', todos: 'expectedRevision' };
export const revision = (kind, item) => kind === 'todos' ? item.revision : item.updatedAt;
export const lookup = (kind, key) => ({ [kind === 'articles' ? 'slug' : 'id']: key });

export async function request(pairing, action, args = {}) {
  const { files, ...parameters } = args;
  const uploading = action === 'push' && files?.length;
  const metadata = { ...parameters, action, workspaceID: pairing.workspaceID };
  const headers = { Authorization: `Bearer ${pairing.token}` };
  let body;
  if (uploading) {
    body = new FormData();
    body.append('mutation', JSON.stringify({ ...metadata, files: files.map(({ id, name }) => ({ id, name })) }));
    for (const file of files) body.append(file.id, file.blob, 'upload.bin');
  } else {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(metadata);
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), uploading ? 180_000 : 50_000);
  let response;
  try {
    response = await fetch(`${pairing.url}${uploading ? '/v1/push-with-files' : '/v1/sync'}`, {
      method: 'POST', headers, body,
      redirect: 'error', signal: controller.signal, cache: 'no-store',
    });
  } catch { throw new Error('连接 Mac 失败。请检查网络、配对地址和 Mac 同步服务。'); }
  finally { clearTimeout(timeout); }
  if (response.status === 401) throw new Error('配对已失效，请从 Mac 重新复制配对信息。');
  if (response.status === 503) throw new Error('Mac 正在处理其他请求，请稍后继续同步。');
  if (uploading && response.status === 404) throw new Error('请更新并重启 Mac 的同步服务后再上传附件。');
  if (!response.ok) throw new Error('Mac 未接受同步请求，请检查配对信息。');
  return response.json();
}

// A sent payload is immutable. Even after a timeout its UUID must replay the
// exact payload, because the Mac may already have committed the operation.
export function queueEdit(state, kind, key, method, params, preview, uuid, files) {
  const previous = state.outbox.find(op => op.kind === kind && op.key === key);
  if (previous?.attempted || previous?.error) {
    throw new Error('这条内容有待确认的同步，请先同步或处理冲突。');
  }
  if (previous && previous.method !== method) {
    throw new Error('请先同步这条内容，再执行下一项操作。');
  }
  const next = structuredClone(state);
  const op = previous
    ? { ...previous, params: { ...previous.params, ...params } }
    : { id: uuid(), kind, key, method, params, attempted: false };
  if (files?.length) op.files = files;
  else if (files) delete op.files;
  // Never advance the base revision during repeated offline edits.
  if (previous?.params.expectedUpdatedAt) op.params.expectedUpdatedAt = previous.params.expectedUpdatedAt;
  if (previous?.params.expectedRevision !== undefined) op.params.expectedRevision = previous.params.expectedRevision;
  next.outbox = [...next.outbox.filter(item => item.id !== op.id), op];
  next[kind] = [preview, ...next[kind].filter(item => keyOf(kind, item) !== key)];
  return next;
}

export function resolveEdit(state, op, remote) {
  const next = structuredClone(state);
  next.outbox = next.outbox.filter(item => item.id !== op.id);
  next[op.kind] = next[op.kind].filter(item => keyOf(op.kind, item) !== op.key);
  if (remote) next[op.kind].unshift(remote);
  return next;
}

export class SyncEngine {
  constructor(state, persist, rpc) {
    this.state = state;
    this.persist = persist;
    this.rpc = rpc;
    this.todosDisabled = false;
  }
  async commit(next) { await this.persist(next); this.state = next; }
  async run() {
    const identity = await this.rpc('hello');
    if (identity.workspaceID !== this.state.pairing.workspaceID) throw new Error('Mac 工作区已变化，请检查配对信息。');
    // Flush each operation and durably acknowledge it before sending the next.
    for (const original of [...this.state.outbox]) {
      if (original.error) continue;
      let next = structuredClone(this.state);
      next.outbox.find(op => op.id === original.id).attempted = true;
      await this.commit(next);
      const response = await this.rpc('push', {
        id: original.id, method: original.method, params: original.params,
        ...(original.files?.length ? { files: original.files } : {}),
      });
      next = structuredClone(this.state);
      if (response.error) {
        next.outbox.find(op => op.id === original.id).error = response.error;
      } else {
        if (!response.result || typeof keyOf(original.kind, response.result) !== 'string') throw new Error('Mac 返回了无效的保存结果。');
        next.outbox = next.outbox.filter(op => op.id !== original.id);
        next[original.kind] = [response.result, ...next[original.kind].filter(item =>
          keyOf(original.kind, item) !== original.key &&
          keyOf(original.kind, item) !== keyOf(original.kind, response.result))];
      }
      await this.commit(next);
    }
    // Pull into a temporary snapshot. Incomplete pagination never erases cache.
    const remote = {};
    for (const kind of collections) {
      if (kind === 'todos') {
        const response = await this.rpc('read', { method: 'todos.list', params: {} });
        if (response.error?.code === 'module_disabled') this.todosDisabled = true;
        else if (response.error) throw new Error(response.error.message);
        else if (Array.isArray(response.result)) remote.todos = response.result;
        else throw new Error('待办数据格式有误。');
        continue;
      }
      const summaries = new Map();
      let offset = 0;
      for (;;) {
        const page = await this.read(`${kind}.list`, { offset, limit: 100 });
        if (!Array.isArray(page.items) || (page.hasMore && !page.items.length)) throw new Error('Mac 分页结果有误，请重试。');
        for (const item of page.items) summaries.set(keyOf(kind, item), item);
        offset += page.items.length;
        if (!page.hasMore) break;
      }
      const cached = new Map(this.state[kind].map(item => [keyOf(kind, item), item]));
      const pending = new Set(this.state.outbox.filter(op => op.kind === kind).map(op => op.key));
      remote[kind] = [];
      // Offset pages can shift while desktop content changes. Confirm a cached
      // key that disappeared before treating it as a remote deletion.
      for (const key of new Set([...summaries.keys(), ...cached.keys()])) {
        if (pending.has(key)) continue;
        const summary = summaries.get(key);
        const old = cached.get(key);
        if (summary && kind === 'moments') remote[kind].push(summary);
        else if (summary && old && old.updatedAt === summary.updatedAt && typeof old.body === 'string') {
          remote[kind].push({ ...old, ...summary });
        } else {
          const item = await this.read(`${kind}.get`, lookup(kind, key), true);
          if (item) remote[kind].push(item);
        }
      }
    }
    const next = structuredClone(this.state);
    for (const kind of collections) {
      if (!remote[kind]) continue;
      const pendingKeys = new Set(next.outbox.filter(op => op.kind === kind).map(op => op.key));
      // Remote deletions drop clean records; dirty local records remain visible.
      next[kind] = [...next[kind].filter(item => pendingKeys.has(keyOf(kind, item))),
        ...remote[kind].filter(item => !pendingKeys.has(keyOf(kind, item)))];
    }
    next.lastSync = new Date().toISOString();
    await this.commit(next);
    return this.state;
  }
  async read(method, params, allowMissing = false) {
    const response = await this.rpc('read', { method, params });
    if (allowMissing && response.error?.code === 'not_found') return null;
    if (response.error) throw new Error(response.error.message);
    return response.result;
  }
}
