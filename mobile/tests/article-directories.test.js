import assert from 'node:assert/strict';
import test from 'node:test';
import { articleFolderPath, buildArticleDirectory, parentFolderPath } from '../src/article-directories.js';

test('cached article paths preserve hierarchy without a directory response from Mac', () => {
  const first = { sourceRelativePath: '工作/设计/one.md', category: '其他' };
  const second = { sourceRelativePath: '生活\\设计\\second.html' };
  const draft = { title: '手机草稿' };
  const tree = buildArticleDirectory([first, second, draft]);
  assert.deepEqual(tree.get('').articles, []);
  assert.deepEqual(tree.get('工作').folders.map(folder => folder.name), ['设计']);
  assert.deepEqual(tree.get('工作/设计').articles, [first]);
  assert.deepEqual(tree.get('生活/设计').articles, [second]);
  assert.deepEqual(tree.get('未分类').articles, [draft]);
  assert.equal(parentFolderPath('工作/设计'), '工作');
  assert.equal(parentFolderPath('工作'), '');
});

test('folder listings merge with article paths, NFC and the Mac depth limit', () => {
  const article = { sourceRelativePath: 'Cafe\u0301/设计/notes.md' };
  const tree = buildArticleDirectory([article], ['Café/设计/空目录', '一/二/三/四/五/六']);
  assert.deepEqual(tree.get('Café').folders.map(folder => folder.name), ['设计']);
  assert.deepEqual(tree.get('Café/设计').articles, [article]);
  assert.deepEqual(tree.get('Café/设计/空目录').articles, []);
  assert.equal(tree.has('一/二/三/四/五'), true);
  assert.equal(tree.has('一/二/三/四/五/六'), false);
  assert.equal(articleFolderPath({ sourceRelativePath: '一/二/三/四/五/六/file.html' }), '一/二/三/四/五');
  assert.equal(articleFolderPath({ sourceRelativePath: 'root.md' }), '未分类');
});
