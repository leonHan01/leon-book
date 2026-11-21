export const collections = ['articles', 'moments', 'todos'];
export function emptyState() {
  return { version: 1, pairing: null, articles: [], moments: [], todos: [], outbox: [], lastSync: null };
}

export function upgradeSyncState(state) {
  if (state.syncGeneration || !state.outbox.some(op => op.error?.code === 'message_too_large')) return state;
  const outbox = state.outbox.map(op => op.error?.code === 'message_too_large' ? {
    ...op, error: { code: 'write_unknown', message: '旧版本无法确认这条大内容是否已保存，请先在 Mac 核对。' },
  } : op);
  return { ...state, outbox };
}

export function keyOf(kind, item) { return kind === 'articles' ? item.slug : item.id; }
const invalidPairing = () => new Error('配对信息无效，请扫描或粘贴 LeonBook 显示的配对信息。');

export function parsePairing(text, now = Date.now()) {
  let value, url;
  try {
    if (typeof text !== 'string' || text.length > 4096) throw invalidPairing();
    value = JSON.parse(text);
    if (typeof value.url !== 'string') throw invalidPairing();
    url = new URL(value.url);
  } catch { throw invalidPairing(); }
  const loopback = ['127.0.0.1', '[::1]'].includes(url.hostname);
  if (!(url.protocol === 'https:' || (url.protocol === 'http:' && loopback)) || url.username || url.password ||
      url.pathname !== '/' || url.search || url.hash ||
      typeof value.workspaceID !== 'string' || !/^[\w-]{16,128}$/.test(value.workspaceID)) {
    throw invalidPairing();
  }
  const origin = { url: url.origin, workspaceID: value.workspaceID };
  if (value.type === 'leonbook-pair') {
    if (value.version !== 1 || typeof value.code !== 'string' || !/^[\w-]{43}$/.test(value.code) ||
        !Number.isFinite(value.expiresAt)) throw invalidPairing();
    // Mac validates expiration against its own clock. Allow modest clock skew on mobile.
    if (value.expiresAt < now - 60_000) throw new Error('配对码已过期，请在 Mac 上生成新的二维码。');
    return { ...origin, code: value.code };
  }
  if (typeof value.token !== 'string' || !/^[\w-]{32,128}$/.test(value.token)) throw invalidPairing();
  return { ...origin, token: value.token };
}

export async function pairDevice(invitation, name) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    let response;
    try {
      response = await fetch(`${invitation.url}/v1/pair`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, cache: 'no-store', redirect: 'error',
        body: JSON.stringify({ workspaceID: invitation.workspaceID, code: invitation.code, name }), signal: controller.signal,
      });
    } catch {
      throw new Error('无法连接 Mac。请确认同一局域网、Mac 同步已开启，以及手机已信任同步证书。');
    }
    if (response.status === 403) throw new Error('配对码不可用，请在 Mac 上生成新的二维码后重试。');
    if (!response.ok) throw new Error('Mac 未接受配对，请检查同步服务。');
    const { result } = await response.json();
    if (result?.workspaceID !== invitation.workspaceID || typeof result.token !== 'string' ||
        !/^[\w-]{43}$/.test(result.token) || typeof result.deviceID !== 'string') throw invalidPairing();
    return { url: invitation.url, workspaceID: result.workspaceID, token: result.token, deviceID: result.deviceID };
  } finally { clearTimeout(timeout); }
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
  try {
    let response;
    try {
      response = await fetch(`${pairing.url}${uploading ? '/v1/push-with-files' : '/v1/sync'}`, {
        method: 'POST', headers, body,
        redirect: 'error', signal: controller.signal, cache: 'no-store',
      });
    } catch { throw new Error('连接 Mac 失败。请检查网络、配对地址和 Mac 同步服务。'); }
    if (response.status === 401) throw new Error('此设备的配对已失效，请在 Mac 重新生成配对码。');
    if (response.status === 503) throw new Error('Mac 正在处理其他请求，请稍后继续同步。');
    if (uploading && response.status === 404) throw new Error('请更新并重启 Mac 的同步服务后再上传附件。');
    if (!response.ok) throw new Error('Mac 未接受同步请求，请检查配对信息。');
    // Fetch resolves at the headers. Keep the deadline in force while reading the body.
    return await response.json();
  } catch (error) {
    if (controller.signal.aborted) throw new Error('与 Mac 同步超时，请检查网络后重试。');
    throw error;
  } finally { clearTimeout(timeout); }
}

// A sent payload is immutable. Even after a timeout its UUID must replay the
// exact payload, because the Mac may already have committed the operation.
export function queueEdit(state, kind, key, method, params, preview, uuid, { files, baseFields } = {}) {
  const previous = state.outbox.find(op => op.kind === kind && op.key === key);
  if (previous?.attempted || previous?.error) {
    throw new Error('这条内容有待确认的同步，请先同步或处理冲突。');
  }
  if (previous && previous.method !== method) {
    throw new Error('请先同步这条内容，再执行下一项操作。');
  }
  const next = structuredClone(state);
  const op = previous
    ? { ...previous, params }
    : { id: uuid(), kind, key, method, params, attempted: false };
  if (baseFields) op.baseFields = baseFields;
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

function readError(error) {
  return Object.assign(new Error(error.message || 'Mac 暂时无法读取资料。'), { code: error.code });
}

export async function readRecord(rpc, kind, key, context = {}) {
  const method = `${kind}.get`;
  const params = lookup(kind, key);
  const response = await rpc('read', { ...context, method, params });
  if (response.error?.code === 'not_found') return null;
  if (!response.error) {
    if (!response.result || keyOf(kind, response.result) !== key) throw new Error('Mac 返回了无效的资料编号。');
    return response.result;
  }
  if (kind !== 'articles' || response.error.code !== 'response_too_large') throw readError(response.error);

  const chunks = [];
  let article;
  let offset = 0;
  do {
    const page = await rpc('read', { ...context, method, params: {
      ...params, bodyOffset: offset, ...(article ? { expectedUpdatedAt: article.updatedAt } : {}),
    } });
    if (page.error) throw readError(page.error);
    const { body, nextOffset, updatedAt, article: metadata } = page.result ?? {};
    article ??= metadata;
    if (article?.slug !== key || typeof updatedAt !== 'string' || article.updatedAt !== updatedAt ||
        typeof body !== 'string' || (nextOffset !== null && (!Number.isSafeInteger(nextOffset) || nextOffset <= offset))) {
      throw new Error('Mac 正文分段结果有误，请重试。');
    }
    chunks.push(body);
    offset = nextOffset;
  } while (offset !== null);
  return { ...article, body: chunks.join('') };
}

const restored = {
  code: 'workspace_restored',
  message: 'Mac 资料库已恢复，请对照 Mac 版本处理手机保留的修改。',
};
const snapshotChanged = { code: 'snapshot_changed', message: 'Mac 上的资料在同步过程中已变化，请重试。' };
const collectionLabels = { articles: '文章', moments: '微博', todos: '待办' };

export class SyncEngine {
  constructor(state, persist, rpc) {
    this.state = state;
    this.persist = persist;
    this.rpc = rpc;
    this.todosDisabled = false;
  }
  async commit(next) { await this.persist(next); this.state = next; }
  async run({ onlyOperationID } = {}) {
    const identity = await this.rpc('hello');
    if (identity.workspaceID !== this.state.pairing.workspaceID) throw new Error('Mac 工作区已变化，请检查配对信息。');
    const generation = identity.generation;
    if (this.state.syncGeneration && !generation) throw new Error('请升级 Mac 同步服务后再同步。');
    if (generation && generation !== this.state.syncGeneration) {
      const next = structuredClone(this.state);
      if (next.syncGeneration || generation !== 'initial') {
        for (const op of next.outbox) {
          op.error = restored;
          delete op.transferError;
        }
      }
      next.syncGeneration = generation;
      await this.commit(next);
    }
    const context = generation ? { generation } : {};
    // Flush each operation and durably acknowledge it before sending the next.
    for (const original of [...this.state.outbox]) {
      if (original.error || (onlyOperationID && original.id !== onlyOperationID)) continue;
      let next = structuredClone(this.state);
      next.outbox.find(op => op.id === original.id).attempted = true;
      await this.commit(next);
      let response;
      try {
        response = await this.rpc('push', {
          ...context, ...(generation ? { compact: true } : {}),
          id: original.id, method: original.method, params: original.params,
          ...(original.files?.length ? { files: original.files } : {}),
        });
      } catch (error) {
        next = structuredClone(this.state);
        next.outbox.find(op => op.id === original.id).transferError = error.message || '发送中断，请重试。';
        await this.commit(next);
        throw error;
      }
      next = structuredClone(this.state);
      if (response.error) {
        const rejected = next.outbox.find(op => op.id === original.id);
        rejected.error = response.error;
        delete rejected.transferError;
      } else {
        if (!response.result || typeof keyOf(original.kind, response.result) !== 'string') throw new Error('Mac 返回了无效的保存结果。');
        let record = response.result;
        if (response.receipt && original.kind === 'articles') {
          const { uploadedAttachments, ...receipt } = record;
          const local = next.articles.find(item => item.slug === original.key);
          record = { ...local, ...receipt, needsRefresh: true };
          if (uploadedAttachments?.length) {
            const media = new Map([...(local?.media ?? []), ...uploadedAttachments].map(item => [item.url, item]));
            record.media = [...media.values()];
          }
        }
        next.outbox = next.outbox.filter(op => op.id !== original.id);
        next[original.kind] = [record, ...next[original.kind].filter(item =>
          keyOf(original.kind, item) !== original.key &&
          keyOf(original.kind, item) !== keyOf(original.kind, record))];
      }
      await this.commit(next);
    }
    // Commit each complete collection independently. Never replace a cache with a partial scan.
    const failures = [];
    for (const kind of collections) {
      let records;
      try {
        try { records = await this.pullCollection(kind, context); }
        catch (error) {
          if (error.code !== 'snapshot_changed') throw error;
          records = await this.pullCollection(kind, context);
        }
      } catch (error) {
        if (kind === 'todos' && error.code === 'module_disabled') this.todosDisabled = true;
        else failures.push(`${collectionLabels[kind]}：${error.message}`);
        if (error.code === 'workspace_restored') break;
        continue;
      }
      const next = structuredClone(this.state);
      const pending = new Set(this.state.outbox.filter(op => op.kind === kind).map(op => op.key));
      next[kind] = [...next[kind].filter(item => pending.has(keyOf(kind, item))),
        ...records.filter(item => !pending.has(keyOf(kind, item)))];
      await this.commit(next);
    }
    if (failures.length) throw new Error(failures.join('；'));
    await this.commit({ ...this.state, lastSync: new Date().toISOString(), lastSyncError: null });
    return this.state;
  }
  async pullCollection(kind, context) {
    const method = `${kind}.list`;
    const checked = Boolean(context.generation);
    if (kind === 'todos' && !checked) {
      const response = await this.rpc('read', { method, params: {} });
      if (response.error) throw readError(response.error);
      if (!Array.isArray(response.result)) throw new Error('待办数据格式有误。');
      return response.result;
    }
    const summaries = new Map();
    let offset = 0;
    let limit = 100;
    let snapshot = '';
    let total;
    for (;;) {
      const params = { offset, limit, ...(checked ? { snapshot } : {}) };
      const response = await this.rpc('read', { ...context, method, params });
      if (response.error?.code === 'response_too_large' && limit > 1) {
        limit = Math.floor(limit / 2);
        continue;
      }
      if (response.error) throw readError(response.error);
      const page = response.result;
      if (!Array.isArray(page?.items) || (page.hasMore && !page.items.length) ||
          (checked && (typeof page.snapshot !== 'string' || !page.snapshot || !Number.isSafeInteger(page.total)))) {
        throw new Error('Mac 分页结果有误，请重试。');
      }
      if ((snapshot && snapshot !== page.snapshot) || (total !== undefined && total !== page.total)) {
        throw readError(snapshotChanged);
      }
      snapshot = page.snapshot ?? '';
      total = page.total;
      for (const item of page.items) {
        const key = keyOf(kind, item);
        if (typeof key !== 'string') throw new Error('Mac 返回了无效的资料编号。');
        if (summaries.has(key)) throw readError(snapshotChanged);
        summaries.set(key, item);
      }
      offset += page.items.length;
      if (!page.hasMore) {
        if (total !== undefined && offset !== total) throw readError(snapshotChanged);
        break;
      }
    }
    if (kind === 'todos') return [...summaries.values()];

    const records = [];
    const cached = new Map(this.state[kind].map(item => [keyOf(kind, item), item]));
    const pending = new Set(this.state.outbox.filter(op => op.kind === kind).map(op => op.key));
    // Recheck missing cached keys before treating them as remote deletions.
    for (const key of new Set([...summaries.keys(), ...cached.keys()])) {
      if (pending.has(key)) continue;
      const summary = summaries.get(key);
      const old = cached.get(key);
      if (summary && kind === 'moments') records.push(summary);
      else if (summary && old && !old.needsRefresh && old.updatedAt === summary.updatedAt && typeof old.body === 'string') {
        records.push({ ...old, ...summary });
      } else {
        const item = await readRecord(this.rpc, kind, key, context);
        if (checked && summary && item?.updatedAt !== summary.updatedAt) throw readError(snapshotChanged);
        if (item) records.push(item);
      }
    }
    return records;
  }
}
