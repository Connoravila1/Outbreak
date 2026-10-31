package com.outbreak.game;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.ContextCompat;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

/**
 * Patrol mode bridge: Patrol.start / stop / status / requestBackground / openSettings.
 * The web layer hands over the server URL and token; the foreground service does the rest.
 */
@CapacitorPlugin(
        name = "Patrol",
        permissions = {
                @Permission(alias = "background", strings = { Manifest.permission.ACCESS_BACKGROUND_LOCATION })
        }
)
public class PatrolPlugin extends Plugin {

    private SharedPreferences prefs() {
        return getContext().getSharedPreferences(PatrolService.PREFS, Context.MODE_PRIVATE);
    }

    private boolean hasFineLocation() {
        return ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    /** "Allow all the time". Before Android 10 there is no separate permission. */
    private boolean hasBackgroundLocation() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return hasFineLocation();
        return ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    private JSObject statusObject() {
        SharedPreferences p = prefs();
        long endsAt = p.getLong(PatrolService.P_ENDS_AT, 0);
        boolean active = p.getBoolean(PatrolService.P_ACTIVE, false) && (endsAt == 0 || endsAt > System.currentTimeMillis());
        JSObject o = new JSObject();
        o.put("active", active);
        o.put("endsAt", active ? endsAt : 0);
        o.put("intervalSec", p.getLong(PatrolService.P_INTERVAL_MS, 60_000) / 1000);
        o.put("lastCheckIn", p.getLong(PatrolService.P_LAST_OK, 0));
        o.put("lastError", p.getString(PatrolService.P_LAST_ERROR, ""));
        o.put("fineLocation", hasFineLocation());
        o.put("backgroundLocation", hasBackgroundLocation());
        o.put("notifications", NotificationManagerCompat.from(getContext()).areNotificationsEnabled());
        o.put("sdk", Build.VERSION.SDK_INT);
        return o;
    }

    @PluginMethod
    public void start(PluginCall call) {
        String url = call.getString("serverUrl", "");
        String token = call.getString("token", "");
        if (url == null || token == null || !url.startsWith("http") || token.isEmpty()) {
            call.reject("serverUrl and token are required");
            return;
        }
        if (!hasFineLocation()) {
            call.reject("Location permission is needed first.", "location_denied");
            return;
        }
        long interval = Math.max(10, Math.min(600, call.getInt("intervalSec", 60)));
        long duration = Math.max(0, Math.min(24 * 3600, call.getInt("durationSec", 0)));
        Intent i = new Intent(getContext(), PatrolService.class)
                .setAction(PatrolService.ACTION_START)
                .putExtra(PatrolService.EXTRA_URL, url.replaceAll("/+$", ""))
                .putExtra(PatrolService.EXTRA_TOKEN, token)
                .putExtra(PatrolService.EXTRA_INTERVAL_SEC, interval)
                .putExtra(PatrolService.EXTRA_DURATION_SEC, duration);
        try {
            ContextCompat.startForegroundService(getContext(), i);
        } catch (RuntimeException e) {
            call.reject("Patrol could not start: " + e.getMessage(), "start_failed");
            return;
        }
        // The service writes the same preferences when it starts; answer with what it will hold.
        JSObject o = statusObject();
        o.put("active", true);
        o.put("endsAt", duration > 0 ? System.currentTimeMillis() + duration * 1000L : 0);
        o.put("intervalSec", interval);
        call.resolve(o);
    }

    @PluginMethod
    public void stop(PluginCall call) {
        Intent i = new Intent(getContext(), PatrolService.class).setAction(PatrolService.ACTION_STOP);
        prefs().edit().putBoolean(PatrolService.P_ACTIVE, false).apply();
        try {
            ContextCompat.startForegroundService(getContext(), i);
        } catch (RuntimeException e) {
            getContext().stopService(new Intent(getContext(), PatrolService.class));
        }
        JSObject o = statusObject();
        o.put("active", false);
        call.resolve(o);
    }

    @PluginMethod
    public void status(PluginCall call) {
        call.resolve(statusObject());
    }

    /** Ask for "Allow all the time". Android 11+ sends the player to the app's location settings. */
    @PluginMethod
    public void requestBackground(PluginCall call) {
        if (!hasFineLocation()) {
            call.reject("Allow location first.", "location_denied");
            return;
        }
        if (hasBackgroundLocation()) {
            call.resolve(statusObject());
            return;
        }
        requestPermissionForAlias("background", call, "backgroundResult");
    }

    @PermissionCallback
    private void backgroundResult(PluginCall call) {
        call.resolve(statusObject());
    }

    /** The app's system settings page, for when the permission flow cannot be completed in-app. */
    @PluginMethod
    public void openSettings(PluginCall call) {
        Intent i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", getContext().getPackageName(), null));
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        getContext().startActivity(i);
        call.resolve();
    }
}
