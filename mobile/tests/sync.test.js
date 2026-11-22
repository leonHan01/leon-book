import test from 'node:test';
import assert from 'node:assert/strict';
import { completeTodo, editableFields, mergeEditorFields, saveEditor } from '../src/editor.js';
import { emptyState, parsePairing, request, resolveEdit, SyncEngine, upgradeSyncState } from '../src/sync.js';

const pairing = { url: 'https://mac.local:8765', token: 'a'.repeat(43), workspaceID: 'b'.repeat(64) };
const todo = { id: 'todo-1', title: '原始标题', notes: '原始备注', priority: 1, dueDay: null, revision: 1 };
const drafts = { title: '手机标题', notes: '原始备注', priority: 1, dueDay: null };
const makeState = () => ({ ...emptyState(), pairing, todos: [todo] });
const emptyPage = { result: { items: [], hasMore: false } };

test('a draft can change its destination offline and keeps that destination until the Mac supports it', async () => {
  const fields = { title: '离线草稿', body: '正文', format: 'text' };
  const saved = saveEditor(makeState(), 'articles', null, fields, [], { articleDestination: '工作/设计' });
  const [draft] = saved.articles;
  const [original] = saved.outbox;
  assert.equal(draft.sourceRelativePath, `工作/设计/${draft.slug}.html`);

  const moved = saveEditor(saved, 'articles', draft, fields, [], { articleDestination: '日记/今天' });
  const [operation] = moved.outbox;
  assert.equal(operation.id, original.id);
  assert.equal(operation.params.destinationFolder, '日记/今天');
  assert.equal(moved.articles[0].sourceRelativePath, `日记/今天/${draft.slug}.html`);
  const olderMac = await new SyncEngine(moved, async () => {}, async (action, args) => {
    if (action === 'hello') return { workspaceID: pairing.workspaceID };
    assert.equal(action, 'read');
    return args.method === 'todos.list' ? { result: [] } : emptyPage;
  }).run();
  assert.equal(olderMac.outbox[0].attempted, false);
  assert.match(olderMac.outbox[0].transferError, /升级 Mac/);
  assert.deepEqual(olderMac.articles, moved.articles);

  const defaultFolder = saveEditor(olderMac, 'articles', olderMac.articles[0], fields, [], { articleDestination: '未分类' });
  assert.equal(defaultFolder.outbox[0].params.destinationFolder, undefined);
  assert.equal(defaultFolder.outbox[0].transferError, undefined);
});

test('sync aborts when the response headers arrived but the JSON body stalls', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let reachedBody;
  const reading = new Promise(resolve => { reachedBody = resolve; });
  t.mock.method(globalThis, 'fetch', async (_url, { signal }) => ({
    ok: true,
    status: 200,
    json: () => new Promise((_resolve, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true });
      reachedBody(signal);
    }),
  }));
  const result = request(pairing, 'hello').catch(error => error);
  const signal = await reading;
  t.mock.timers.tick(50_000);
  assert.equal(signal.aborted, true);
  const error = await result;
  assert.equal(error.code, 'sync_timeout');
  assert.match(error.message, /超时/);
});

test('a busy attachment lookup does not make a sync push fail or change its payload', async t => {
  const sent = [];
  t.mock.method(globalThis, 'fetch', async (_url, { body }) => {
    sent.push(body);
    if (sent.length === 1) return { status: 503 };
    return { status: 200, ok: true, json: async () => ({ result: todo }) };
  });
  const push = { id: 'same-operation', method: 'todos.update', params: { id: todo.id, expectedRevision: 1, title: 'changed' } };
  assert.deepEqual(await request(pairing, 'push', push), { result: todo });
  assert.equal(sent.length, 2);
  assert.equal(sent[0], sent[1]);
});

test('loss of response keeps the same payload durable and retry acknowledges it once', async () => {
  const next = saveEditor(makeState(), 'todos', todo, drafts);
  const sent = [];
  let disk = next;
  const persist = async value => { disk = structuredClone(value); };
  let attempts = 0;
  const saved = { ...todo, title: drafts.title, revision: 2 };
  const transport = async (action, args) => {
    if (action === 'hello') return { workspaceID: pairing.workspaceID };
    if (action === 'push') {
      sent.push(args);
      assert.equal(disk.outbox[0].attempted, true);
      if (++attempts === 1) throw new Error('network down after commit');
      return { result: saved };
    }
    return args.method === 'todos.list' ? { result: [saved] } : emptyPage;
  };
  await assert.rejects(() => new SyncEngine(next, persist, transport).run(), /network down/);
  assert.equal(disk.todos[0].title, drafts.title);
  assert.throws(() => saveEditor(disk, 'todos', disk.todos[0], { ...drafts, title: 'again' }), /待确认/);
  const final = await new SyncEngine(disk, persist, transport).run();
  assert.deepEqual(sent[0], sent[1]);
  assert.deepEqual(final.todos, [saved]);
  assert.deepEqual(final.outbox, []);
});

test('conflicting and deleted records preserve mobile edits and allow unrelated write', async () => {
  let state = saveEditor(makeState(), 'todos', todo, drafts);
  const article = { slug: 'alpha', title: 'Mac article', updatedAt: '1', body: '<p>Original</p>' };
  state.articles.push(article);
  state = saveEditor(state, 'articles', article, { title: 'Mobile article', body: article.body, format: 'html' });
  state = saveEditor(state, 'moments', null, { text: 'Independent post' });
  const post = { id: 'new-post', text: 'Independent post' };
  const replies = {
    'todos.update': { error: { code: 'conflict' } },
    'articles.update': { error: { code: 'not_found' } },
    'moments.create': { result: post },
  };
  const remote = { ...todo, title: 'Mac title', revision: 2 };
  const engine = new SyncEngine(state, async () => {}, async (action, args) => {
    if (action === 'hello') return { workspaceID: pairing.workspaceID };
    if (action === 'push') return replies[args.method];
    if (args.method === 'todos.list') return { result: [remote] };
    if (args.method === 'moments.list') return { result: { items: [post], hasMore: false } };
    return emptyPage;
  });
  const synced = await engine.run();
  assert.deepEqual(synced.moments, [post]);
  assert.equal(synced.articles[0].title, 'Mobile article');
  assert.equal(synced.todos[0].title, drafts.title);
  const todoOp = synced.outbox.find(op => op.kind === 'todos');
  const merged = saveEditor(resolveEdit(synced, todoOp, remote), 'todos', remote, { ...drafts, title: '合并标题' });
  assert.equal(merged.outbox.find(op => op.kind === 'todos').params.expectedRevision, 2);
  const articleOp = merged.outbox.find(op => op.kind === 'articles');
  const copied = saveEditor(resolveEdit(merged, articleOp, null), 'articles', undefined, {
    title: 'Mobile article (copy)', body: article.body, format: 'html',
  });
  assert.equal(copied.articles[0].slug, `mobile-${copied.outbox.find(op => op.kind === 'articles').id}`);
  assert.equal(copied.articles.some(item => item.slug === article.slug), false);
});

test('merging an article carries the mobile body forward without overwriting the Mac title', () => {
  const original = { slug: 'article', title: '旧标题', body: '旧正文', updatedAt: 'v1' };
  const local = saveEditor({ ...makeState(), articles: [original] }, 'articles', original, {
    ...editableFields('articles', original), body: '<手机纯文本>',
  });
  const [op] = local.outbox;
  const remote = { ...original, title: 'Mac 新标题', updatedAt: 'v2' };
  const fields = mergeEditorFields('articles', remote, op);
  assert.equal(fields.title, 'Mac 新标题');
  const merged = saveEditor(resolveEdit(local, op, remote), 'articles', remote, fields);
  assert.deepEqual(merged.outbox[0].params, {
    slug: 'article', expectedUpdatedAt: 'v2', body: '<手机纯文本>', format: 'text',
  });
});

test('merging an attachment-only edit retains the Mac body and its format', () => {
  const original = { slug: 'article', title: '旧标题', body: '旧正文', updatedAt: 'v1' };
  const files = [{ id: 'local-image', name: 'image.png', blob: new Blob(['bytes']) }];
  const local = saveEditor({ ...makeState(), articles: [original] }, 'articles', original,
    editableFields('articles', original), files);
  const [op] = local.outbox;
  const remote = { ...original, body: '<p><strong>Mac 富文本</strong></p>', updatedAt: 'v2' };
  const fields = mergeEditorFields('articles', remote, op);
  const merged = saveEditor(resolveEdit(local, op, remote), 'articles', remote, fields, op.files);
  assert.equal(merged.articles[0].body, remote.body);
  assert.equal(merged.articles[0].format, 'html');
  assert.deepEqual(merged.outbox[0].params, { slug: 'article', expectedUpdatedAt: 'v2' });
  assert.equal(merged.outbox[0].files[0].id, 'local-image');
});

test('a reverted offline field is removed from the patch, including after reopening the saved queue', () => {
  const original = { slug: 'article', title: '原始标题', body: '原始正文', updatedAt: 'v1' };
  const baseline = editableFields('articles', original);
  const state = { ...makeState(), articles: [original] };
  const edited = saveEditor(state, 'articles', original, { ...baseline, title: '临时标题', body: '已修改正文' });
  const reopened = structuredClone(edited);
  const kept = saveEditor(reopened, 'articles', reopened.articles[0], { ...baseline, body: '最终正文' });
  const [op] = kept.outbox;
  assert.deepEqual(op.params, { slug: 'article', expectedUpdatedAt: 'v1', body: '最终正文', format: 'text' });
  assert.equal(mergeEditorFields('articles', { ...original, title: 'Mac 新标题' }, op).title, 'Mac 新标题');
  const reverted = saveEditor(kept, 'articles', kept.articles[0], baseline);
  assert.deepEqual(reverted.outbox, []);
  assert.equal(reverted.articles[0].body, original.body);

  delete reopened.outbox[0].baseFields;
  const legacy = saveEditor(reopened, 'articles', reopened.articles[0], baseline);
  assert.equal(legacy.outbox[0].params.title, original.title);
  assert.equal(legacy.outbox[0].params.body, original.body);
});

test('a new library generation preserves pending revisions and files for manual review', async () => {
  const files = [{ id: 'local-image', name: 'image.png', blob: new Blob(['bytes']) }];
  let state = saveEditor({ ...makeState(), syncGeneration: 'initial' }, 'todos', todo, drafts);
  state = saveEditor(state, 'articles', null, { title: 'Offline draft', body: 'Draft body', format: 'text' }, files);
  state.outbox[1].attempted = true;
  let saved;
  const engine = new SyncEngine(state, async next => { saved = structuredClone(next); }, async (action, args) => {
    if (action === 'hello') return { workspaceID: pairing.workspaceID, generation: 'restored' };
    assert.equal(action, 'read');
    assert.equal(args.generation, 'restored');
    return { result: { items: [], total: 0, hasMore: false, snapshot: 'empty' } };
  });
  await engine.run();
  assert.equal(saved.syncGeneration, 'restored');
  assert.deepEqual(saved.outbox.map(op => op.error.code), ['workspace_restored', 'workspace_restored']);
  assert.equal(saved.outbox[1].id, state.outbox[1].id);
  assert.equal(await saved.outbox[1].files[0].blob.text(), 'bytes');
  assert.equal(saved.articles[0].body, 'Draft body');
  assert.equal(saved.todos[0].title, drafts.title);
});

test('legacy size errors cannot authorize a second copy of a possibly applied write', () => {
  const state = saveEditor(makeState(), 'todos', todo, drafts);
  state.outbox[0].attempted = true;
  state.outbox[0].error = { code: 'message_too_large' };
  const verified = { ...state, syncGeneration: 'initial' };
  assert.equal(upgradeSyncState(verified), verified);
  const upgraded = upgradeSyncState(state);
  assert.equal(upgraded.outbox[0].error.code, 'write_unknown');
  assert.equal(upgraded.outbox[0].id, state.outbox[0].id);
  assert.equal(upgraded.todos[0].title, drafts.title);
});

test('a changed page restarts the scan and a failed todo pull leaves complete collections committed', async () => {
  const state = { ...makeState(), syncGeneration: 'initial', lastSync: 'prior sync' };
  const article = { slug: 'article', title: 'Mac article', body: 'Mac body', updatedAt: 'v1' };
  const deleted = { id: 'deleted', text: 'Deleted mid-scan' };
  const remaining = { id: 'remaining', text: 'Still present' };
  const timelineRequests = [];
  const engine = new SyncEngine(state, async () => {}, async (action, { method, params } = {}) => {
    if (action === 'hello') return { workspaceID: pairing.workspaceID, generation: 'initial' };
    if (method === 'articles.list') return { result: { items: [article], total: 1, hasMore: false, snapshot: 'articles' } };
    if (method === 'articles.get') return { result: article };
    if (method === 'todos.list') return { error: { code: 'response_too_large', message: 'Exceeded size limit' } };
    assert.equal(method, 'moments.list');
    timelineRequests.push(params);
    switch (timelineRequests.length) {
      case 1: return { result: { items: [deleted], total: 2, hasMore: true, snapshot: 'before' } };
      case 2: return { error: { code: 'snapshot_changed' } };
      default: return { result: { items: [remaining], total: 1, hasMore: false, snapshot: 'after' } };
    }
  });
  await assert.rejects(engine.run(), /待办/);
  assert.deepEqual(timelineRequests.map(({ offset, snapshot }) => [offset, snapshot]), [[0, ''], [1, 'before'], [0, '']]);
  assert.deepEqual(engine.state.articles, [article]);
  assert.deepEqual(engine.state.moments, [remaining]);
  assert.deepEqual(engine.state.todos, [todo]);
  assert.equal(engine.state.lastSync, 'prior sync');
});

test('a compact receipt confirms a write and the large article is fetched in version-checked parts', async () => {
  let state = { ...makeState(), syncGeneration: 'initial' };
  state = saveEditor(state, 'articles', null, { title: 'Local title', body: 'Local draft', format: 'text' });
  const [{ key: slug }] = state.outbox;
  const summary = { slug, title: 'Mac title', updatedAt: 'v1' };
  const requests = [];
  const engine = new SyncEngine(state, async () => {}, async (action, args) => {
    if (action === 'hello') return { workspaceID: pairing.workspaceID, generation: 'initial' };
    if (action === 'push') {
      assert.equal(args.compact, true);
      return { result: { slug, updatedAt: 'v1', status: 'draft' }, receipt: true };
    }
    if (args.method === 'articles.get') {
      requests.push(args.params);
      if (args.params.bodyOffset === undefined) return { error: { code: 'response_too_large' } };
      if (args.params.bodyOffset === 0) return { result: { article: summary, updatedAt: 'v1', body: '一🙂', nextOffset: 7 } };
      assert.deepEqual(args.params, { slug, bodyOffset: 7, expectedUpdatedAt: 'v1' });
      return { result: { updatedAt: 'v1', body: '二', nextOffset: null } };
    }
    const items = args.method === 'articles.list' ? [summary] : [];
    return { result: { items, total: items.length, hasMore: false, snapshot: 'checked' } };
  });
  const synced = await engine.run();
  assert.equal(requests.length, 3);
  assert.deepEqual(synced.outbox, []);
  assert.deepEqual(synced.articles, [{ ...summary, body: '一🙂二' }]);
});

test('a shifted page cannot remove a cached article that still exists', async () => {
  const retained = { slug: 'retained', title: 'Retained', updatedAt: 'now', body: '<p>Still here</p>' };
  const deleted = { slug: 'deleted', title: 'Deleted', updatedAt: 'now', body: '<p>Gone</p>' };
  const state = { ...makeState(), articles: [retained, deleted] };
  const engine = new SyncEngine(state, async () => {}, async (action, args) => {
    if (action === 'hello') return { workspaceID: pairing.workspaceID };
    if (args.method === 'todos.list') return { result: [] };
    if (args.method === 'articles.get') {
      return args.params.slug === 'retained' ? { result: retained } : { error: { code: 'not_found' } };
    }
    return emptyPage;
  });
  assert.deepEqual((await engine.run()).articles, [retained]);
});

test('changing only a title preserves rich article body and completion uses todo revision', () => {
  const item = { slug: 'original', title: 'Original', body: '<article><img src="local"></article>', updatedAt: 'v1' };
  const changed = saveEditor({ ...makeState(), articles: [item] }, 'articles', item, { ...itemFields(item), title: 'New title' });
  assert.deepEqual(changed.outbox[0].params, { slug: 'original', title: 'New title', expectedUpdatedAt: 'v1' });
  assert.deepEqual(completeTodo(makeState(), todo, 'now').outbox[0].params, { id: todo.id, expectedRevision: 1, completed: true });
});

function itemFields(item) { return { title: item.title, body: item.body, format: 'html' }; }

test('certificate-free pairing accepts private IPs while public cleartext and non-origin URLs are rejected', () => {
  assert.deepEqual(parsePairing(JSON.stringify(pairing)), pairing);
  for (const host of ['192.168.1.8', '10.0.0.9', '172.16.0.1', '172.31.255.254', '127.0.0.1', '[::1]']) {
    const lan = { ...pairing, url: `http://${host}:8765` };
    assert.deepEqual(parsePairing(JSON.stringify(lan)), lan);
  }
  for (const host of ['8.8.8.8', '0.0.0.0', '172.15.0.1', '172.32.0.1', '192.169.0.1', 'example.com']) {
    assert.throws(() => parsePairing(JSON.stringify({ ...pairing, url: `http://${host}:8765` })), /配对信息无效/);
  }
  assert.throws(() => parsePairing(JSON.stringify({ ...pairing, url: 'http://192.168.1.8:8765/redirect' })));
  assert.throws(() => parsePairing(JSON.stringify({ ...pairing, url: 'https://mac.local/path' })));
});
