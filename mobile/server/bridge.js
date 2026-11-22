import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { DatabaseSync } from 'node:sqlite';
import { createServer as createHTTPServer } from 'node:http';
import { createServer as createHTTPSServer } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { openAttachment } from './attachments.js';
import { deviceRegistry } from './devices.js';
import { operationID, readUpload } from './uploads.js';
import { articleSourcePath, validArticleDestination } from '../shared/article-placement.js';
import { inlineArticleIDs } from '../shared/inline-article-images.js';

const reads = new Set([
  'articles.list', 'articles.get', 'articles.folders', 'moments.list', 'moments.get', 'todos.list', 'todos.get',
]);
const writes = new Map(Object.entries({
  'articles.create': ['slug', 'title', 'body', 'format', 'destinationFolder'],
  'articles.update': ['slug', 'expectedUpdatedAt', 'title', 'body', 'format'],
  'moments.create': ['text'],
  'moments.update': ['id', 'expectedUpdatedAt', 'text'],
  'todos.create': ['title', 'notes', 'priority', 'dueDay'],
  'todos.update': ['id', 'expectedRevision', 'title', 'notes', 'priority', 'dueDay'],
  'todos.complete': ['id', 'expectedRevision', 'completed'],
}));
const rejected = new Set([
  'invalid_params', 'invalid_request', 'validation_error', 'not_found', 'already_exists',
  'conflict', 'module_disabled', 'read_only', 'message_too_large', 'attachment_limit',
]);
const allowedOrigins = new Set([
  'capacitor://localhost', 'https://localhost', 'http://127.0.0.1:4187',
]);
const MAX_REQUEST = 4 * 1024 * 1024;
const unknown = { error: { code: 'write_unknown', message: 'Mac 无法确认上次写入是否完成。请先核对 Mac 的资料，再处理手机保留的修改。' } };
const restored = { error: { code: 'workspace_restored', message: 'Mac 资料库已恢复，或旧回执无法确认。请对照 Mac 版本处理手机保留的修改。' } };
const messages = {
  conflict: 'Mac 上的内容已经变化。', not_found: '这条内容已从 Mac 的资料库移除。',
  already_exists: 'Mac 已存在同名内容。',
  module_disabled: '请在 Mac 设置中启用对应模块后重试。',
  read_only: '这个 Mac 工作区当前只读。',
  message_too_large: '内容超过同步接口的大小限制。',
  response_too_large: 'Mac 返回的资料超过大小限制。',
  snapshot_changed: 'Mac 上的资料在同步过程中已变化，请重试。',
  workspace_restored: restored.error.message,
  validation_error: 'Mac 未接受这次保存，请检查内容。',
  invalid_params: 'Mac 未接受这次编辑参数。',
  invalid_request: 'Mac 未接受这次同步请求。',
  attachment_limit: '一条微博最多可保存 9 个附件。请移除部分待上传附件后重试。',
  upgrade_required: '请升级 Mac 版 LeonBook，再重新同步这条内容。',
  storage_error: 'Mac 暂时无法保存上传文件，请检查可用空间后重试。',
};

function authorized(header, token) {
  const actual = Buffer.from(header ?? '');
  const expected = Buffer.from(`Bearer ${token}`);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

function invalid(message = '同步请求格式不正确。') {
  return { error: { code: 'invalid_request', message } };
}

function object(value) { return value && typeof value === 'object' && !Array.isArray(value); }

async function readBody(req, maxBytes = MAX_REQUEST) {
  const length = req.headers['content-length'];
  if (length !== undefined && Number(length) > maxBytes) return null;
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBytes) return null;
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { return null; }
}

function cleanResponse(response) {
  if (!response.error) return { result: response.result };
  return { error: {
    code: response.error.code,
    message: messages[response.error.code] ?? 'Mac 暂时无法处理同步，请检查 Mac 端同步服务。',
  } };
}

export function makeBridge({ databasePath, workspaceID, workspacePath, automation, getGeneration = async () => null,
  tls, allowLegacyToken = true, now = Date.now }) {
  const token = allowLegacyToken ? randomBytes(32).toString('base64url') : null;
  const journal = new DatabaseSync(databasePath);
  journal.exec(`
    PRAGMA busy_timeout = 3000;
    PRAGMA synchronous = FULL;
    CREATE TABLE IF NOT EXISTS mobile_operations (
      workspace TEXT NOT NULL, id TEXT NOT NULL, fingerprint TEXT NOT NULL,
      response TEXT, generation TEXT, PRIMARY KEY (workspace, id)
    );
    BEGIN IMMEDIATE;
  `);
  if (!journal.prepare('PRAGMA table_info(mobile_operations)').all().some(column => column.name === 'generation')) {
    journal.exec('ALTER TABLE mobile_operations ADD COLUMN generation TEXT');
  }
  journal.exec('COMMIT');
  const devices = deviceRegistry(journal, workspaceID, now);
  const insert = journal.prepare('INSERT OR IGNORE INTO mobile_operations (workspace, id, fingerprint, generation) VALUES (?, ?, ?, ?)');
  const select = journal.prepare('SELECT fingerprint, response, generation FROM mobile_operations WHERE workspace = ? AND id = ?');
  const finish = journal.prepare('UPDATE mobile_operations SET response = ? WHERE workspace = ? AND id = ?');
  const remove = journal.prepare('DELETE FROM mobile_operations WHERE workspace = ? AND id = ?');
  let busy = false;
  const inFlight = new Set();

  async function push({ id, method, params, generation: expected, compact }, files = []) {
    if (typeof id !== 'string' || !operationID.test(id) ||
        !object(params) || !writes.has(method) || Object.keys(params).some(key => !writes.get(method).includes(key))) {
      return invalid();
    }
    if (method === 'articles.create' && params.slug !== `mobile-${id}`) return invalid();
    const { destinationFolder, ...automationParams } = params;
    if (Object.hasOwn(params, 'destinationFolder')) {
      if (!validArticleDestination(destinationFolder)) return invalid('请选择有效的文章目录。');
      automationParams.sourceRelativePath = articleSourcePath(destinationFolder, params.slug);
    }
    // Operations use flat parameter maps, so key ordering does not affect retries.
    if (Object.values(params).some(value => value !== null && typeof value === 'object')) return invalid();
    const payload = [method, Object.entries(params).sort(([a], [b]) => a.localeCompare(b))];
    if (files.length) payload.push(files.map(({ name, kind, digest }) => [name, kind, digest]));
    const inlineIDs = method.startsWith('articles.') ? inlineArticleIDs(params.body) : new Set();
    if (inlineIDs.size) {
      const images = new Set(files.filter(file => file.kind === 'image').map(file => file.id));
      if (params.format !== 'html' || [...inlineIDs].some(id => !images.has(id))) return invalid('正文插图缺少对应的图片文件。');
      payload.push(files.map(file => file.id));
    }
    const fingerprint = createHash('sha256').update(JSON.stringify(payload)).digest('hex');
    const generation = await getGeneration();
    if ((expected !== undefined && expected !== generation) ||
        (expected === undefined && generation !== null && generation !== 'initial')) return restored;
    const claimed = insert.run(workspaceID, id, fingerprint, generation).changes === 1;
    if (!claimed) {
      const record = select.get(workspaceID, id);
      if (record.fingerprint !== fingerprint) return invalid('这次操作的编号已被另一项编辑使用。');
      if (record.generation !== generation) return restored;
      // After a bridge crash, the content write may have committed. An unfinished
      // claim survives the restart and prevents a blind replay of that write.
      return record.response ? JSON.parse(record.response) : unknown;
    }
    let result;
    try {
      const staged = files.map(({ id, path, name, kind }) => ({ path, name, kind, ...(inlineIDs.size ? { id } : {}) }));
      const attachments = staged.length ? { files: staged, ...(inlineIDs.size ? { inlineImages: true } : {}) } : {};
      const wantsReceipt = generation !== null && compact === true && method.startsWith('articles.');
      const response = generation !== null
        ? await automation('mobile.mutate', { method, params: automationParams, generation, compact: wantsReceipt, ...attachments })
        : staged.length ? await automation('mobile.saveWithAttachments', { method, params: automationParams, ...attachments })
          : await automation(method, automationParams);
      if (response.error?.code === 'busy') {
        remove.run(workspaceID, id);
        return null;
      }
      if (response.error?.code === 'workspace_restored') {
        remove.run(workspaceID, id);
        return restored;
      }
      if ((generation !== null || files.length) && response.error?.code === 'method_not_found') {
        result = { error: { code: 'upgrade_required', message: messages.upgrade_required } };
      } else {
        result = response.error && !rejected.has(response.error.code) ? unknown : cleanResponse(response);
        if (wantsReceipt && !response.error) result.receipt = true;
      }
    } catch {
      result = unknown;
    }
    finish.run(JSON.stringify(result), workspaceID, id);
    return generation !== await getGeneration() ? restored : result;
  }

  async function handle(req, res) {
    const origin = req.headers.origin;
    if (origin && !allowedOrigins.has(origin)) { res.writeHead(403).end(); return; }
    if (origin) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
    }
    res.setHeader('Cache-Control', 'no-store, no-transform');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const multipart = req.url === '/v1/push-with-files';
    const pairing = req.url === '/v1/pair';
    if (!multipart && !pairing && req.url !== '/v1/sync') { res.writeHead(404).end(); return; }
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Methods': 'POST',
        'Access-Control-Allow-Headers': 'authorization, content-type',
        'Access-Control-Allow-Private-Network': 'true',
      }).end();
      return;
    }
    if (req.method !== 'POST') { res.writeHead(405).end(); return; }
    const send = (status, response) => res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' }).end(JSON.stringify(response));
    if (pairing) {
      if (req.headers['content-type']?.split(';')[0] !== 'application/json') { res.writeHead(415).end(); return; }
      const input = await readBody(req, 4096);
      const result = devices.pair(input);
      if (!result) { send(403, { error: { code: 'pairing_unavailable' } }); return; }
      send(200, { result });
      return;
    }
    const authorization = req.headers.authorization;
    const canSync = () => (token && authorized(authorization, token)) ||
      (authorization?.startsWith('Bearer ') && devices.accepts(authorization.slice(7)));
    if (!canSync()) { res.writeHead(401).end(); return; }
    if (multipart) {
      if (busy) { req.resume(); send(503, { error: { code: 'busy' } }); return; }
      busy = true;
      let directory;
      try {
        directory = await mkdtemp(join(tmpdir(), 'leonbook-upload-'));
        const staged = await readUpload(req, directory);
        if (req.aborted) return;
        if (!canSync()) { res.writeHead(401).end(); return; }
        if (staged.error) {
          send(200, { error: { code: staged.error, message: messages[staged.error] } });
        } else if (staged.metadata.workspaceID !== workspaceID) {
          send(400, invalid('请检查配对工作区。'));
        } else {
          const response = await push(staged.metadata, staged.files);
          send(response ? 200 : 503, response ?? { error: { code: 'busy' } });
        }
      } finally {
        busy = false;
        if (directory) await rm(directory, { recursive: true, force: true });
      }
      return;
    }
    if (req.headers['content-type']?.split(';')[0] !== 'application/json') { res.writeHead(415).end(); return; }
    const input = await readBody(req);
    if (!object(input) || input.workspaceID !== workspaceID) { send(400, invalid('请检查配对工作区。')); return; }
    const { action, method, params, generation } = input;
    if (action === 'hello') {
      send(200, {
        workspaceID, generation: (await getGeneration()) ?? undefined, supportsArticleFolders: true, supportsArticleDestination: true,
        supportsInlineArticleImages: true,
      });
      return;
    }
    if (busy) { send(503, { error: { code: 'busy' } }); return; }
    busy = true;
    let attachment;
    try {
      if (action === 'attachment') {
        attachment = await openAttachment(workspacePath, automation, input);
      } else if (action === 'push') {
        const response = await push(input);
        send(response ? 200 : 503, response ?? { error: { code: 'busy' } });
      } else if (action === 'read' && reads.has(method) && object(params)) {
        if (generation !== undefined && generation !== await getGeneration()) { send(200, restored); return; }
        const response = await automation(method, params);
        if (generation !== undefined && generation !== await getGeneration()) { send(200, restored); return; }
        send(response.error?.code === 'busy' ? 503 : 200, cleanResponse(response));
      } else {
        send(400, invalid());
      }
    } finally { busy = false; }
    if (!attachment) return;
    if (attachment.status !== 200) { res.writeHead(attachment.status).end(); return; }
    const { handle, size, contentType } = attachment;
    try {
      res.writeHead(200, {
        'Content-Type': contentType, 'Content-Length': size, 'Content-Disposition': 'attachment',
      });
      if (size === 0) { res.end(); return; }
      await pipeline(handle.createReadStream({ autoClose: false, start: 0, end: size - 1 }), res);
    } finally { await handle.close(); }
  }

  const listener = (req, res) => {
    const request = handle(req, res).catch(error => {
      if (res.destroyed) return;
      console.error(`LeonBook 同步服务处理失败：${error.code ?? error.name}`);
      if (!res.headersSent) res.writeHead(500);
      res.end();
    });
    inFlight.add(request);
    request.finally(() => inFlight.delete(request));
  };
  const server = tls ? createHTTPSServer(tls, listener) : createHTTPServer(listener);
  server.requestTimeout = 180_000;
  server.headersTimeout = 10_000;
  server.maxConnections = 24;
  server.once('close', () => Promise.allSettled([...inFlight]).then(() => journal.close()));
  return { server, token, devices };
}
