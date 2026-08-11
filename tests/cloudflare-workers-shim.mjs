export const env = new Proxy({}, {
  get(_target, property) {
    return globalThis.__CLOUDFLARE_TEST_ENV__?.[property];
  },
});
