package com.outbreak.game;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.os.IBinder;
import android.os.Looper;

/**
 * THE ONLY JAVA IN THIS PROJECT. Read this before you add a second line to it.
 *
 * It is a foreground service AND the location listener, in one class, and that is deliberate:
 *
 *   - Android has no native location API. Every route to a live fix runs through a Java callback
 *     object, which needs a class, which needs a dex. JNI cannot conjure one.
 *
 *   - Background location needs a foreground service. Without one, Android throttles a backgrounded
 *     app's location to a few fixes an hour and eventually kills it. An ambient game whose whole
 *     premise is "it notices when your room goes live while it is in your pocket" cannot have that.
 *
 * Folding the listener INTO the service is not just tidiness. It is correctness: the listener is
 * owned by the foreground service, not by the activity, so it survives the activity being
 * backgrounded or destroyed. That is the entire point of M.6.
 *
 * ============================================================================
 * IT HOLDS NO COORDINATE. THAT IS THE DESIGN.
 *
 * `onLocationChanged` reads two doubles out of the Location, hands them to Zig, and forgets. There
 * is no field holding a Location, no field holding a latitude -- the coordinate lives for the
 * length of one call and is quantized to a u64 room id in Zig before this method returns. The
 * server has never seen a coordinate and structurally cannot; the phone is the only place one ever
 * exists, and this class plus one Zig function is the whole of that place.
 *
 * Do not add a field that keeps a Location. Do not log the position. Every such change looks
 * reasonable and turns this class into a coordinate database.
 *
 * ============================================================================
 * THE NOTIFICATION SAYS NOTHING ABOUT THE GAME. ON PURPOSE.
 *
 * This is the PERSISTENT service notification -- the always-there "we are running" one. It is
 * static and boring, and it must stay that way: a notification is a signal with content AND timing,
 * and one that changed with your cell would leak, through when it changed, exactly the sub-quorum
 * count that quorum silence protects (I3). The "you are under attack" experience is a SEPARATE,
 * event-driven notification (M.8), designed carefully against that side-channel. This one only ever
 * says why location is on.
 */
public final class OutbreakService extends Service implements LocationListener {

    static {
        // NativeActivity loads liboutbreak.so under the framework's class loader; native methods
        // resolve against the loader that loaded THIS class, which is the app's. loadLibrary is
        // idempotent -- this registers the library already in the process against this loader.
        System.loadLibrary("outbreak");
    }

    /** Implemented in Zig. Quantizes, and the floats are dead when it returns. */
    private static native void onLocation(double latitude, double longitude, float accuracyMetres);

    private static final String CHANNEL_ID = "outbreak_location";
    private static final int NOTIFICATION_ID = 1;

    /** Milliseconds between fixes, handed in by the shell via the start Intent. */
    public static final String EXTRA_INTERVAL_MS = "interval_ms";

    private LocationManager manager;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // FIRST, become a foreground service -- Android 12+ requires startForeground within a few
        // seconds of the service starting, or it kills us with an ANR-shaped crash.
        startForeground(NOTIFICATION_ID, buildNotification());

        if (manager == null) {
            manager = (LocationManager) getSystemService(Context.LOCATION_SERVICE);

            long intervalMs = 30000;
            if (intent != null) intervalMs = intent.getLongExtra(EXTRA_INTERVAL_MS, 30000);

            try {
                // GPS provider, not fused: fused is a Play Services dependency this project does not
                // take lightly (F1); the platform provider is in the OS and needs nothing. The
                // callback lands on the main looper, does almost nothing (quantize + store a u64),
                // and returns -- so the main thread is never held up.
                manager.requestLocationUpdates(
                        LocationManager.GPS_PROVIDER, intervalMs, 0.0f, this, Looper.getMainLooper());
            } catch (SecurityException e) {
                // Permission was revoked between the check and here. Not an error: a phone that will
                // not tell us where it is, which the policy already knows how to handle.
            }
        }

        // START_STICKY: if the system kills us under memory pressure, restart us when it can. An
        // ambient game wants to come back on its own.
        return START_STICKY;
    }

    @Override
    public void onLocationChanged(Location location) {
        // Read, hand over, forget. The reference dies with this stack frame.
        onLocation(location.getLatitude(), location.getLongitude(), location.getAccuracy());
    }

    @Override
    public void onDestroy() {
        if (manager != null) manager.removeUpdates(this);
        super.onDestroy();
    }

    private Notification buildNotification() {
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, "Location", NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("Keeps Outbreak watching for activity nearby.");
            channel.setShowBadge(false);
            nm.createNotificationChannel(channel);
        }

        // Tapping the notification opens the app.
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        int flags = PendingIntent.FLAG_IMMUTABLE;
        PendingIntent tap = PendingIntent.getActivity(this, 0, launch, flags);

        // The small icon is a monochrome silhouette Android renders in the status bar; looked up by
        // name rather than R.drawable so this build needs no generated R class.
        int icon = getResources().getIdentifier("ic_notify", "drawable", getPackageName());

        Notification.Builder b = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);

        return b
                .setContentTitle("Outbreak")
                .setContentText("Watching for activity nearby")
                .setSmallIcon(icon)
                .setContentIntent(tap)
                .setOngoing(true)
                .build();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null; // not a bound service
    }

    // LocationListener, the rest. Android requires them; we have nothing to say. A provider going
    // out of service is not an error -- it is a phone that does not currently know where it is.
    @Override public void onProviderEnabled(String provider) {}
    @Override public void onProviderDisabled(String provider) {}
    @Override public void onStatusChanged(String provider, int status, android.os.Bundle extras) {}
}
