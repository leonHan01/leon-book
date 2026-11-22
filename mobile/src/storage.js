import { attachmentCacheLimit } from '../shared/attachments.js';

// One transaction holds the cache and outbox together: a saved edit cannot lose
// its sync intent. Do not silently fall back to ephemeral memory on disk errors.
let connection;
function database() {
  connection ??= new Promise((resolve, reject) => {
    const request = indexedDB.open('leonbook-mobile', 3);
    request.onupgradeneeded = event => {
      if (event.oldVersion < 1) request.result.createObjectStore('state');
      if (event.oldVersion < 2) {
        const files = request.result.createObjectStore('attachments');
        files.createIndex('retention', ['usedAt', 'size']);
      }
      if (event.oldVersion < 3) request.result.createObjectStore('articleDrafts');
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error('请关闭其他 LeonBook 页面后重试。'));
  });
  return connection;
}
export async function loadState() {
  const db = await database();
  return new Promise((resolve, reject) => {
    const tx = db.transaction('state', 'readonly');
    const request = tx.objectStore('state').get('current');
    tx.oncomplete = () => resolve(request.result ?? null);
    tx.onabort = () => reject(tx.error);
    tx.onerror = () => reject(tx.error);
  });
}
const draftRange = workspace => IDBKeyRange.bound([workspace], [workspace, []]);

export async function saveState(state, { clearAttachments = false, removeDraft, adoptLocalDrafts } = {}) {
  const db = await database();
  return new Promise((resolve, reject) => {
    const stores = ['state'];
    if (clearAttachments) stores.push('attachments');
    if (removeDraft || adoptLocalDrafts) stores.push('articleDrafts');
    const tx = db.transaction(stores, 'readwrite');
    tx.objectStore('state').put(structuredClone(state), 'current');
    if (clearAttachments) tx.objectStore('attachments').clear();
    if (removeDraft) tx.objectStore('articleDrafts').delete(removeDraft);
    if (adoptLocalDrafts) {
      const drafts = tx.objectStore('articleDrafts');
      const cursor = drafts.openCursor(draftRange(''));
      cursor.onsuccess = () => {
        const entry = cursor.result;
        if (!entry) return;
        drafts.put(entry.value, [adoptLocalDrafts, entry.key[1]]);
        entry.delete();
        entry.continue();
      };
    }
    tx.oncomplete = resolve;
    tx.onabort = () => reject(tx.error ?? new Error('本机存储失败，请保留编辑内容后重试。'));
    tx.onerror = () => reject(tx.error);
  });
}

async function articleDraftTransaction(mode, action) {
  const db = await database();
  return new Promise((resolve, reject) => {
    const tx = db.transaction('articleDrafts', mode);
    const request = action(tx.objectStore('articleDrafts'));
    tx.oncomplete = () => resolve(request.result);
    tx.onabort = () => reject(tx.error ?? new Error('无法将草稿保存到手机。'));
    tx.onerror = () => reject(tx.error);
  });
}

export const loadArticleDrafts = workspace => articleDraftTransaction('readonly', store => store.getAll(draftRange(workspace)));
export const saveArticleDraft = (key, draft) => articleDraftTransaction('readwrite', store => store.put(draft, key));
export const removeArticleDraft = key => articleDraftTransaction('readwrite', store => store.delete(key));

async function attachmentsTransaction(action) {
  const db = await database();
  return new Promise((resolve, reject) => {
    const tx = db.transaction('attachments', 'readwrite');
    let result;
    tx.oncomplete = () => resolve(result);
    tx.onabort = () => reject(tx.error ?? new Error('附件缓存操作未完成。'));
    action(tx.objectStore('attachments'), value => { result = value; });
  });
}

export function loadAttachment(workspaceID, ref) {
  return attachmentsTransaction((store, setResult) => {
    const key = [workspaceID, ref.path];
    const request = store.get(key);
    request.onsuccess = () => {
      const cached = request.result;
      if (!cached || cached.expectedSize !== ref.size) return;
      store.put({ ...cached, usedAt: Date.now() }, key);
      setResult(cached.blob);
    };
  });
}

export function storeAttachment(workspaceID, ref, blob) {
  return attachmentsTransaction(store => {
    const key = [workspaceID, ref.path];
    const older = [];
    let bytes = blob.size;
    // A key cursor scans metadata without materializing the stored blobs.
    const scan = store.index('retention').openKeyCursor();
    scan.onsuccess = () => {
      const cursor = scan.result;
      if (cursor) {
        const oldKey = cursor.primaryKey;
        if (indexedDB.cmp(oldKey, key) !== 0) {
          const size = cursor.key[1];
          older.push({ key: oldKey, size });
          bytes += size;
        }
        cursor.continue();
        return;
      }
      for (const entry of older) {
        if (bytes <= attachmentCacheLimit) break;
        store.delete(entry.key);
        bytes -= entry.size;
      }
      store.put({ blob, size: blob.size, usedAt: Date.now(), expectedSize: ref.size }, key);
    };
  });
}

export function clearAttachmentCache() {
  return attachmentsTransaction(store => store.clear());
}
