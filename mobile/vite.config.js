import { defineConfig } from 'vite';

export default defineConfig({
  build: { target: ['chrome107', 'safari16'] },
  server: { port: 4187, strictPort: true },
});
