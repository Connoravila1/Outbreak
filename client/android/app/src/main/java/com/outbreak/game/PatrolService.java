package com.outbreak.game;

import android.Manifest;
import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.SystemClock;
import android.text.format.DateFormat;

import androidx.core.app.NotificationCompat;
import androidx.core.content.ContextCompat;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Date;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Patrol mode: keeps the player in the world while the app is closed.
 *
 * A foreground service of type "location" with one persistent, quiet notification. It listens to
 * the platform LocationManager (PASSIVE, NETWORK and GPS providers, so no Play Services and no
 * high-power fused request) with a 60 s / 40 m floor, and every `intervalSec` it POSTs the latest
 * fix to /api/patrol. Each event the server hands back becomes a notification on the high
 * importance "Contacts" channel; tapping one opens the app, which then replays the fight.
 *
 * Battery: the radios are asked for a fix at most once a minute and only when the phone has moved
 * 40 m; a stationary phone costs one small HTTPS POST per interval, scheduled with an inexact
 * AlarmManager alarm (no wake lock is held between check-ins).
 *
 * The coordinate: the latest fix is kept in memory only so a stationary player can be re-announced;
 * it is never written to disk or logged. The token and server URL are given by the web layer at
 * start (never read from WebView storage) and kept in private preferences only so the service can
 * resume after the system restarts it; they are erased when patrol stops.
 */
public final class PatrolService extends Service implements LocationListener {

    static final String ACTION_START = "com.outbreak.game.patrol.START";
    static final String ACTION_STOP = "com.outbreak.game.patrol.STOP";
    static final String ACTION_TICK = "com.outbreak.game.patrol.TICK";

    static final String EXTRA_URL = "url";
    static final String EXTRA_TOKEN = "token";
    static final String EXTRA_INTERVAL_SEC = "interval_sec";
    static final String EXTRA_DURATION_SEC = "duration_sec";

    static final String PREFS = "patrol";
    static final String P_ACTIVE = "active";
    static final String P_URL = "url";
    static final String P_TOKEN = "token";
    static final String P_INTERVAL_MS = "interval_ms";
    static final String P_ENDS_AT = "ends_at";
    static final String P_LAST_OK = "last_ok";
    static final String P_LAST_ERROR = "last_error";

    private static final String CH_SERVICE = "patrol_service";
    private static final String CH_CONTACTS = "patrol_contacts";
    private static final String CH_UPDATES = "patrol_updates";
    private static final int ID_SERVICE = 7001;
    private static final int ID_NOTICE = 7002;

    /** A fix worse than this is not worth announcing (a Contact reaches 60 m). */
    private static final float MAX_ACCURACY_M = 150f;
    /** A remembered fix older than this is dropped rather than re-announced. */
    private static final long MAX_FIX_AGE_MS = 20 * 60 * 1000L;
    private static final long MAX_BACKOFF_MS = 10 * 60 * 1000L;
    private static final long LOCATION_MIN_TIME_MS = 60 * 1000L;
    private static final float LOCATION_MIN_DISTANCE_M = 40f;

    private static final Pattern CONTACT_TEXT =
            Pattern.compile("^CONTACT\\. (A (?:Human|Zombie)), level (\\d+)\\. You (won|lost)\\.$");

    private SharedPreferences prefs;
    private LocationManager locations;
    private HandlerThread locationThread;
    private ExecutorService worker;
    private PowerManager.WakeLock wakeLock;

    private boolean listening = false;
    private volatile Location latest;
    /** Whether {@link #latest} came from a mock provider (read from the original fix, not the copy). */
    private volatile boolean latestMock = false;
    private volatile int failures = 0;
    private boolean foregrounded = false;

    @Override
    public void onCreate() {
        super.onCreate();
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        locations = (LocationManager) getSystemService(Context.LOCATION_SERVICE);
        worker = Executors.newSingleThreadExecutor();
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm != null) {
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "outbreak:patrol");
            wakeLock.setReferenceCounted(false);
        }
        createChannels();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();

        // Android gives a few seconds to call startForeground after startForegroundService.
        try {
            startAsForeground();
        } catch (RuntimeException e) {
            // The system refused (a restart from the background without the right to start a
            // location service, or the permission was withdrawn). Patrol cannot run.
            endPatrol("Patrol could not keep running in the background. Open Outbreak to start it again.");
            return START_NOT_STICKY;
        }

        if (ACTION_STOP.equals(action)) {
            endPatrol(null);
            return START_NOT_STICKY;
        }
        if (ACTION_START.equals(action)) {
            long durationSec = intent.getLongExtra(EXTRA_DURATION_SEC, 0);
            long intervalSec = Math.max(10, intent.getLongExtra(EXTRA_INTERVAL_SEC, 60));
            prefs.edit()
                    .putBoolean(P_ACTIVE, true)
                    .putString(P_URL, intent.getStringExtra(EXTRA_URL))
                    .putString(P_TOKEN, intent.getStringExtra(EXTRA_TOKEN))
                    .putLong(P_INTERVAL_MS, intervalSec * 1000L)
                    .putLong(P_ENDS_AT, durationSec > 0 ? System.currentTimeMillis() + durationSec * 1000L : 0L)
                    .remove(P_LAST_ERROR)
                    .apply();
            failures = 0;
            // The notification text carries the end time, so refresh it.
            startAsForeground(); // refreshes the end time shown
        } else if (!prefs.getBoolean(P_ACTIVE, false)) {
            // Restarted by the system after patrol had already ended.
            endPatrol(null);
            return START_NOT_STICKY;
        }

        long endsAt = prefs.getLong(P_ENDS_AT, 0);
        if (endsAt > 0 && System.currentTimeMillis() >= endsAt) {
            endPatrol("Patrol ended. Open Outbreak to see what happened.");
            return START_NOT_STICKY;
        }
        if (!listen()) {
            endPatrol("Patrol stopped: Outbreak has no permission to read your location.");
            return START_NOT_STICKY;
        }

        if (wakeLock != null) wakeLock.acquire(45_000);
        worker.execute(this::checkIn);
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        unlisten();
        cancelAlarm();
        if (worker != null) worker.shutdownNow();
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        super.onDestroy();
    }

    // --- Location --------------------------------------------------------------------------------

    private boolean listen() {
        if (listening) return true;
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            return false;
        }
        if (locationThread == null) {
            locationThread = new HandlerThread("patrol-location");
            locationThread.start();
        }
        try {
            // Whatever other apps already asked for costs nothing extra.
            request(LocationManager.PASSIVE_PROVIDER);
            request(LocationManager.NETWORK_PROVIDER);
            request(LocationManager.GPS_PROVIDER);
            listening = true;
        } catch (SecurityException e) {
            return false;
        }
        return true;
    }

    private void request(String provider) {
        try {
            if (locations.getAllProviders().contains(provider)) {
                locations.requestLocationUpdates(provider, LOCATION_MIN_TIME_MS, LOCATION_MIN_DISTANCE_M, this, locationThread.getLooper());
            }
        } catch (IllegalArgumentException e) {
            // This device has no such provider.
        }
    }

    private void unlisten() {
        if (locations != null) {
            try {
                locations.removeUpdates(this);
            } catch (SecurityException ignored) {
                // nothing to remove
            }
        }
        listening = false;
        latest = null;
        if (locationThread != null) {
            locationThread.quitSafely();
            locationThread = null;
        }
    }

    @Override
    public void onLocationChanged(Location loc) {
        if (loc.hasAccuracy() && loc.getAccuracy() > MAX_ACCURACY_M) return;
        Location cur = latest;
        if (cur == null || loc.getTime() >= cur.getTime()) {
            latest = new Location(loc);
            latestMock = MockLocation.isMock(loc);
        }
    }

    /** The newest usable fix: ours, else the system's last known one. Null when there is none. */
    private Location bestFix() {
        Location best = latest;
        long now = System.currentTimeMillis();
        if (best != null && now - best.getTime() > MAX_FIX_AGE_MS) best = null;
        if (best != null) return best;
        try {
            for (String p : new String[] { LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER }) {
                if (!locations.getAllProviders().contains(p)) continue;
                Location l = locations.getLastKnownLocation(p);
                if (l == null || now - l.getTime() > MAX_FIX_AGE_MS) continue;
                if (l.hasAccuracy() && l.getAccuracy() > MAX_ACCURACY_M) continue;
                if (best == null || l.getTime() > best.getTime()) best = l;
            }
        } catch (SecurityException ignored) {
            return null;
        }
        return best;
    }

    // --- Check-in --------------------------------------------------------------------------------

    private void checkIn() {
        try {
            long endsAt = prefs.getLong(P_ENDS_AT, 0);
            if (!prefs.getBoolean(P_ACTIVE, false)) return;
            if (endsAt > 0 && System.currentTimeMillis() >= endsAt) {
                endPatrol("Patrol ended. Open Outbreak to see what happened.");
                return;
            }
            Location fix = bestFix();
            if (fix == null) {
                prefs.edit().putString(P_LAST_ERROR, "no_fix").apply();
                scheduleNext();
                return;
            }
            JSONObject body = new JSONObject();
            body.put("lat", fix.getLatitude());
            body.put("lon", fix.getLongitude());
            body.put("acc", fix.hasAccuracy() ? fix.getAccuracy() : 0);
            // The server pauses real-world fights and war points while the phone's fix is a mock one.
            body.put("mock", fix == latest ? latestMock : MockLocation.isMock(fix));

            String url = prefs.getString(P_URL, "") + "/api/patrol";
            String token = prefs.getString(P_TOKEN, "");
            HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
            int status;
            String text;
            try {
                c.setRequestMethod("POST");
                c.setConnectTimeout(10_000);
                c.setReadTimeout(15_000);
                c.setDoOutput(true);
                c.setRequestProperty("Content-Type", "application/json");
                c.setRequestProperty("Accept", "application/json");
                c.setRequestProperty("Authorization", "Bearer " + token);
                try (OutputStream out = c.getOutputStream()) {
                    out.write(body.toString().getBytes(StandardCharsets.UTF_8));
                }
                status = c.getResponseCode();
                text = read(status >= 400 ? c.getErrorStream() : c.getInputStream());
            } finally {
                c.disconnect();
            }

            if (status == 401 || status == 403) {
                endPatrol("Patrol stopped: you were signed out. Open Outbreak to sign in and start it again.");
                return;
            }
            if (status == 409) {
                // No callsign or faction chosen yet: there is nothing to patrol as.
                endPatrol("Patrol stopped: finish setting up your character in Outbreak first.");
                return;
            }
            if (status >= 500 || status == 429) throw new java.io.IOException("server " + status);
            if (status == 200) {
                failures = 0;
                prefs.edit().putLong(P_LAST_OK, System.currentTimeMillis()).remove(P_LAST_ERROR).apply();
                deliver(new JSONObject(text).optJSONArray("events"));
            } else {
                // A refused fix (400) is not worth backing off for.
                prefs.edit().putString(P_LAST_ERROR, "http_" + status).apply();
            }
            scheduleNext();
        } catch (Exception e) {
            failures++;
            prefs.edit().putString(P_LAST_ERROR, "network").apply();
            scheduleNext();
        } finally {
            if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        }
    }

    private static String read(InputStream in) throws java.io.IOException {
        if (in == null) return "";
        try (InputStream s = in) {
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            byte[] chunk = new byte[2048];
            int n;
            while ((n = s.read(chunk)) > 0 && buf.size() < 64 * 1024) buf.write(chunk, 0, n);
            return buf.toString("UTF-8");
        }
    }

    private void scheduleNext() {
        if (!prefs.getBoolean(P_ACTIVE, false)) return;
        long interval = prefs.getLong(P_INTERVAL_MS, 60_000);
        long delay = failures == 0 ? interval : Math.min(MAX_BACKOFF_MS, interval << Math.min(failures, 5));
        AlarmManager am = (AlarmManager) getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + delay, tickIntent());
    }

    private PendingIntent tickIntent() {
        Intent i = new Intent(this, PatrolService.class).setAction(ACTION_TICK);
        return PendingIntent.getService(this, 1, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private void cancelAlarm() {
        AlarmManager am = (AlarmManager) getSystemService(Context.ALARM_SERVICE);
        if (am != null) am.cancel(tickIntent());
    }

    // --- Notifications ---------------------------------------------------------------------------

    private void createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager nm = getSystemService(NotificationManager.class);
        NotificationChannel service = new NotificationChannel(CH_SERVICE, "Patrol", NotificationManager.IMPORTANCE_LOW);
        service.setDescription("Shown while Outbreak is patrolling in the background.");
        service.setShowBadge(false);
        NotificationChannel contacts = new NotificationChannel(CH_CONTACTS, "Contacts", NotificationManager.IMPORTANCE_HIGH);
        contacts.setDescription("Fights that found you while the app was closed.");
        NotificationChannel updates = new NotificationChannel(CH_UPDATES, "Patrol updates", NotificationManager.IMPORTANCE_DEFAULT);
        updates.setDescription("Level-ups, raids and patrol ending.");
        nm.createNotificationChannel(service);
        nm.createNotificationChannel(contacts);
        nm.createNotificationChannel(updates);
    }

    private PendingIntent openApp() {
        Intent i = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (i != null) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        return PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private void startAsForeground() {
        PendingIntent stop = PendingIntent.getService(this, 2,
                new Intent(this, PatrolService.class).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        long endsAt = prefs.getLong(P_ENDS_AT, 0);
        NotificationCompat.Builder b = new NotificationCompat.Builder(this, CH_SERVICE)
                .setSmallIcon(R.drawable.ic_notify)
                .setContentTitle("Outbreak is patrolling · tap to open")
                .setContentIntent(openApp())
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .addAction(0, "Stop", stop);
        if (endsAt > 0) b.setContentText("Until " + DateFormat.getTimeFormat(this).format(new Date(endsAt)));
        Notification n = b.build();
        if (foregrounded) {
            // Already in the foreground (a tick, or a restart of the timer): just refresh it. Calling
            // startForeground again from the background is what the system restricts.
            getSystemService(NotificationManager.class).notify(ID_SERVICE, n);
            return;
        }
        foregrounded = true;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID_SERVICE, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
        } else {
            startForeground(ID_SERVICE, n);
        }
    }

    private void deliver(JSONArray events) {
        if (events == null) return;
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        for (int i = 0; i < events.length(); i++) {
            JSONObject e = events.optJSONObject(i);
            if (e == null) continue;
            String type = e.optString("type");
            String text = e.optString("text");
            boolean contact = "contact".equals(type);
            String title;
            switch (type) {
                case "contact": title = "CONTACT"; break;
                case "level_up": title = "LEVEL UP"; break;
                case "raid": title = "RAID"; break;
                case "echo_report": title = "ECHO"; break;
                default: title = "OUTBREAK"; break;
            }
            if (contact) {
                Matcher m = CONTACT_TEXT.matcher(text);
                if (m.matches()) {
                    text = m.group(1) + " found you. " + ("won".equals(m.group(3)) ? "You held." : "You were beaten.");
                } else if (text.startsWith("CONTACT. ")) {
                    text = text.substring("CONTACT. ".length());
                }
            }
            int id = 10_000 + (int) (e.optLong("id", i) % 1_000_000L);
            Notification n = new NotificationCompat.Builder(this, contact ? CH_CONTACTS : CH_UPDATES)
                    .setSmallIcon(R.drawable.ic_notify)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setStyle(new NotificationCompat.BigTextStyle().bigText(text))
                    .setContentIntent(openApp())
                    .setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_EVENT)
                    .setPriority(contact ? NotificationCompat.PRIORITY_HIGH : NotificationCompat.PRIORITY_DEFAULT)
                    .setWhen(e.optLong("at", System.currentTimeMillis()))
                    .setShowWhen(true)
                    .build();
            try {
                nm.notify(id, n);
            } catch (SecurityException ignored) {
                // notifications are not allowed; the app still shows the events when it opens
            }
        }
    }

    // --- Ending ----------------------------------------------------------------------------------

    /** Stop everything, erase the token, and optionally tell the player why. */
    private void endPatrol(String notice) {
        prefs.edit().putBoolean(P_ACTIVE, false).remove(P_TOKEN).remove(P_URL).putLong(P_ENDS_AT, 0).apply();
        cancelAlarm();
        unlisten();
        stopForeground(STOP_FOREGROUND_REMOVE);
        if (notice != null) {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            Notification n = new NotificationCompat.Builder(this, CH_UPDATES)
                    .setSmallIcon(R.drawable.ic_notify)
                    .setContentTitle("OUTBREAK")
                    .setContentText(notice)
                    .setStyle(new NotificationCompat.BigTextStyle().bigText(notice))
                    .setContentIntent(openApp())
                    .setAutoCancel(true)
                    .build();
            try {
                nm.notify(ID_NOTICE, n);
            } catch (SecurityException ignored) {
                // notifications are not allowed
            }
        }
        stopSelf();
    }
}
