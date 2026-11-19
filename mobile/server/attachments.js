import { constants } from 'node:fs';
import { open, realpath } from 'node:fs/promises';
import { join } from 'node:path';
import { attachmentLimit, attachmentType, mediaPath, recordAttachments } from '../shared/attachments.js';

export async function openAttachment(workspacePath, automation, input) {
  const { kind, key, path } = input;
  const canonical = mediaPath(path);
  if (!workspacePath || !['articles', 'moments'].includes(kind) ||
      typeof key !== 'string' || key.length < 1 || key.length > 512 || !canonical) return { status: 404 };

  const record = await automation(`${kind}.get`, kind === 'articles' ? { slug: key } : { id: key });
  if (record.error?.code === 'busy') return { status: 503 };
  if (record.error?.code === 'not_found') return { status: 404 };
  if (record.error) return { status: 502 };
  const ref = recordAttachments(kind, record.result).find(item => item.path === canonical);
  if (!ref) return { status: 404 };

  const [directory, filename] = canonical.split('/').slice(2).map(decodeURIComponent);
  const parent = join(workspacePath, 'media', directory);
  let file;
  try {
    // A symlink anywhere below the canonical data root is outside the shares
    // offered by this workspace. Refuse links and only stream regular files.
    if ((await realpath(parent)).normalize('NFC') !== parent.normalize('NFC')) return { status: 404 };
    file = await open(join(parent, filename), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const stat = await file.stat();
    if (!stat.isFile()) return { status: 404 };
    if (stat.size > attachmentLimit) return { status: 413 };
    const contentType = attachmentType(filename, ref.kind);
    const handle = file;
    file = null;
    return { status: 200, handle, size: stat.size, contentType };
  } catch (error) {
    if (['ENOENT', 'ELOOP', 'ENOTDIR', 'EACCES', 'EPERM', 'ENXIO'].includes(error.code)) return { status: 404 };
    throw error;
  } finally {
    if (file) await file.close();
  }
}
