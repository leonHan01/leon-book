import busboy from 'busboy';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { rename } from 'node:fs/promises';
import { join } from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { attachmentKind, attachmentLimit, supportsMomentUpload, uploadBatchLimit, uploadExtension, uploadFileCount, uploadName } from '../shared/attachments.js';

export const operationID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const jsonLimit = 4 * 1024 * 1024;

export async function readUpload(req, directory) {
  const files = new Map();
  let metadata, failure;
  const fail = code => { failure ??= code; };
  let receiver;
  try {
    receiver = busboy({ headers: req.headers, limits: {
      fields: 1, files: uploadFileCount, fieldSize: jsonLimit, fileSize: attachmentLimit + 1,
      parts: uploadFileCount + 2,
    } });
  } catch { return { error: 'invalid_request' }; }

  const pending = [];
  let incoming = 0;
  const limit = new Transform({
    transform(chunk, _encoding, callback) {
      incoming += chunk.length;
      if (incoming > uploadBatchLimit + jsonLimit + 64 * 1024) {
        fail('message_too_large');
        callback(new Error('multipart size limit'));
      } else callback(null, chunk);
    },
  });
  receiver.on('field', (field, json, info) => {
    if (field !== 'mutation' || info.valueTruncated) { fail('invalid_request'); return; }
    try { metadata = JSON.parse(json); } catch { fail('invalid_request'); }
  });
  receiver.on('file', (id, source) => {
    if (!operationID.test(id) || files.has(id)) { fail('invalid_request'); source.resume(); return; }
    const file = { path: join(directory, id), size: 0, digest: null };
    files.set(id, file);
    const digest = createHash('sha256');
    source.on('limit', () => fail('message_too_large'));
    const measure = new Transform({
      transform(chunk, _encoding, callback) {
        file.size += chunk.length;
        digest.update(chunk);
        callback(null, chunk);
      },
    });
    pending.push(pipeline(source, measure, createWriteStream(file.path, { flags: 'wx', mode: 0o600 }))
      .then(() => { file.digest = digest.digest('hex'); }, () => { fail('storage_error'); }));
  });
  for (const event of ['fieldsLimit', 'filesLimit', 'partsLimit']) receiver.on(event, () => fail('invalid_request'));
  // Keep the response writable for validation errors from the decoder.
  await new Promise(resolve => {
    const complete = () => resolve();
    req.once('aborted', () => { fail('invalid_request'); limit.destroy(); receiver.destroy(); });
    req.once('error', () => { fail('invalid_request'); limit.destroy(); receiver.destroy(); });
    limit.once('error', () => { receiver.destroy(); req.resume(); });
    receiver.once('error', () => { fail('invalid_request'); limit.destroy(); req.resume(); });
    receiver.once('close', complete);
    req.pipe(limit).pipe(receiver);
  });
  await Promise.all(pending);
  if (failure) return { error: failure };
  if (!Array.isArray(metadata?.files) || !metadata.files.length ||
      metadata.files.length !== files.size || !/^(articles|moments)\.(create|update)$/.test(metadata.method)) {
    return { error: 'invalid_request' };
  }
  const result = [];
  let total = 0;
  for (const descriptor of metadata.files) {
    const file = files.get(descriptor?.id);
    const name = typeof descriptor?.name === 'string' ? uploadName(descriptor.name) : '';
    if (!file || !file.digest || !name || Buffer.byteLength(name) > 250) return { error: 'invalid_request' };
    if (metadata.method.startsWith('moments.') && !supportsMomentUpload(name)) return { error: 'invalid_params' };
    total += file.size;
    if (!file.size || file.size > attachmentLimit || total > uploadBatchLimit) return { error: 'message_too_large' };
    const path = `${file.path}.${uploadExtension(name)}`;
    await rename(file.path, path);
    result.push({ id: descriptor.id, path, name, kind: attachmentKind(name), digest: file.digest });
    files.delete(descriptor.id);
  }
  return { metadata, files: result };
}
