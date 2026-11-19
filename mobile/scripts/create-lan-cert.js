import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { isIP } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

async function main() {
  const [ip, directory] = process.argv.slice(2);
  if (!isIP(ip) || ip.includes('%') || !directory) {
    throw new Error('用法：node mobile/scripts/create-lan-cert.js Mac的局域网IP 新建证书目录');
  }
  process.umask(0o077);
  const output = resolve(directory);
  await mkdir(output, { mode: 0o700 });
  const scratch = await mkdtemp(join(tmpdir(), 'leonbook-tls-'));
  try {
    const root = join(output, 'leonbook-ca.cer');
    const leaf = join(output, 'mac-cert.pem');
    const serverKey = join(output, 'mac-key.pem');
    const caKey = join(scratch, 'root.key');
    const ca = join(scratch, 'root.pem');
    const csr = join(scratch, 'mac.csr');
    const caConfig = join(scratch, 'ca.cnf');
    const leafConfig = join(scratch, 'leaf.cnf');
    await writeFile(caConfig, [
      '[req]', 'distinguished_name = dn', 'x509_extensions = v3_ca',
      '[dn]', 'CN = LeonBook Local Sync', '[v3_ca]',
      'basicConstraints = critical,CA:TRUE,pathlen:0',
      'keyUsage = critical,keyCertSign,cRLSign', 'subjectKeyIdentifier = hash',
    ].join('\n'));
    await writeFile(leafConfig, [
      '[server]', 'basicConstraints = critical,CA:FALSE',
      'keyUsage = critical,digitalSignature,keyEncipherment',
      'extendedKeyUsage = serverAuth', `subjectAltName = IP:${ip}`,
    ].join('\n'));
    const openssl = (...args) => execFileSync('openssl', args, { stdio: ['ignore', 'ignore', 'pipe'] });
    openssl('req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256', '-days', '365',
      '-config', caConfig, '-subj', '/CN=LeonBook Local Sync', '-keyout', caKey, '-out', ca);
    openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-subj', '/CN=LeonBook Mac Sync',
      '-keyout', serverKey, '-out', csr);
    openssl('x509', '-req', '-in', csr, '-CA', ca, '-CAkey', caKey, '-CAserial', join(scratch, 'serial'),
      '-CAcreateserial', '-days', '365', '-sha256', '-extfile', leafConfig, '-extensions', 'server', '-out', leaf);
    openssl('verify', '-purpose', 'sslserver', '-CAfile', ca, leaf);
    openssl('x509', '-in', ca, '-outform', 'DER', '-out', root);
    console.log(`证书已生成：${output}\n将 leonbook-ca.cer 安装到自己的手机。mac-key.pem 留在 Mac 上。`);
  } catch (error) {
    await rm(output, { recursive: true, force: true });
    throw new Error(error.stderr?.toString().trim() || error.message);
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
