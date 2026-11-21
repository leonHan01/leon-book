import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';

const invitationTTL = 5 * 60_000;
const digest = value => createHash('sha256').update(value).digest('hex');
const token = () => randomBytes(32).toString('base64url');
const tokenPattern = /^[A-Za-z0-9_-]{43}$/;

export function deviceRegistry(db, workspaceID, now = Date.now) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS mobile_devices (
      workspace TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL,
      token_hash TEXT NOT NULL, paired_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL,
      PRIMARY KEY (workspace, id), UNIQUE (workspace, token_hash)
    );
  `);
  const add = db.prepare('INSERT INTO mobile_devices VALUES (?, ?, ?, ?, ?, ?)');
  const find = db.prepare('SELECT id, last_seen_at FROM mobile_devices WHERE workspace = ? AND token_hash = ?');
  const touch = db.prepare('UPDATE mobile_devices SET last_seen_at = ? WHERE workspace = ? AND id = ?');
  const list = db.prepare('SELECT id, name, paired_at AS pairedAt, last_seen_at AS lastSeenAt FROM mobile_devices WHERE workspace = ? ORDER BY paired_at DESC');
  const revoke = db.prepare('DELETE FROM mobile_devices WHERE workspace = ? AND id = ?');
  let invite;

  return {
    invite(url) {
      const code = token();
      invite = { hash: digest(code), expiresAt: now() + invitationTTL };
      return { type: 'leonbook-pair', version: 1, url, workspaceID, code, expiresAt: invite.expiresAt };
    },
    cancelInvite() { invite = undefined; },
    status() {
      return { devices: list.all(workspaceID), expiresAt: invite?.expiresAt > now() ? invite.expiresAt : null };
    },
    pair(input) {
      if (input?.workspaceID !== workspaceID || typeof input?.code !== 'string' || !tokenPattern.test(input.code) ||
          !invite || invite.expiresAt <= now() ||
          !timingSafeEqual(Buffer.from(digest(input.code), 'hex'), Buffer.from(invite.hash, 'hex'))) return null;
      const name = typeof input.name === 'string' ? input.name.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 64) : '';
      if (!name || list.all(workspaceID).length >= 32) return null;
      const issued = token();
      const deviceID = randomUUID();
      const pairedAt = now();
      add.run(workspaceID, deviceID, name, digest(issued), pairedAt, pairedAt);
      invite = undefined;
      return { workspaceID, deviceID, token: issued };
    },
    accepts(value) {
      if (typeof value !== 'string' || !tokenPattern.test(value)) return false;
      const device = find.get(workspaceID, digest(value));
      if (!device) return false;
      const time = now();
      if (time - device.last_seen_at >= 60_000) touch.run(time, workspaceID, device.id);
      return true;
    },
    revoke(id) { return typeof id === 'string' && revoke.run(workspaceID, id).changes === 1; },
  };
}
