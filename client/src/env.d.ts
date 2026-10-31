/// <reference types="vite/client" />
declare module '@fontsource/*';

/** The client's version (package.json), baked in by vite.config.ts. */
declare const __APP_VERSION__: string;

interface ImportMetaEnv {
  readonly VITE_SERVER_URL?: string;
  readonly VITE_MOCK?: string;
  /** Seconds between Patrol check-ins (default 60; use 15 to test). */
  readonly VITE_PATROL_INTERVAL_SEC?: string;
  /** Google OAuth client IDs (see docs/ACCOUNTS_SETUP.md). The web ID is also used by Android. */
  readonly VITE_GOOGLE_WEB_CLIENT_ID?: string;
  readonly VITE_GOOGLE_IOS_CLIENT_ID?: string;
  /** Apple Services ID and the return URL registered for it (Android / web Sign in with Apple). */
  readonly VITE_APPLE_SERVICE_ID?: string;
  readonly VITE_APPLE_REDIRECT_URL?: string;
}

declare module 'maplibre-gl/dist/maplibre-gl-worker.mjs?url' {
  const url: string;
  export default url;
}
