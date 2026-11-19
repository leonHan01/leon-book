import test from 'node:test';
import assert from 'node:assert/strict';
import { completeTodo, saveEditor } from '../src/editor.js';
import { emptyState, parsePairing, resolveEdit, SyncEngine } from '../src/sync.js';

const pairing = { url: 'https://mac.local:8765', token: 'a'.repeat(43), workspaceID: 'b'.repeat(64) };
const todo = { id: 'todo-1', title: '原始标题', notes: '原始备注', priority: 1, dueDay: null, revision: 1 };
const drafts = { title: '手机标题', notes: '原始备注', priority: 1, dueDay: null };
const makeState = () => ({ ...emptyState(), pairing, todos: [todo] });
const emptyPage = { result: { items: [], hasMore: false } };

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

test('private LAN pairing requires HTTPS and a bare origin', () => {
  assert.deepEqual(parsePairing(JSON.stringify(pairing)), pairing);
  assert.throws(() => parsePairing(JSON.stringify({ ...pairing, url: 'http://192.168.1.8:8765' })));
  assert.throws(() => parsePairing(JSON.stringify({ ...pairing, url: 'https://mac.local/path' })));
});
