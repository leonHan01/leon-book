export const attachmentLimit = 32 * 1024 * 1024;
export const attachmentCacheLimit = 128 * 1024 * 1024;
export const uploadBatchLimit = 64 * 1024 * 1024;
export const uploadFileCount = 9;

const previewTypes = new Map(Object.entries({
  jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp', avif: 'image/avif',
  heic: 'image/heic', heif: 'image/heif',
  mp4: 'video/mp4', m4v: 'video/mp4', mov: 'video/quicktime', webm: 'video/webm',
  mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac', wav: 'audio/wav', ogg: 'audio/ogg',
}));

export function uploadExtension(name) { return /\.([a-z0-9]{1,12})$/i.exec(name)?.[1].toLowerCase() ?? 'bin'; }
export function uploadName(name) {
  return name.replace(/[\u0000-\u001f\u007f/\\:*?"<>|]/g, '_').replace(/^\.+/, '').trim().normalize('NFC') || 'attachment';
}
export function attachmentKind(name) {
  const ext = uploadExtension(name);
  return previewTypes.get(ext)?.split('/')[0] ?? 'file';
}
export function attachmentType(name, kind) {
  const mime = previewTypes.get(uploadExtension(name));
  return mime?.startsWith(`${kind}/`) ? mime : 'application/octet-stream';
}
export function supportsMomentUpload(name) {
  return attachmentKind(name) === 'image' || ['mp3', 'mp4'].includes(uploadExtension(name));
}

export function mediaPath(url) {
  if (typeof url !== 'string' || url.length > 2048) return null;
  const local = url.replace(/^https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?(?=\/media\/)/i, '');
  const match = /^\/?media\/([^/]+)\/([^/]+)$/.exec(local);
  if (!match) return null;
  try {
    const parts = match.slice(1).map(part => decodeURIComponent(part));
    if (parts.some(part => !/^[\p{L}\p{N}_.-]+$/u.test(part) || part.startsWith('.'))) return null;
    return '/media/' + parts.map(encodeURIComponent).join('/');
  } catch { return null; }
}

export function recordAttachments(kind, record) {
  const refs = kind === 'moments' ? record?.images
    : kind === 'articles' ? [...(record?.banner ? [{ ...record.banner, kind: 'image' }] : []), ...(record?.media ?? [])]
    : [];
  const unique = new Map();
  for (const ref of refs ?? []) {
    const path = mediaPath(ref?.url);
    if (!path || unique.has(path)) continue;
    unique.set(path, {
      path, kind: ref.kind,
      name: typeof ref.name === 'string' && ref.name.trim() ? ref.name : decodeURIComponent(path.split('/').at(-1)),
      size: Number.isSafeInteger(ref.size) && ref.size > 0 ? ref.size : undefined,
    });
  }
  return [...unique.values()];
}
