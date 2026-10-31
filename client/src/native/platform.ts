import { Capacitor } from '@capacitor/core';

/** True inside the Android / iOS Capacitor shell; false in a browser. */
export const isNative: boolean = Capacitor.isNativePlatform();
