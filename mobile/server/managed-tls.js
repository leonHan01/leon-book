import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { chmod, mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { isIP } from 'node:net';
import { join } from 'node:path';
import { promisify } from 'node:util';

const run = promisify(execFile);
const openssl = (...args) => run('/usr/bin/openssl', args, { timeout: 12_000 });

async function authority(directory) {
  const saved = join(directory, 'authority-v1');
  if (await stat(saved).then(() => true, error => {
    if (error.code === 'ENOENT') return false;
    throw error;
  })) return saved;
  const draft = await mkdtemp(join(directory, 'new-authority-'));
  try {
    const config = join(draft, 'ca.cnf');
    const key = join(draft, 'ca-key.pem');
    const pem = join(draft, 'ca.pem');
    await writeFile(config, [
      '[req]', 'distinguished_name=dn', 'x509_extensions=ca',
      '[dn]', 'CN=LeonBook Local Sync',
      '[ca]', 'basicConstraints=critical,CA:TRUE,pathlen:0', 'keyUsage=critical,keyCertSign,cRLSign', 'subjectKeyIdentifier=hash',
    ].join('\n'), { mode: 0o600 });
    await openssl('req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256', '-days', '3650',
      '-config', config, '-subj', '/CN=LeonBook Local Sync', '-keyout', key, '-out', pem);
    await chmod(key, 0o600);
    await openssl('x509', '-in', pem, '-outform', 'DER', '-out', join(draft, 'leonbook-ca.cer'));
    await rm(config);
    try { await rename(draft, saved); }
    catch (error) { if (!['EEXIST', 'ENOTEMPTY'].includes(error.code)) throw error; }
    return saved;
  } finally { await rm(draft, { recursive: true, force: true }); }
}

export async function managedTLS(directory, host) {
  if (!isIP(host) || host.includes('%')) throw new Error('同步证书需要有效的本机 IP。');
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await chmod(directory, 0o700);
  const root = await authority(directory);
  const key = join(root, 'ca-key.pem');
  const ca = join(root, 'ca.pem');
  const scratch = await mkdtemp(join(directory, 'leaf-'));
  try {
    const config = join(scratch, 'leaf.cnf');
    const leafKey = join(scratch, 'leaf.key');
    const leafRequest = join(scratch, 'leaf.csr');
    const leaf = join(scratch, 'leaf.pem');
    await writeFile(config, [
      '[server]', 'basicConstraints=critical,CA:FALSE', 'keyUsage=critical,digitalSignature,keyEncipherment',
      'extendedKeyUsage=serverAuth', `subjectAltName=IP:${host}`,
    ].join('\n'), { mode: 0o600 });
    await openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-subj', '/CN=LeonBook Mac Sync',
      '-keyout', leafKey, '-out', leafRequest);
    const serial = randomBytes(16).toString('hex');
    await openssl('x509', '-req', '-in', leafRequest, '-CA', ca, '-CAkey', key, '-set_serial', `0x${serial}`,
      '-days', '365', '-sha256', '-extfile', config, '-extensions', 'server', '-out', leaf);
    await openssl('verify', '-purpose', 'sslserver', '-CAfile', ca, leaf);
    return {
      tls: { cert: await readFile(leaf), key: await readFile(leafKey), minVersion: 'TLSv1.2' },
      certificate: join(root, 'leonbook-ca.cer'),
    };
  } finally { await rm(scratch, { recursive: true, force: true }); }
}
