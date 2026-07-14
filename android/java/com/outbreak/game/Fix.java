package com.outbreak.game;

import android.location.Location;
import android.location.LocationListener;

/**
 * THE ONLY JAVA IN THIS PROJECT. Read this before you add a second line to it.
 *
 * ============================================================================
 * WHY IT EXISTS AT ALL
 *
 * `android.zig` opens by saying THERE IS NO KOTLIN, and until now that was literally true: the
 * framework's own NativeActivity loads a shared library and no class of ours is ever written.
 *
 * Android has no native location API. There is no LocationManager in the NDK, there never has
 * been, and there is no plan for one. Every route to a live fix runs through a Java callback
 * object -- LocationListener, or a Consumer, or a BroadcastReceiver -- and a callback object needs
 * a class, and a class needs a dex. JNI cannot conjure one: Proxy.newProxyInstance needs an
 * InvocationHandler, RegisterNatives needs a class that already declares the native method. It is
 * turtles, and the bottom turtle is Java.
 *
 * So: fifteen lines, and not one more.
 *
 * ============================================================================
 * IT HOLDS NOTHING. THAT IS THE ENTIRE DESIGN.
 *
 * The coordinate wall says the raw position is consumed and discarded in the same function that
 * receives it. This class is now part of that wall, so it obeys it:
 *
 *   - No field holds a Location. No field holds a latitude. THIS CLASS HAS NO FIELDS.
 *   - Nothing is stored, cached, logged, or put in a crash report.
 *   - The Location object arrives, two doubles are read out of it, they are handed straight to
 *     Zig, and the reference goes out of scope on the next line.
 *
 * `onLocation` quantizes and drops the floats before it returns. By the time this method finishes,
 * the only thing that survives anywhere in the process is a u64 cell id -- a group-by key, not a
 * compressed coordinate, and there is no function anywhere that turns it back.
 *
 * The server has never seen a coordinate and structurally cannot: the build fails if a float
 * appears in the core. THE PHONE IS THEREFORE THE ONLY PLACE A COORDINATE EVER EXISTS, and this
 * file plus one Zig function is the whole of that place.
 *
 * ============================================================================
 * DO NOT
 *
 * Do not add a field. Do not keep the last Location "so we can compare". Do not log the accuracy
 * with the position next to it. Do not add a getter. Every one of those will look reasonable on
 * the day someone writes it, and every one of them turns this class into a coordinate database.
 *
 * If this file grows, something has gone wrong.
 */
public final class Fix implements LocationListener {

    /**
     * WITHOUT THIS LINE, THE NATIVE METHOD BELOW DOES NOT EXIST.
     *
     * NativeActivity loads liboutbreak.so itself, so the library is already in the process -- the
     * symbol is right there, and `nm` will show it to you. But the JVM resolves native methods
     * against the libraries loaded by THE CLASS LOADER THAT LOADED THIS CLASS, and NativeActivity
     * loaded it under the framework's. This class is loaded by the app's.
     *
     * So the JVM looked for Java_com_outbreak_game_Fix_onLocation, in a library it had, and did
     * not find it, and threw UnsatisfiedLinkError with a message about the library not being
     * loaded -- while the library was loaded.
     *
     * `loadLibrary` is idempotent. This does not load it twice; it registers the one already there
     * against this class loader, which is the whole of what was missing.
     */
    static {
        System.loadLibrary("outbreak");
    }

    /** Implemented in Zig. It quantizes, and the floats are dead when it returns. */
    private static native void onLocation(double latitude, double longitude, float accuracyMetres);

    @Override
    public void onLocationChanged(Location location) {
        // Read, hand over, forget. The `location` reference dies with this stack frame.
        onLocation(location.getLatitude(), location.getLongitude(), location.getAccuracy());
    }

    // The rest of the interface. Android requires them; we have nothing to say.
    //
    // A provider going out of service is NOT an error and is not reported as one: it is a phone
    // that does not currently know where it is, which is an ordinary condition and not a failure.
    // The policy already handles never having had a fix.

    @Override
    public void onProviderEnabled(String provider) {}

    @Override
    public void onProviderDisabled(String provider) {}

    @Override
    public void onStatusChanged(String provider, int status, android.os.Bundle extras) {}
}
