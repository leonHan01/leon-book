import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

// Exercise the shipping drop listener without launching WebKit or the app.
const source = await readFile(new URL('../Sources/LeonBook/Resources/RichArticleAudio.js', import.meta.url), 'utf8');
function editor({ editable = true } = {}) {
  const listeners = new Map(), messages = [];
  const block = {
    tagName: 'P', textContent: 'Keep this paragraph', outerHTML: '<p>Keep this paragraph</p>',
    querySelector: () => null,
    getBoundingClientRect: () => ({ top: 0, bottom: 40, height: 40 }),
  };
  const root = {
    dataset: {}, children: [block], lastElementChild: block,
    contains: node => node === block,
    addEventListener: (name, listener) => listeners.set(name, listener),
  };
  block.parentElement = root;
  const button = { querySelector: () => null };
  const context = vm.createContext({
    window: { addEventListener() {}, LeonL10n: { text: value => value } },
    document: { querySelector: () => button },
  });
  vm.runInContext(source, context);
  let id = 0;
  const api = context.createArticleAudio({
    root, canEdit: () => editable, documentID: () => 'article',
    send: message => messages.push(message), uuid: () => String(++id),
    checkpoint() {}, notify() {}, focusBlock() {}, closeMenu() {},
  });
  function dispatch(type, files) {
    const event = {
      target: block, clientY: 35, defaultPrevented: false,
      dataTransfer: { files, items: files.map(file => ({ kind: 'file', type: file.type })), dropEffect: '' },
      preventDefault() { this.defaultPrevented = true; }, stopImmediatePropagation() {},
    };
    listeners.get(type)(event);
    return event;
  }
  return { root, block, messages, dispatch, api };
}

for (const files of [
  [{ name: 'recording.MP3', type: 'audio/mpeg' }],
  [{ name: 'video.mp4', type: 'video/mp4' }],
  [{ name: 'photo.png', type: 'image/png' }],
  [{ name: 'photo.jpg', type: 'image/jpeg' }, { name: 'video.mov', type: 'video/quicktime' }, { name: 'recording.mp3', type: '' }],
]) {
  const test = editor();
  assert.equal(test.dispatch('dragover', files).defaultPrevented, true, `${files[0].name}: drag must be accepted`);
  assert.equal(test.dispatch('drop', files).defaultPrevented, true, `${files[0].name}: drop must be consumed`);
  assert.equal(test.messages.length, 1, 'drop must request native import once');
  assert.equal(test.messages[0].type, 'dropMedia', 'use the general native media importer');
  assert.deepEqual(Array.from(test.messages[0].names), files.map(file => file.name), 'preserve mixed-file order');
  test.dispatch('drop', files);
  assert.equal(test.messages.length, 1, 'a pending import must block duplicate drops');
}

for (const files of [
  [{ name: 'document.txt', type: 'text/plain' }],
  [{ name: 'photo.png', type: 'image/png' }, { name: 'document.txt', type: 'text/plain' }],
]) {
  const test = editor();
  assert.equal(test.dispatch('drop', files).defaultPrevented, true, 'unsupported files must not navigate away from the article');
  assert.equal(test.messages.length, 0, 'reject unsupported batches without partially importing');
}

const stale = editor();
stale.dispatch('drop', [{ name: 'video.mp4', type: 'video/mp4' }]);
const requestID = stale.messages[0].requestID;
assert.equal(stale.api.completeMedia(requestID, [{ source: 'file:///tmp/video.mp4', kind: 'video' }]), false, 'persist only workspace paths');
assert.equal(stale.api.completeMedia(requestID, [{ source: '/media/inbox/video.mp4', kind: 'audio' }]), false, 'reject mismatched media kinds');
stale.block.outerHTML = '<p>Newer edits</p>';
assert.equal(stale.api.completeMedia(requestID, [{ source: '/media/inbox/video.mp4', kind: 'video' }]), false, 'never overwrite text edited during import');
stale.api.cancel(requestID);
assert.equal(stale.api.completeMedia(requestID, [{ source: '/media/inbox/video.mp4', kind: 'video' }]), false, 'cancelled requests must not insert');

const reader = editor({ editable: false });
reader.dispatch('drop', [{ name: 'video.mp4', type: 'video/mp4' }]);
assert.equal(reader.messages.length, 0, 'read-only articles must not import media');
console.log('PASS: image, video, MP3, mixed-file drops, and read-only protection');
