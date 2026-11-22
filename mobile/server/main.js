import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmod, mkdir, readFile, realpath, stat } from 'node:fs/promises';
import { isIP } from 'node:net';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { isPrivateIPv4 } from '../shared/network.js';
import { makeBridge } from './bridge.js';
import { managedTLS } from './managed-tls.js';

const cliDefault = fileURLToPath(new URL('../../macos/dist/leon-book.app/Contents/MacOS/LeonBookCLI', import.meta.url));

export async function libraryGeneration(root) {
  // This file is written into the staging directory by LocalBackupManager.
  const directory = await stat(root);
  let value;
  try { value = await readFile(join(root, '.leonbook-restore-generation'), 'utf8'); }
  catch (error) {
    if (error.code !== 'ENOENT') throw error;
    const current = await stat(root);
    if (current.ino !== directory.ino || current.dev !== directory.dev) throw new Error('Library changed during sync');
    return 'initial';
  }
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value)) throw new Error('Invalid restore generation');
  return value;
}

export function automate(executable, root, userID, method, params = {}) {
  return new Promise((resolve, reject) => {
    const args = [method, '--root', root, '--json', '-'];
    if (userID) args.push('--user', userID);
    const child = execFile(executable, args, { timeout: 45_000, maxBuffer: 10 * 1024 * 1024 }, (error, stdout) => {
      if (error?.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER') { resolve({ error: { code: 'response_too_large' } }); return; }
      if (error?.killed || (error && typeof error.code !== 'number')) { reject(new Error('Mac API 无法响应。')); return; }
      try {
        const response = JSON.parse(stdout);
        if (response.apiVersion !== 1 || (!response.error && !Object.hasOwn(response, 'result'))) throw new Error();
        resolve(response);
      } catch { reject(new Error('Mac API 返回无效数据。')); }
    });
    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify(params));
  });
}

async function main() {
  const { values } = parseArgs({ options: {
    root: { type: 'string' }, user: { type: 'string' }, cli: { type: 'string' },
    host: { type: 'string', default: '127.0.0.1' }, port: { type: 'string', default: '8765' },
    managed: { type: 'boolean' }, 'lan-http': { type: 'boolean' }, 'control-stdio': { type: 'boolean' }, 'state-dir': { type: 'string' },
    url: { type: 'string' }, cert: { type: 'string' }, key: { type: 'string' }, help: { type: 'boolean' },
  } });
  if (values.help) {
    console.log('用法：./scripts/leonblog mobile-sync --root 数据根目录 [--user 用户ID] [--host Mac 的IP] [--port 8765] [--lan-http | --cert 证书 --key 私钥] [--url https://手机访问的地址] [--cli CLI路径]');
    return;
  }
  const port = Number(values.port);
  if (!values.root || !isIP(values.host) || !Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('请指定有效的 --root、监听 IP 和端口。');
  }
  const local = ['127.0.0.1', '::1'].includes(values.host);
  const lanHTTP = values['lan-http'];
  if (lanHTTP && (!isPrivateIPv4(values.host) || values.cert || values.key || values.managed)) {
    throw new Error('局域网 HTTP 需要一个私有 IPv4 地址，且不能同时指定证书。');
  }
  if ((values.managed && (values.cert || values.key)) || Boolean(values.cert) !== Boolean(values.key) ||
      (!local && !lanHTTP && !values.cert && !values.managed)) {
    throw new Error('局域网监听需要同时指定 --cert 和 --key。');
  }
  const host = isIP(values.host) === 6 ? `[${values.host}]` : values.host;
  const listenURL = new URL(`${values.cert || values.managed ? 'https' : 'http'}://${host}:${port}`);
  const url = new URL(values.url ?? listenURL);
  if (lanHTTP && url.origin !== listenURL.origin) throw new Error('局域网 HTTP 的配对地址必须与监听地址一致。');
  if (url.username || url.password || url.pathname !== '/' || url.search || url.hash ||
      (url.protocol !== 'https:' && (url.protocol !== 'http:' || (!local && !lanHTTP) || url.hostname !== host))) {
    throw new Error('请使用有效的 HTTPS 或当前 Mac 的局域网 HTTP 地址。');
  }
  const root = await realpath(values.root);
  if (!(await stat(join(root, 'workspaces'))).isDirectory() || !(await stat(join(root, 'users.json'))).isFile()) {
    throw new Error('请使用已有的 LeonBook 数据根目录。');
  }
  const executable = resolve(values.cli ?? cliDefault);
  const workspace = await automate(executable, root, values.user, 'workspace.info');
  const userID = workspace.result?.user?.id;
  if (!userID) throw new Error(workspace.error?.message ?? '无法读取 LeonBook 用户工作区。');
  const workspaceID = createHash('sha256').update(JSON.stringify([root, userID])).digest('hex');

  const journalDir = values['state-dir'] ? resolve(values['state-dir'])
    : join(homedir(), 'Library', 'Application Support', 'LeonBook', 'MobileSync');
  await mkdir(journalDir, { recursive: true, mode: 0o700 });
  await chmod(journalDir, 0o700);
  const managed = values.managed ? await managedTLS(join(journalDir, 'certificates'), values.host) : null;
  const tls = managed?.tls ?? (values.cert ? { cert: await readFile(values.cert), key: await readFile(values.key), minVersion: 'TLSv1.2' } : null);
  const { server, token, devices } = makeBridge({
    workspaceID, tls, workspacePath: join(root, 'workspaces', userID),
    allowLegacyToken: !values['control-stdio'],
    databasePath: join(journalDir, 'operations.sqlite'),
    getGeneration: () => libraryGeneration(root),
    automation: (method, params) => automate(executable, root, userID, method, params),
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, values.host, resolve);
  });
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    server.close();
    server.closeIdleConnections();
  };
  if (values['control-stdio']) {
    const write = message => console.log(JSON.stringify(message));
    const control = createInterface({ input: process.stdin, crlfDelay: Infinity });
    control.on('line', line => {
      let input;
      try { input = JSON.parse(line); } catch { return; }
      switch (input?.action) {
        case 'invite': write({ type: 'invite', invitation: devices.invite(url.origin) }); break;
        case 'status': write({ type: 'status', ...devices.status() }); break;
        case 'revoke': devices.revoke(input.id); write({ type: 'status', ...devices.status() }); break;
        case 'cancel-invite': devices.cancelInvite(); write({ type: 'status', ...devices.status() }); break;
        case 'stop': control.close(); process.stdin.pause(); stop(); break;
      }
    });
    control.once('close', stop);
    write({ type: 'ready', url: url.origin, certificate: managed?.certificate });
    write({ type: 'status', ...devices.status() });
  } else {
    console.log(`LeonBook 手机同步已开启，工作区 ${userID}。将下一行粘贴到手机的「连接 Mac」。`);
    if (lanHTTP) console.log('当前为局域网 HTTP，同步内容和凭证以明文传输。');
    console.log(JSON.stringify({ url: url.origin, token, workspaceID }));
    console.log('按 Ctrl+C 停止同步。此终端凭证只在本次服务运行期间有效。');
  }
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.once(signal, () => { process.stdin.pause(); stop(); });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    if (process.argv.includes('--control-stdio')) console.log(JSON.stringify({ type: 'error', message: error.message }));
    else console.error(`无法开启 LeonBook 手机同步：${error.message}`);
    process.exitCode = 1;
  });
}
