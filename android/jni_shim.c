// The JNI plumbing. Verbose, mechanical, and confined to this file.
//
// ============================================================================
// WHY A SHIM AND NOT A `@cImport`
//
// Same reason as `vendor/stb_impl.c`: Zig does not ship bionic's headers, so `#include <jni.h>`
// only resolves when the NDK is present. Making the NDK a prerequisite of `zig build` -- on every
// machine, forever, in order to TYPE-CHECK a phone file -- is a bad trade.
//
// So Zig declares these functions as `extern fn` and never sees a header, exactly as `android.zig`
// declares the NDK and `gles.zig` declares GLES. The JNI function table stays on this side of the
// wall, where it belongs.
//
// ============================================================================
// WHAT IS NOT IN HERE
//
// THE COORDINATE. It does not pass through this file and it never will.
//
// `Java_com_outbreak_game_Fix_onLocation` -- the native method the listener calls -- is exported
// from ZIG, not from here, and the JVM resolves it by symbol name straight out of the .so. So the
// latitude's first and only stop in our code is a Zig function that quantizes it and drops it.
//
// If a location ever appears in this file, someone has put a stop on the way.

#include <jni.h>
#include <stddef.h>
#include <string.h>
#include <android/log.h>

#define LOG(...) __android_log_print(ANDROID_LOG_WARN, "outbreak", __VA_ARGS__)

// ---------------------------------------------------------------- threads

/// Attach the calling thread to the JVM and hand back its JNIEnv.
///
/// The render thread is ours, not the JVM's -- it was spawned by Zig and the VM has never heard of
/// it. Touching JNI from an unattached thread is undefined behaviour, not an error.
JNIEnv *jnishim_attach(JavaVM *vm) {
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK) return env;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return NULL;
    return env;
}

void jnishim_detach(JavaVM *vm) {
    (*vm)->DetachCurrentThread(vm);
}

/// Swallow and clear any pending exception, and say whether there was one.
///
/// A pending JNI exception poisons every subsequent call. Checking is not optional, and there is
/// nothing useful to do with a location exception except carry on without a fix (E4).
static int cleared(JNIEnv *env, const char *what) {
    if ((*env)->ExceptionCheck(env)) {
        // DESCRIBE IT FIRST. The first version of this function cleared the exception and returned,
        // which meant `requestLocationUpdates` failed and the app carried on in perfect silence
        // with the radio off. A swallowed exception is a bug you get to find twice.
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        LOG("JNI exception at: %s", what);
        return 1;
    }
    return 0;
}

/// FIND ONE OF *OUR* CLASSES. `FindClass` will not do it.
///
/// In a native callback there are no Java frames on the stack, so `FindClass` falls back to the
/// SYSTEM class loader -- which has never heard of `com.outbreak.game.Fix` and never will. It
/// throws ClassNotFoundException, and if you are clearing exceptions quietly you will simply
/// observe that the GPS does not work.
///
/// The app's own classes live in the ACTIVITY's class loader, so we go and ask it.
static jclass find_app_class(JNIEnv *env, jobject activity, const char *dotted) {
    jclass activity_class = (*env)->GetObjectClass(env, activity);
    jmethodID get_loader = (*env)->GetMethodID(env, activity_class, "getClassLoader",
                                               "()Ljava/lang/ClassLoader;");
    if (cleared(env, "getClassLoader id") || get_loader == NULL) return NULL;

    jobject loader = (*env)->CallObjectMethod(env, activity, get_loader);
    if (cleared(env, "getClassLoader") || loader == NULL) return NULL;

    jclass loader_class = (*env)->GetObjectClass(env, loader);
    jmethodID load = (*env)->GetMethodID(env, loader_class, "loadClass",
                                         "(Ljava/lang/String;)Ljava/lang/Class;");
    if (cleared(env, "loadClass id") || load == NULL) return NULL;

    jstring name = (*env)->NewStringUTF(env, dotted);
    jclass found = (jclass)(*env)->CallObjectMethod(env, loader, load, name);
    int failed = cleared(env, "loadClass");

    (*env)->DeleteLocalRef(env, name);
    (*env)->DeleteLocalRef(env, loader_class);
    (*env)->DeleteLocalRef(env, loader);
    (*env)->DeleteLocalRef(env, activity_class);

    return failed ? NULL : found;
}

// ---------------------------------------------------------------- permission

/// Has the user granted us fine location?
///
/// PackageManager.PERMISSION_GRANTED is 0.
int jnishim_has_location_permission(JNIEnv *env, jobject activity) {
    jclass ctx = (*env)->FindClass(env, "android/content/Context");
    if (cleared(env, "Context class") || ctx == NULL) return 0;

    jmethodID check = (*env)->GetMethodID(env, ctx, "checkSelfPermission", "(Ljava/lang/String;)I");
    if (cleared(env, "checkSelfPermission id") || check == NULL) return 0;

    jstring perm = (*env)->NewStringUTF(env, "android.permission.ACCESS_FINE_LOCATION");
    jint result = (*env)->CallIntMethod(env, activity, check, perm);
    int granted = !cleared(env, "checkSelfPermission") && result == 0;

    (*env)->DeleteLocalRef(env, perm);
    (*env)->DeleteLocalRef(env, ctx);
    return granted;
}

/// Ask for the permissions the game needs. Fire and forget -- the result arrives as a callback we
/// do not have a class for, so we simply keep checking `jnishim_has_location_permission` until it
/// says yes or the player says no. Polling a boolean once a second is not a cost worth building a
/// second Java class over.
///
/// TWO permissions, asked in one sequence: ACCESS_FINE_LOCATION (the room) and POST_NOTIFICATIONS
/// (the combat alert, M.8). The latter is only meaningful on Android 13+; on older versions the OS
/// treats it as already granted, so requesting it unconditionally is harmless. Location is the one
/// the game gates on; if notifications are refused the game still plays, just without the alert.
void jnishim_request_location_permission(JNIEnv *env, jobject activity) {
    jclass activity_class = (*env)->GetObjectClass(env, activity);
    if (cleared(env, "activity class") || activity_class == NULL) return;

    jmethodID request = (*env)->GetMethodID(env, activity_class, "requestPermissions",
                                            "([Ljava/lang/String;I)V");
    if (cleared(env, "requestPermissions id") || request == NULL) {
        (*env)->DeleteLocalRef(env, activity_class);
        return;
    }

    jclass string_class = (*env)->FindClass(env, "java/lang/String");
    jobjectArray perms = (*env)->NewObjectArray(env, 2, string_class, NULL);
    jstring fine = (*env)->NewStringUTF(env, "android.permission.ACCESS_FINE_LOCATION");
    jstring notif = (*env)->NewStringUTF(env, "android.permission.POST_NOTIFICATIONS");
    (*env)->SetObjectArrayElement(env, perms, 0, fine);
    (*env)->SetObjectArrayElement(env, perms, 1, notif);

    (*env)->CallVoidMethod(env, activity, request, perms, 1);
    cleared(env, "requestPermissions");

    (*env)->DeleteLocalRef(env, fine);
    (*env)->DeleteLocalRef(env, notif);
    (*env)->DeleteLocalRef(env, perms);
    (*env)->DeleteLocalRef(env, string_class);
    (*env)->DeleteLocalRef(env, activity_class);
}

// ---------------------------------------------------------------- the service

/// Start the foreground service, handing it the fix interval.
///
/// The service, not the activity, owns the location subscription -- which is exactly what makes it
/// survive the activity being backgrounded. We only start it here; it registers the listener,
/// shows the notification, and delivers fixes to Zig on its own.
///
/// `interval_ms` is chosen by `gps.zig`'s policy (or by the diagnostic build) and threaded through
/// as an Intent extra.
void jnishim_start_service(JNIEnv *env, jobject activity, long interval_ms) {
    jclass activity_class = (*env)->GetObjectClass(env, activity);

    // Intent intent = new Intent(activity, OutbreakService.class);
    jclass intent_class = (*env)->FindClass(env, "android/content/Intent");
    if (cleared(env, "Intent class") || intent_class == NULL) return;

    jclass service_class = find_app_class(env, activity, "com.outbreak.game.OutbreakService");
    if (service_class == NULL) {
        LOG("could not load OutbreakService -- is classes.dex in the APK?");
        return;
    }

    jmethodID intent_ctor = (*env)->GetMethodID(
        env, intent_class, "<init>", "(Landroid/content/Context;Ljava/lang/Class;)V");
    jobject intent = (*env)->NewObject(env, intent_class, intent_ctor, activity, service_class);
    if (cleared(env, "new Intent") || intent == NULL) return;

    // intent.putExtra("interval_ms", (long) interval_ms);
    jmethodID put_extra = (*env)->GetMethodID(
        env, intent_class, "putExtra", "(Ljava/lang/String;J)Landroid/content/Intent;");
    jstring key = (*env)->NewStringUTF(env, "interval_ms");
    (*env)->CallObjectMethod(env, intent, put_extra, key, (jlong)interval_ms);
    cleared(env, "putExtra");
    (*env)->DeleteLocalRef(env, key);

    // activity.startForegroundService(intent)  -- API 26+. This is the call that legally requires
    // the service to call startForeground() within a few seconds, which OutbreakService does first.
    jmethodID start_fgs = (*env)->GetMethodID(
        env, activity_class, "startForegroundService", "(Landroid/content/Intent;)Landroid/content/ComponentName;");
    if (cleared(env, "startForegroundService id") || start_fgs == NULL) {
        // Pre-26 fallback: startService.
        jmethodID start = (*env)->GetMethodID(
            env, activity_class, "startService", "(Landroid/content/Intent;)Landroid/content/ComponentName;");
        if (start != NULL) {
            (*env)->CallObjectMethod(env, activity, start, intent);
            cleared(env, "startService");
        }
    } else {
        (*env)->CallObjectMethod(env, activity, start_fgs, intent);
        cleared(env, "startForegroundService");
    }

    (*env)->DeleteLocalRef(env, intent);
    (*env)->DeleteLocalRef(env, service_class);
    (*env)->DeleteLocalRef(env, intent_class);
    (*env)->DeleteLocalRef(env, activity_class);
}

/// Command the running service to resume (active != 0) or pause (active == 0) GPS updates.
///
/// This does NOT start or stop the service -- it delivers a fresh Intent to the one already
/// running, carrying a boolean the service reads in onStartCommand. The foreground service stays
/// up (M.6); only its GPS subscription is toggled. It is the governor's hand on the radio.
///
/// startForegroundService, not startService: the service is already foreground, and re-delivering
/// through the same door the initial start used is idempotent (the service re-calls
/// startForeground, which is harmless) and never trips the background-start restriction on O+.
void jnishim_set_gps_active(JNIEnv *env, jobject activity, int active) {
    jclass activity_class = (*env)->GetObjectClass(env, activity);

    jclass intent_class = (*env)->FindClass(env, "android/content/Intent");
    if (cleared(env, "Intent class (set_gps)") || intent_class == NULL) return;

    jclass service_class = find_app_class(env, activity, "com.outbreak.game.OutbreakService");
    if (service_class == NULL) return;

    jmethodID intent_ctor = (*env)->GetMethodID(
        env, intent_class, "<init>", "(Landroid/content/Context;Ljava/lang/Class;)V");
    jobject intent = (*env)->NewObject(env, intent_class, intent_ctor, activity, service_class);
    if (cleared(env, "new Intent (set_gps)") || intent == NULL) return;

    // intent.putExtra("gps_active", (boolean) active)
    jmethodID put_extra = (*env)->GetMethodID(
        env, intent_class, "putExtra", "(Ljava/lang/String;Z)Landroid/content/Intent;");
    jstring key = (*env)->NewStringUTF(env, "gps_active");
    (*env)->CallObjectMethod(env, intent, put_extra, key, (jboolean)(active ? 1 : 0));
    cleared(env, "putExtra gps_active");
    (*env)->DeleteLocalRef(env, key);

    jmethodID start_fgs = (*env)->GetMethodID(
        env, activity_class, "startForegroundService", "(Landroid/content/Intent;)Landroid/content/ComponentName;");
    if (cleared(env, "startForegroundService id (set_gps)") || start_fgs == NULL) {
        jmethodID start = (*env)->GetMethodID(
            env, activity_class, "startService", "(Landroid/content/Intent;)Landroid/content/ComponentName;");
        if (start != NULL) {
            (*env)->CallObjectMethod(env, activity, start, intent);
            cleared(env, "startService (set_gps)");
        }
    } else {
        (*env)->CallObjectMethod(env, activity, start_fgs, intent);
        cleared(env, "startForegroundService (set_gps)");
    }

    (*env)->DeleteLocalRef(env, intent);
    (*env)->DeleteLocalRef(env, service_class);
    (*env)->DeleteLocalRef(env, intent_class);
    (*env)->DeleteLocalRef(env, activity_class);
}

/// Raise or clear the "your cell is live" combat alert. `band >= 0` raises it with that crowd band;
/// `band < 0` clears it. Like set_gps, this delivers a command Intent to the running service, which
/// posts (or cancels) the notification. The band is a CATEGORICAL index, never a count.
void jnishim_combat_alert(JNIEnv *env, jobject activity, int band) {
    jclass activity_class = (*env)->GetObjectClass(env, activity);

    jclass intent_class = (*env)->FindClass(env, "android/content/Intent");
    if (cleared(env, "Intent class (combat)") || intent_class == NULL) return;

    jclass service_class = find_app_class(env, activity, "com.outbreak.game.OutbreakService");
    if (service_class == NULL) return;

    jmethodID intent_ctor = (*env)->GetMethodID(
        env, intent_class, "<init>", "(Landroid/content/Context;Ljava/lang/Class;)V");
    jobject intent = (*env)->NewObject(env, intent_class, intent_ctor, activity, service_class);
    if (cleared(env, "new Intent (combat)") || intent == NULL) return;

    // intent.putExtra("combat_band", (int) band)
    jmethodID put_extra = (*env)->GetMethodID(
        env, intent_class, "putExtra", "(Ljava/lang/String;I)Landroid/content/Intent;");
    jstring key = (*env)->NewStringUTF(env, "combat_band");
    (*env)->CallObjectMethod(env, intent, put_extra, key, (jint)band);
    cleared(env, "putExtra combat_band");
    (*env)->DeleteLocalRef(env, key);

    jmethodID start_fgs = (*env)->GetMethodID(
        env, activity_class, "startForegroundService", "(Landroid/content/Intent;)Landroid/content/ComponentName;");
    if (cleared(env, "startForegroundService id (combat)") || start_fgs == NULL) {
        jmethodID start = (*env)->GetMethodID(
            env, activity_class, "startService", "(Landroid/content/Intent;)Landroid/content/ComponentName;");
        if (start != NULL) {
            (*env)->CallObjectMethod(env, activity, start, intent);
            cleared(env, "startService (combat)");
        }
    } else {
        (*env)->CallObjectMethod(env, activity, start_fgs, intent);
        cleared(env, "startForegroundService (combat)");
    }

    (*env)->DeleteLocalRef(env, intent);
    (*env)->DeleteLocalRef(env, service_class);
    (*env)->DeleteLocalRef(env, intent_class);
    (*env)->DeleteLocalRef(env, activity_class);
}

/// Stop the service. The radio goes quiet and the notification disappears -- the whole battery
/// budget in one call: a service that is not running costs nothing.
void jnishim_stop_service(JNIEnv *env, jobject activity) {
    jclass activity_class = (*env)->GetObjectClass(env, activity);

    jclass intent_class = (*env)->FindClass(env, "android/content/Intent");
    jclass service_class = find_app_class(env, activity, "com.outbreak.game.OutbreakService");
    if (service_class == NULL) return;

    jmethodID intent_ctor = (*env)->GetMethodID(
        env, intent_class, "<init>", "(Landroid/content/Context;Ljava/lang/Class;)V");
    jobject intent = (*env)->NewObject(env, intent_class, intent_ctor, activity, service_class);

    jmethodID stop = (*env)->GetMethodID(
        env, activity_class, "stopService", "(Landroid/content/Intent;)Z");
    if (!cleared(env, "stopService id") && stop != NULL) {
        (*env)->CallBooleanMethod(env, activity, stop, intent);
        cleared(env, "stopService");
    }

    (*env)->DeleteLocalRef(env, intent);
    (*env)->DeleteLocalRef(env, service_class);
    (*env)->DeleteLocalRef(env, intent_class);
    (*env)->DeleteLocalRef(env, activity_class);
}
