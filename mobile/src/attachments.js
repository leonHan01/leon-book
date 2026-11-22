import { Capacitor } from '@capacitor/core';
import { Directory, Filesystem } from '@capacitor/filesystem';
import { Share } from '@capacitor/share';
import { attachmentKind, attachmentLimit, attachmentType, mediaPath } from '../shared/attachments.js';
import { uuid } from './editor.js';
import { loadAttachment, storeAttachment } from './storage.js';
import { fetchWithBusyRetry } from './sync.js';

const attachmentErrors = {
  401: '配对已失效，请重新连接 Mac。',
  404: 'Mac 上找不到这个附件。请同步后重试。',
  413: '附件超过 32 MB，请在 Mac 查看。',
  503: 'Mac 正在处理其他同步请求，请稍后重试。',
};

async function fetchAttachment(pairing, kind, key, ref, signal) {
  const controller = new AbortController();
  const cancel = () => controller.abort();
  signal.addEventListener('abort', cancel, { once: true });
  if (signal.aborted) cancel();
  const timeout = setTimeout(cancel, 90_000);
  try {
    let response;
    try {
      response = await fetchWithBusyRetry(() => fetch(`${pairing.url}/v1/sync`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${pairing.token}` },
        body: JSON.stringify({ action: 'attachment', workspaceID: pairing.workspaceID, kind, key, path: ref.path }),
        cache: 'no-store', redirect: 'error', signal: controller.signal,
      }), controller.signal);
    } catch {
      throw new Error('无法连接 Mac，请检查同步服务和网络。');
    }
    if (!response.ok) throw new Error(attachmentErrors[response.status] ?? 'Mac 暂时无法读取该附件。');
    const mime = response.headers.get('Content-Type')?.split(';')[0] || 'application/octet-stream';
    const length = response.headers.get('Content-Length');
    if (length !== null && Number(length) > attachmentLimit) {
      cancel();
      throw new Error(attachmentErrors[413]);
    }
    const reader = response.body?.getReader();
    const chunks = [];
    let size = 0;
    if (reader) {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > attachmentLimit) {
          await reader.cancel();
          throw new Error(attachmentErrors[413]);
        }
        chunks.push(value);
      }
    }
    if (length !== null && size !== Number(length)) throw new Error('附件下载不完整，请重试。');
    return new Blob(chunks, { type: mime });
  } finally {
    clearTimeout(timeout);
    signal.removeEventListener('abort', cancel);
  }
}

export async function downloadAttachment(pairing, kind, key, ref, signal) {
  const blob = await fetchAttachment(pairing, kind, key, ref, signal);
  if (signal.aborted) return null;
  try {
    await storeAttachment(pairing.workspaceID, ref, blob);
    return { blob, cached: true };
  } catch {
    return { blob, cached: false };
  }
}

let prepareExport;
async function shareFile(blob, name) {
  // Remove transient files from previous launches before staging a new export.
  prepareExport ??= Filesystem.rmdir({ directory: Directory.Cache, path: 'leonbook-share', recursive: true }).catch(() => {});
  await prepareExport;
  const contents = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result.split(',', 2)[1]);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
  const { uri } = await Filesystem.writeFile({
    path: `leonbook-share/${uuid()}/${name}`, directory: Directory.Cache, data: contents, recursive: true,
  });
  await Share.share({ files: [uri], dialogTitle: '导出附件' });
}

function exportAttachment(blob, ref) {
  const fallback = decodeURIComponent(ref.path.split('/').at(-1));
  const name = ref.name.replace(/[\u0000-\u001f\u007f/\\:*?"<>|]/g, '_').replace(/^\.+/, '').trim();
  const filename = name && new TextEncoder().encode(name).length <= 200 ? name : fallback;
  if (Capacitor.isNativePlatform()) return shareFile(blob, filename);
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1_000);
}

function previewTag(mime) {
  if (/^image\/(jpeg|png|gif|webp|avif|heic|heif)$/.test(mime)) return 'img';
  if (/^audio\/(?:mpeg|mp4|wav|ogg|aac)$/.test(mime)) return 'audio';
  if (/^video\/(?:mp4|quicktime|webm)$/.test(mime)) return 'video';
}

export function previewImageBlob(blob, name) {
  const mime = blob.type.startsWith('image/') ? blob.type : attachmentType(name, 'image');
  if (previewTag(mime) === 'img') return mime === blob.type ? blob : blob.slice(0, blob.size, mime);
  return null;
}

export async function cacheUploadedAttachments(pairing, method, record, files) {
  const items = method.startsWith('articles.') ? record.uploadedAttachments ?? record.media : record.images;
  if (!Array.isArray(items) || items.length < files.length) return;
  const added = items.slice(-files.length);
  for (const [index, file] of files.entries()) {
    const saved = added[index];
    const path = mediaPath(saved.url);
    if (path && saved.name === file.name && saved.size === file.blob.size) {
      const type = attachmentType(decodeURIComponent(path.split('/').at(-1)), saved.kind);
      try { await storeAttachment(pairing.workspaceID, { path, size: saved.size }, file.blob.slice(0, file.blob.size, type)); }
      catch { /* Upload is confirmed even if this copy does not fit in the cache. */ }
    }
  }
}

export function pendingAttachmentCard(file, dialog, openImage) {
  const kind = attachmentKind(file.name);
  const type = attachmentType(file.name, kind);
  return attachmentCard({
    ref: { name: file.name, path: encodeURIComponent(file.name), kind }, dialog, openImage,
    localBlob: file.blob.slice(0, file.blob.size, type),
  });
}

export function attachmentCard({ ref, kind, key, pairing, dialog, localBlob, offlineOnly = false, queueImage, openImage }) {
  const card = document.createElement('span');
  card.className = 'attachment';
  const name = document.createElement('strong');
  name.textContent = ref.name;
  const status = document.createElement('span');
  status.className = 'attachment-status muted';
  status.setAttribute('role', 'status');
  const action = document.createElement('button');
  action.type = 'button';
  action.textContent = '下载附件';
  const view = document.createElement('span');
  view.className = 'attachment-preview';
  card.append(name, view, status, action);

  let blobURL;
  const controller = new AbortController();
  dialog.addEventListener('close', () => {
    controller.abort();
    if (blobURL) URL.revokeObjectURL(blobURL);
  }, { once: true });

  function display(blob, cached) {
    if (controller.signal.aborted) return;
    status.textContent = localBlob ? '已保存在手机，待同步' : cached ? '可离线查看' : '本次可查看，未能保存到手机';
    const mime = ref.kind === 'image' && blob.type === 'application/octet-stream'
      ? attachmentType(ref.name, 'image') : blob.type;
    const tag = previewTag(mime);
    if (tag && !blobURL) {
      const media = document.createElement(tag);
      blobURL = URL.createObjectURL(mime === blob.type ? blob : blob.slice(0, blob.size, mime));
      if (tag === 'img') { media.alt = ref.name; media.loading = 'lazy'; }
      else { media.controls = true; media.preload = 'metadata'; media.playsInline = true; }
      media.addEventListener('error', () => { status.textContent = '手机暂无法预览此格式，可以导出文件。'; });
      media.src = blobURL;
      if (tag === 'img' && openImage) {
        const open = document.createElement('button');
        open.type = 'button';
        open.className = 'attachment-image-button';
        open.setAttribute('aria-label', `全屏查看 ${ref.name}`);
        open.addEventListener('click', () => openImage(blob));
        open.append(media);
        view.append(open);
      } else view.append(media);
    }
    action.disabled = false;
    action.textContent = '导出文件';
    action.onclick = async () => {
      action.disabled = true;
      try { await exportAttachment(blob, ref); }
      catch (error) {
        if (!/cancel/i.test(error?.message ?? '')) status.textContent = '暂时无法导出附件，请重试。';
      } finally { action.disabled = false; }
    };
  }

  if (localBlob) {
    display(localBlob, true);
    return card;
  }
  action.onclick = async () => {
    if (controller.signal.aborted) return;
    action.disabled = true;
    status.textContent = '正在从 Mac 下载…';
    try {
      const saved = await downloadAttachment(pairing, kind, key, ref, controller.signal);
      if (saved) display(saved.blob, saved.cached);
    } catch (error) {
      if (!controller.signal.aborted) status.textContent = error.message || '附件下载中断，请重试。';
    } finally { action.disabled = false; }
  };
  action.disabled = true;
  if (!pairing) {
    status.textContent = '连接 Mac 后可下载';
  } else {
    const tooLarge = ref.size > attachmentLimit;
    status.textContent = '正在检查本机缓存…';
    loadAttachment(pairing.workspaceID, ref).catch(() => null).then(blob => {
      if (controller.signal.aborted) return;
      if (blob) display(blob, true);
      else if (queueImage && ref.kind === 'image' && !tooLarge && !offlineOnly) {
        status.textContent = '等待下载图片…';
        queueImage(action.onclick);
      }
      else {
        status.textContent = tooLarge ? attachmentErrors[413] : offlineOnly ? '尚未下载，请同步结束后从列表重新打开。' : '未下载';
        action.disabled = tooLarge || offlineOnly;
      }
    });
  }
  return card;
}
