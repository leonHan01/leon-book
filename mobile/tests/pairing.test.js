import assert from 'node:assert/strict';
import { X509Certificate } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { request as httpsRequest } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { makeBridge } from '../server/bridge.js';
import { managedTLS } from '../server/managed-tls.js';
import { parsePairing } from '../src/sync.js';

const workspaceID = 'a'.repeat(64);
function post(url, route, body, { token, ca } = {}) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const headers = { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) };
    if (token) headers.Authorization = `Bearer ${token}`;
    const req = httpsRequest(new URL(route, url), { ca, method: 'POST', headers }, res => {
      const buffers = [];
      res.on('data', data => buffers.push(data));
      res.on('error', reject);
      res.on('end', () => {
        const text = Buffer.concat(buffers).toString();
        resolve({ status: res.statusCode, json: text && JSON.parse(text) });
      });
    });
    req.once('error', reject);
    req.end(data);
  });
}

test('trusted pairing is one-time, scoped and stays authorized after restarting the TLS service', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'leonbook-pairing-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const databasePath = join(directory, 'operations.sqlite');
  let clock = Date.now();
  const options = { databasePath, workspaceID, allowLegacyToken: false, now: () => clock };
  const automation = async () => { throw new Error('hello and pairing must not access the workspace'); };
  const tlsDirectory = join(directory, 'certificates');

  const start = async (config = options) => {
    const managed = await managedTLS(tlsDirectory, '127.0.0.1');
    const ca = new X509Certificate(await readFile(managed.certificate));
    const leaf = new X509Certificate(managed.tls.cert);
    assert.equal(leaf.checkIP('127.0.0.1'), '127.0.0.1');
    assert.ok(leaf.verify(ca.publicKey));
    const { server, devices, token } = makeBridge({ ...config, automation, tls: managed.tls });
    assert.equal(token, null);
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const close = () => new Promise(resolve => server.listening ? server.close(resolve) : resolve());
    t.after(close);
    return { devices, close, url: `https://127.0.0.1:${server.address().port}`, ca: ca.toString(), fingerprint: ca.fingerprint256 };
  };

  const first = await start();
  const hello = { workspaceID, action: 'hello' };
  const redeem = (invitation, name = '我的 iPhone') => post(first.url, '/v1/pair', { ...invitation, name }, { ca: first.ca });
  assert.equal((await post(first.url, '/v1/sync', hello, { ca: first.ca })).status, 401);
  const expired = first.devices.invite(first.url);
  clock += 300_001;
  assert.equal((await redeem(expired)).status, 403);
  const invitation = first.devices.invite(first.url);
  assert.deepEqual(parsePairing(JSON.stringify(invitation), clock), { url: first.url, workspaceID, code: invitation.code });
  assert.throws(() => parsePairing(JSON.stringify({ ...invitation, url: 'http://192.168.1.3' }), clock), /配对信息无效/);
  await assert.rejects(() => post(first.url, '/v1/pair', { ...invitation, name: 'device' }), { code: 'UNABLE_TO_VERIFY_LEAF_SIGNATURE' });
  assert.equal((await redeem({ ...invitation, workspaceID: 'b'.repeat(64) })).status, 403);
  assert.equal((await redeem(invitation, '')).status, 403);
  const paired = (await redeem(invitation)).json.result;
  assert.ok(paired.token && paired.deviceID);
  assert.equal((await redeem(invitation)).status, 403);
  assert.equal(first.devices.status().expiresAt, null);
  assert.deepEqual(first.devices.status().devices.map(device => device.name), ['我的 iPhone']);
  assert.equal(JSON.stringify(first.devices.status()).includes(paired.token), false);
  await first.close();

  const restarted = await start();
  assert.equal(first.fingerprint, restarted.fingerprint);
  const usingDevice = { token: paired.token, ca: first.ca };
  assert.equal((await post(restarted.url, '/v1/sync', hello, usingDevice)).json.workspaceID, workspaceID);
  const other = await start({ ...options, workspaceID: 'b'.repeat(64) });
  assert.equal((await post(other.url, '/v1/sync', { ...hello, workspaceID: 'b'.repeat(64) }, usingDevice)).status, 401);
  assert.equal(other.devices.revoke(paired.deviceID), false);
  assert.equal(restarted.devices.revoke(paired.deviceID), true);
  assert.equal((await post(restarted.url, '/v1/sync', hello, usingDevice)).status, 401);
});
