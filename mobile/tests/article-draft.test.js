import assert from 'node:assert/strict';
import test from 'node:test';
import { autosaveArticleDraft } from '../src/article-draft.js';

test('explicit save stops outstanding autosaves before removing the draft', async () => {
  let read = 'first edit';
  let unblock;
  const blocked = new Promise(resolve => { unblock = resolve; });
  const writes = [];
  const draft = autosaveArticleDraft(() => read, async value => {
    writes.push(value);
    await blocked;
  }, () => {}, false);

  draft.changed();
  const flushing = draft.flush();
  await Promise.resolve();
  read = 'final version submitted explicitly';
  draft.changed();
  const settling = draft.settle();
  unblock();
  await Promise.all([settling, flushing]);
  assert.deepEqual(writes, ['first edit']);
});
