import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdir, mkdtemp, readdir, readFile, realpath, rm, symlink, truncate, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeBridge } from '../server/bridge.js';
import { automate } from '../server/main.js';
import { attachmentLimit } from '../shared/attachments.js';
import { request } from '../src/sync.js';

async function listen(bridge, t) {
  await new Promise((resolve, reject) => {
    bridge.server.once('error', reject);
    bridge.server.listen(0, '127.0.0.1', resolve);
  });
  t.after(() => new Promise(resolve => bridge.server.close(resolve)));
  return `http://127.0.0.1:${bridge.server.address().port}/v1/sync`;
}

const workspaceID = 'a'.repeat(64);
const picture = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jLZ0AAAAASUVORK5CYII=', 'base64');
function call(url, token, data, origin = 'https://localhost') {
  return fetch(url, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify({ workspaceID, ...data }),
  });
}

test('bridge restricts callers and never replays acknowledged or uncertain writes', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'leonbook-bridge-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const databasePath = join(directory, 'journal.sqlite');
  let calls = 0;
  const bridge = makeBridge({ databasePath, workspaceID, automation: async (_method, params) => {
    calls++;
    if (params.text === 'uncertain') throw new Error('lost after write');
    return { result: { id: 'saved', text: params.text } };
  } });
  const url = await listen(bridge, t);
  const request = { action: 'push', id: '62de177a-bd2f-414c-a957-3001992f8f40', method: 'moments.create', params: { text: 'save once' } };
  assert.equal((await call(url, 'incorrect', request)).status, 401);
  assert.equal((await call(url, bridge.token, request, 'https://example.test')).status, 403);
  assert.equal((await call(url, bridge.token, { action: 'read', method: 'backup.list', params: {} })).status, 400);
  assert.equal((await call(url, bridge.token, { ...request, method: 'users.select' })).status, 200);
  assert.equal(calls, 0);
  const first = await (await call(url, bridge.token, request)).json();
  assert.deepEqual(first, { result: { id: 'saved', text: 'save once' } });
  assert.deepEqual(await (await call(url, bridge.token, request)).json(), first);
  assert.equal((await (await call(url, bridge.token, { ...request, params: { text: 'different' } })).json()).error.code, 'invalid_request');
  assert.equal(calls, 1);
  const uncertain = { ...request, id: 'af44c926-5abb-4981-973c-edae69ac8772', params: { text: 'uncertain' } };
  assert.equal((await (await call(url, bridge.token, uncertain)).json()).error.code, 'write_unknown');
  assert.equal((await (await call(url, bridge.token, uncertain)).json()).error.code, 'write_unknown');
  // Simulate a process ending between the content write and recording its result.
  const journal = new DatabaseSync(databasePath);
  journal.prepare('UPDATE mobile_operations SET response = NULL WHERE id = ?').run(uncertain.id);
  journal.close();
  const restarted = makeBridge({ databasePath, workspaceID, automation: async () => { calls++; throw new Error('must not run'); } });
  const newURL = await listen(restarted, t);
  assert.deepEqual(await (await call(newURL, restarted.token, request)).json(), first);
  assert.equal((await (await call(newURL, restarted.token, uncertain)).json()).error.code, 'write_unknown');
  assert.equal(calls, 2);
});

test('bridge syncs with the real Mac CLI and preserves concurrent Mac changes', { skip: !process.env.LEONBOOK_TEST_CLI }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'leonbook-cli-sync-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const root = join(directory, 'library');
  const cli = (method, params) => automate(process.env.LEONBOOK_TEST_CLI, root, undefined, method, params);
  const info = await cli('workspace.info', {});
  assert.ok(info.result?.user.id);
  const bridge = makeBridge({ databasePath: join(directory, 'journal.sqlite'), workspaceID,
    workspacePath: join(await realpath(root), 'workspaces', info.result.user.id), automation: cli });
  const url = await listen(bridge, t);
  const talk = async input => (await call(url, bridge.token, input)).json();
  const push = (id, method, params) => talk({ action: 'push', id, method, params });
  const articleID = '41c6537b-5fd0-47be-9cb2-cd493a27030b';
  const slug = `mobile-${articleID}`;
  const created = await push(articleID, 'articles.create', { slug, title: '手机草稿', body: '第一版正文', format: 'text' });
  assert.equal(created.result?.slug, slug, JSON.stringify(created));
  const mac = await cli('articles.update', { slug, expectedUpdatedAt: created.result.updatedAt, title: 'Mac 上编辑过' });
  assert.equal(mac.result?.title, 'Mac 上编辑过');
  const conflict = await push('8e13e1ad-c028-4d85-8b7f-e28a60e95f9f', 'articles.update', {
    slug, expectedUpdatedAt: created.result.updatedAt, body: '手机离线编辑', format: 'text',
  });
  assert.equal(conflict.error?.code, 'conflict');
  const fetched = await talk({ action: 'read', method: 'articles.get', params: { slug } });
  assert.equal(fetched.result?.title, 'Mac 上编辑过');
  assert.match(fetched.result.body, /第一版正文/);

  const moment = await push('35bc0460-a749-4d8d-bafd-422c17a82283', 'moments.create', { text: '手机微博' });
  assert.equal(moment.result?.text, '手机微博');
  const todo = await push('65c33288-80e1-4656-9e1f-81cdac104048', 'todos.create', { title: '手机待办' });
  assert.equal(todo.result?.title, '手机待办');
  const completed = await push('53cb111c-db18-419c-ad83-623ba104c5cf', 'todos.complete', {
    id: todo.result.id, expectedRevision: todo.result.revision, completed: true,
  });
  assert.ok(completed.result?.completedAt);

  const source = join(directory, 'picture.png');
  await writeFile(source, picture);
  const uploaded = (await cli('media.upload', { path: source, kind: 'image', slug: 'moments' })).result;
  assert.ok(uploaded?.url);
  const post = (await cli('moments.create', { text: '带附件的微博', images: [uploaded] })).result;
  assert.equal(post?.images[0].url, uploaded.url);
  const attachment = (kind, key, path) => call(url, bridge.token, { action: 'attachment', kind, key, path });
  const response = await attachment('moments', post.id, uploaded.url);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'image/png');
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), picture);
  assert.equal((await attachment('moments', moment.result.id, uploaded.url)).status, 404);
});

test('attachment upload retries validate bytes before returning a journaled result', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'leonbook-upload-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  let calls = 0;
  const bridge = makeBridge({ workspaceID, databasePath: join(directory, 'journal.sqlite'), automation: async (method, payload) => {
    assert.equal(method, 'mobile.saveWithAttachments');
    assert.equal(payload.method, 'moments.create');
    assert.equal(payload.files[0].name, '手机图片.png');
    assert.equal(payload.files[0].kind, 'image');
    assert.deepEqual(await readFile(payload.files[0].path), picture);
    calls++;
    return { result: { id: 'published', images: [{ name: '手机图片.png' }] } };
  } });
  const endpoint = await listen(bridge, t);
  const pairing = { url: new URL(endpoint).origin, token: bridge.token, workspaceID };
  const file = { id: 'c4b2d863-c279-4f13-8125-817a23a57a1a', name: '手机图片.png', blob: new Blob([picture]) };
  const edit = { id: '1fe68539-c1b1-4812-bda2-23a4718bf21a', method: 'moments.create', params: {}, files: [file] };
  const first = await request(pairing, 'push', edit);
  assert.equal(first.result?.id, 'published', JSON.stringify(first));
  assert.deepEqual(await request(pairing, 'push', edit), first);
  const changed = await request(pairing, 'push', { ...edit, files: [{ ...file, blob: new Blob(['different bytes']) }] });
  assert.equal(changed.error?.code, 'invalid_request');
  const unsupported = await request(pairing, 'push', { ...edit, files: [{ ...file, name: 'document.pdf' }] });
  assert.equal(unsupported.error?.code, 'invalid_params');
  assert.equal(calls, 1);
});

test('Mac saves uploads along with the record and preserves existing files across conflicts', { skip: !process.env.LEONBOOK_TEST_CLI }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'leonbook-real-upload-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const root = join(directory, 'library');
  const cli = (method, params) => automate(process.env.LEONBOOK_TEST_CLI, root, undefined, method, params);
  const info = (await cli('workspace.info', {})).result;
  assert.ok(info?.user.id);
  const workspacePath = join(await realpath(root), 'workspaces', info.user.id);
  const bridge = makeBridge({ workspacePath, workspaceID, databasePath: join(directory, 'journal.sqlite'), automation: cli });
  const endpoint = await listen(bridge, t);
  const pairing = { url: new URL(endpoint).origin, token: bridge.token, workspaceID };
  const photo = { id: 'fb34dd41-d4c5-48cc-81ce-a24026011ccb', name: '手机照片.png', blob: new Blob([picture]) };
  const post = await request(pairing, 'push', { id: 'd72b9371-e84b-40c7-b7db-6bed9c762d9d', method: 'moments.create', params: {}, files: [photo] });
  assert.equal(post.result?.images[0]?.name, '手机照片.png', JSON.stringify(post));
  assert.equal(post.result.text, '');
  const postUpdate = { id: 'cee53aaa-3439-4a1e-978f-1c7e1203e1a3', method: 'moments.update',
    params: { id: post.result.id, expectedUpdatedAt: post.result.updatedAt }, files: [photo] };
  const editedPost = await request(pairing, 'push', postUpdate);
  assert.equal(editedPost.result?.images.length, 2);
  assert.equal(editedPost.result.images[0].url, post.result.images[0].url);

  const createID = '110ee745-6827-42f7-98ba-28b16d090eea';
  const slug = `mobile-${createID}`;
  const create = { id: createID, method: 'articles.create', params: { slug, body: '正文', format: 'text', title: '手机文章' }, files: [photo] };
  const article = await request(pairing, 'push', create);
  assert.equal(article.result?.media[0]?.name, '手机照片.png', JSON.stringify(article));
  assert.ok(article.result.media[0].url.startsWith(`/media/${slug}/`));
  assert.deepEqual(await request(pairing, 'push', create), article);
  const changed = (await cli('articles.update', { slug, expectedUpdatedAt: article.result.updatedAt, title: 'Mac 改过' })).result;
  assert.equal(changed?.title, 'Mac 改过');
  const action = { id: '7709ef0f-cee4-4458-b31c-2791d88467d5', method: 'articles.update',
    params: { slug, expectedUpdatedAt: article.result.updatedAt, title: '手机修改' }, files: [photo] };
  const conflict = await request(pairing, 'push', action);
  assert.equal(conflict.error?.code, 'conflict');
  assert.equal((await cli('articles.get', { slug })).result.media.length, 1);
  assert.deepEqual(await readdir(join(workspacePath, 'media', 'inbox')), []);
  assert.equal((await readdir(join(workspacePath, 'media', slug))).length, 1);

  const invalid = await request(pairing, 'push', { ...action, id: 'b847025c-62d5-4869-a13f-d5161a991fb3',
    params: { slug, expectedUpdatedAt: changed.updatedAt, body: ' ', format: 'text' } });
  assert.equal(invalid.error?.code, 'validation_error');
  assert.deepEqual(await readdir(join(workspacePath, 'media', 'inbox')), []);
});

test('downloads require a current attachment reference and reject links, traversal and oversized media', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'leonbook-attachment-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const parent = await realpath(directory);
  const workspacePath = join(parent, 'workspace');
  const media = join(workspacePath, 'media', 'article');
  const external = join(parent, 'external');
  await mkdir(media, { recursive: true });
  await mkdir(external);
  await writeFile(join(external, 'private.png'), 'other workspace content');
  await writeFile(join(media, '封面.png'), 'image bytes');
  await writeFile(join(media, 'large.mp4'), 'bytes');
  await truncate(join(media, 'large.mp4'), attachmentLimit + 1);
  await writeFile(join(media, 'document.html'), '<html></html>');
  await symlink(join(external, 'private.png'), join(media, 'link.png'));
  await symlink(external, join(workspacePath, 'media', 'external'));
  let deleted = false;
  const bridge = makeBridge({
    workspacePath, workspaceID, databasePath: join(directory, 'operations.sqlite'),
    automation: async (method, params) => {
      assert.equal(method, 'articles.get');
      if (deleted || params.slug !== 'article') return { error: { code: 'not_found' } };
      return { result: { banner: { url: '/media/article/封面.png' }, media: [
        { url: '/media/article/link.png', kind: 'image' }, { url: '/media/external/private.png', kind: 'image' },
        { url: '/media/article/large.mp4', kind: 'video' }, { url: '/media/article/document.html', kind: 'file' },
      ] } };
    },
  });
  const url = await listen(bridge, t);
  const download = (path, token = bridge.token) => call(url, token, { action: 'attachment', kind: 'articles', key: 'article', path });
  assert.equal((await download('/media/article/封面.png', 'invalid')).status, 401);
  for (const path of ['/media/article/%2e%2e', '/media/article/%2fexternal', '/media/article/missing.png',
    '/media/article/link.png', '/media/external/private.png', 'https://elsewhere.test/media/article/封面.png']) {
    assert.equal((await download(path)).status, 404, path);
  }
  assert.equal((await download('/media/article/large.mp4')).status, 413);
  const image = await download('/media/article/%E5%B0%81%E9%9D%A2.png');
  assert.equal(image.status, 200);
  assert.equal(await image.text(), 'image bytes');
  const document = await download('/media/article/document.html');
  assert.equal(document.headers.get('content-type'), 'application/octet-stream');
  assert.equal(document.headers.get('content-disposition'), 'attachment');
  assert.equal(await document.text(), '<html></html>');
  deleted = true;
  assert.equal((await download('/media/article/封面.png')).status, 404);
});
