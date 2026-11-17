import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const context = vm.createContext({});
vm.runInContext(await readFile(new URL('../Sources/LeonBook/Resources/RichArticleBodyBridge.js', import.meta.url), 'utf8'), context);
const opening = '<article data-leon-format="html-v1">', closing = '</article>';
let native = '', revision = 0, messages = [];
const bridge = context.createArticleBodyBridge(message => {
  assert.equal(message.baseRevision, revision);
  if (message.patch) {
    const { offset, removedLength, text, baseLength } = message.patch;
    assert.equal(baseLength, native.length);
    native = native.slice(0, offset) + text + native.slice(offset + removedLength);
  } else native = message.body;
  revision = message.revision;
  messages.push(message);
});
function reset(parts, source = parts.join('')) {
  native = source; revision = 0; messages = [];
  bridge.reset(source, parts.join(''), parts, 'test-session');
}
function publish(parts) {
  const expected = parts.join('');
  bridge.publish(expected, parts);
  assert.equal(native, expected, 'native body must be current before publish returns');
}
const original = [opening, ...Array.from({ length: 2000 }, (_, index) => `<p data-block-id="${index}">${'正文😀'.repeat(20)}</p>`), closing];
reset(original);
let parts = original;
for (let edit = 0; edit < 100; edit++) {
  parts = parts.slice(); parts[1000] = `<p data-block-id="999">新增😀${edit}</p>`; publish(parts);
}
assert.equal(messages.length, 100);
assert(messages.every(message => message.patch), 'local edits must avoid full body messages');
const characters = messages.reduce((sum, message) => sum + message.patch.text.length, 0);
assert(characters < 10000, 'wire content must scale with changed blocks');
publish(parts); assert.equal(messages.length, 100, 'unchanged notifications must be skipped');
parts = parts.slice(); parts.splice(30, 3, '<p>替换👩‍💻</p>'); publish(parts);
parts = [opening, '<p>粘贴</p>', ...parts.slice(1)]; publish(parts);
publish(original); // undo / complete replacement
reset(original, opening + '<p>未规范化</p>' + closing); publish(original);
assert(messages[0].body, 'first normalized body must establish a complete baseline');
bridge.publish(native, original, true);
assert(messages.at(-1).body, 'resynchronization must provide a complete snapshot');
console.log(`PASS article body bridge: 100 immediate edits, ${characters} changed characters instead of full documents; Unicode, undo, replacement and resync verified`);
