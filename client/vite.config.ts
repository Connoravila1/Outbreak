/// <reference types="node" />
import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';

export default defineConfig({
  plugins: [preact()],
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
