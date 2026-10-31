package com.outbreak.game;

import android.content.Context;
import android.location.Location;
import android.location.LocationManager;
import android.os.Build;
import android.os.SystemClock;

/**
 * Does a location fix come from a mock provider (a fake-GPS app)? Android flags it on the fix itself:
 * {@link Location#isMock()} from API 31, {@link Location#isFromMockProvider()} before. The foreground
 * fixes the web layer uses come from the Capacitor Geolocation plugin, which does not pass the flag
 * on, so {@link #latestIsMock(Context)} asks the system for the newest fix instead (see
 * PatrolPlugin.mockCheck). PatrolService reads the flag from its own fixes with {@link #isMock}.
 *
 * Only the yes/no leaves this class; no coordinate is read, kept or logged here.
 */
final class MockLocation {
    /** A fix older than this says nothing about what the player is doing now. */
    private static final long MAX_AGE_MS = 60_000;

    private MockLocation() {}

    @SuppressWarnings("deprecation")
    static boolean isMock(Location l) {
        if (l == null) return false;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return l.isMock();
        return l.isFromMockProvider();
    }

    /**
     * True when the newest fix any provider (gps, network, passive, fused) holds is a mock one and
     * is less than a minute old. Any doubt (no permission, no fix, a stale fix) is "no": a false
     * alarm costs a real player their Contact fights, a miss costs nothing.
     */
    static boolean latestIsMock(Context context) {
        LocationManager lm = (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
        if (lm == null) return false;
        Location newest = null;
        try {
            for (String provider : lm.getAllProviders()) {
                Location l = lm.getLastKnownLocation(provider);
                if (l == null) continue;
                if (newest == null || l.getElapsedRealtimeNanos() > newest.getElapsedRealtimeNanos()) newest = l;
            }
        } catch (SecurityException | IllegalArgumentException e) {
            return false;
        }
        if (newest == null) return false;
        long ageMs = (SystemClock.elapsedRealtimeNanos() - newest.getElapsedRealtimeNanos()) / 1_000_000L;
        if (ageMs > MAX_AGE_MS || ageMs < -MAX_AGE_MS) return false;
        return isMock(newest);
    }
}
