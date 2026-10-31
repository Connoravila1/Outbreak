/// <reference types="vite/client" />
declare module '@fontsource/*';

interface ImportMetaEnv {
  readonly VITE_SERVER_URL?: string;
  readonly VITE_MOCK?: string;
}

declare module 'maplibre-gl/dist/maplibre-gl-worker.mjs?url' {
  const url: string;
  export default url;
}
