import { attachmentLimit } from '../shared/attachments.js';
import { downloadAttachment, previewImageBlob } from './attachments.js';
import { loadAttachment } from './storage.js';

export async function loadPhoto(pairing, kind, key, { ref, blob }, signal, allowDownload) {
  const local = blob ?? (pairing && await loadAttachment(pairing.workspaceID, ref).catch(() => null));
  if (signal.aborted) return null;
  if (local) return local;
  if (ref.size > attachmentLimit) throw new Error('图片超过手机预览的大小限制。');
  if (!pairing || !allowDownload()) throw new Error('这张图片尚未缓存，请连接 Mac 后重试。');
  return (await downloadAttachment(pairing, kind, key, ref, signal))?.blob;
}

export function imagePreviews({ pairing, kind, networkEnabled, root = null }) {
  const visible = new Set();
  const previews = new Map();
  let transfer;
  let disposed = false;
  const observer = new IntersectionObserver(entries => {
    for (const { target, isIntersecting } of entries) {
      const preview = previews.get(target);
      if (!preview || isIntersecting === visible.has(preview)) continue;
      if (isIntersecting) {
        visible.add(preview);
        preview.visibility = new AbortController();
        void load(preview, preview.visibility.signal);
      } else {
        visible.delete(preview);
        preview.visibility.abort();
        preview.waiting = false;
        if (transfer?.preview === preview) transfer.controller.abort();
        release(preview);
      }
    }
  }, { root, rootMargin: '260px 0px' });

  function release(preview) {
    if (!preview.url) return;
    URL.revokeObjectURL(preview.url);
    preview.url = null;
    preview.displayedBlob = null;
    preview.image.removeAttribute('src');
    preview.image.hidden = true;
    preview.status.hidden = false;
  }

  function display(preview, blob) {
    const imageBlob = previewImageBlob(blob, preview.ref.name);
    if (!imageBlob) {
      preview.status.textContent = '点开查看附件';
      return;
    }
    const { image, status, tile } = preview;
    const url = URL.createObjectURL(imageBlob);
    preview.url = url;
    preview.displayedBlob = imageBlob;
    image.onload = () => {
      if (preview.url !== url) return;
      if (preview.aspectRatio && image.naturalHeight > 0) {
        tile.style.aspectRatio = String(preview.aspectRatio(image.naturalWidth / image.naturalHeight));
      }
      status.hidden = true;
      image.hidden = false;
    };
    image.onerror = () => {
      if (preview.url !== url) return;
      release(preview);
      status.textContent = '点开查看附件';
    };
    image.src = url;
  }

  async function load(preview, signal) {
    preview.status.textContent = '正在加载图片…';
    const cached = preview.blob ?? (pairing && await loadAttachment(pairing.workspaceID, preview.ref).catch(() => null));
    if (signal.aborted) return;
    if (cached) {
      display(preview, cached);
      return;
    }
    if (!pairing || preview.ref.size > attachmentLimit) {
      preview.status.textContent = '图片未下载';
      return;
    }
    preview.waiting = true;
    preview.status.textContent = '等待下载图片…';
    void drain();
  }

  // The bridge serializes authorization for attachment requests. Keep one
  // automatic download in flight and give sync/detail requests priority.
  async function drain() {
    if (disposed || transfer || !networkEnabled) return;
    const preview = [...visible].find(item => item.waiting);
    if (!preview) return;
    const controller = new AbortController();
    const viewportSignal = preview.visibility.signal;
    transfer = { preview, controller };
    preview.waiting = false;
    preview.status.textContent = '正在下载图片…';
    try {
      const result = await downloadAttachment(pairing, kind, preview.key, preview.ref, controller.signal);
      if (result && !controller.signal.aborted) display(preview, result.blob);
    } catch {
      if (!controller.signal.aborted) preview.status.textContent = '图片暂不可用';
    } finally {
      if (controller.signal.aborted && !viewportSignal.aborted) {
        preview.waiting = true;
        preview.status.textContent = '等待下载图片…';
      }
      transfer = null;
      void drain();
    }
  }

  return {
    add({ key, ref, blob, className, aspectRatio, label, open }) {
      const tile = document.createElement('button');
      tile.type = 'button';
      tile.className = className;
      tile.setAttribute('aria-label', label);
      const image = document.createElement('img');
      image.alt = '';
      image.decoding = 'async';
      image.hidden = true;
      const status = document.createElement('span');
      status.textContent = '图片';
      tile.append(image, status);
      const preview = { key, ref, blob, tile, image, status, aspectRatio };
      previews.set(tile, preview);
      tile.addEventListener('click', () => open(preview.displayedBlob, tile));
      observer.observe(tile);
      return tile;
    },
    setNetworkEnabled(enabled) {
      networkEnabled = enabled;
      if (!enabled) transfer?.controller.abort();
      else void drain();
    },
    dispose() {
      disposed = true;
      observer.disconnect();
      transfer?.controller.abort();
      for (const preview of visible) {
        preview.visibility.abort();
        release(preview);
      }
      visible.clear();
      previews.clear();
    },
  };
}
