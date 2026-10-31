/// <reference types="node" />
import { readFileSync } from 'node:fs';
import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';

// The version the server's forced-update gate compares (X-Outbreak-Client): package.json at build time.
const { version } = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8')) as { version: string };

export default defineConfig({
  plugins: [preact()],
  define: { __APP_VERSION__: JSON.stringify(version) },
  server: {
    host: true,
    proxy: {
      '/api': { target: process.env.OUTBREAK_API ?? 'http://localhost:8080', changeOrigin: true },
    },
  },
  build: {
    target: 'es2022',
    chunkSizeWarningLimit: 1500,
  },
});
