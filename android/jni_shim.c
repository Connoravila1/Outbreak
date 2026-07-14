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

/// Ask for it. Fire and forget -- the result arrives as a callback we do not have a class for, so
/// we simply keep checking `jnishim_has_location_permission` until it says yes or the player says
/// no. Polling a boolean once a second is not a cost worth building a second Java class over.
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
    jobjectArray perms = (*env)->NewObjectArray(env, 1, string_class, NULL);
    jstring fine = (*env)->NewStringUTF(env, "android.permission.ACCESS_FINE_LOCATION");
    (*env)->SetObjectArrayElement(env, perms, 0, fine);

    (*env)->CallVoidMethod(env, activity, request, perms, 1);
    cleared(env, "requestPermissions");

    (*env)->DeleteLocalRef(env, fine);
    (*env)->DeleteLocalRef(env, perms);
    (*env)->DeleteLocalRef(env, string_class);
    (*env)->DeleteLocalRef(env, activity_class);
}

// ---------------------------------------------------------------- location

/// The listener, held as a global ref for as long as it is registered.
///
/// This is a reference to a Java object with NO FIELDS. It cannot be holding a coordinate, because
/// there is nowhere in it to put one. See `Fix.java`.
static jobject g_listener = NULL;

/// Start listening.
///
/// `min_ms` and `min_metres` are the OS's own throttle, and they are the first line of the battery
/// budget: the radio does not wake for a fix we told it we did not want. The policy in `gps.zig`
/// decides the numbers; this only carries them across.
///
/// Returns 0 on failure, which is not an error -- it is a phone that will not be telling us where
/// it is, and the policy already knows how to have never had a fix (E4).
int jnishim_start_location(JNIEnv *env, jobject activity, int min_ms, float min_metres) {
    if (g_listener != NULL) return 1; // already running

    jclass ctx = (*env)->FindClass(env, "android/content/Context");
    jmethodID get_service = (*env)->GetMethodID(env, ctx, "getSystemService",
                                                "(Ljava/lang/String;)Ljava/lang/Object;");
    if (cleared(env, "getSystemService id") || get_service == NULL) return 0;

    jstring name = (*env)->NewStringUTF(env, "location");
    jobject manager = (*env)->CallObjectMethod(env, activity, get_service, name);
    (*env)->DeleteLocalRef(env, name);
    if (cleared(env, "getSystemService") || manager == NULL) return 0;

    // OUR one Java class -- so `FindClass` is the WRONG TOOL, and this was the bug.
    //
    // In a native callback there are no Java frames on the stack, so `FindClass` falls back to the
    // SYSTEM class loader, which has never heard of com.outbreak.game.Fix and never will. It throws
    // ClassNotFoundException. And because the first version of `cleared()` swallowed exceptions in
    // silence, the observable symptom was simply that the GPS did not work.
    //
    // The app's classes live in the ACTIVITY's class loader. So we go and ask it.
    jclass fix_class = find_app_class(env, activity, "com.outbreak.game.Fix");
    if (fix_class == NULL) {
        LOG("could not load com.outbreak.game.Fix -- is classes.dex in the APK?");
        return 0;
    }

    jmethodID init = (*env)->GetMethodID(env, fix_class, "<init>", "()V");
    jobject listener = (*env)->NewObject(env, fix_class, init);
    if (cleared(env, "new Fix") || listener == NULL) return 0;

    jclass manager_class = (*env)->GetObjectClass(env, manager);
    jmethodID request = (*env)->GetMethodID(
        env, manager_class, "requestLocationUpdates",
        "(Ljava/lang/String;JFLandroid/location/LocationListener;Landroid/os/Looper;)V");
    if (cleared(env, "requestLocationUpdates id") || request == NULL) return 0;

    // The MAIN looper: the callback lands on the OS thread, which is where Android wants it. The
    // native method it calls does almost nothing -- quantize and store a u64 -- so the main thread
    // is never held up (the one contract that matters, see android.zig).
    jclass looper_class = (*env)->FindClass(env, "android/os/Looper");
    jmethodID get_main = (*env)->GetStaticMethodID(env, looper_class, "getMainLooper",
                                                   "()Landroid/os/Looper;");
    jobject main_looper = (*env)->CallStaticObjectMethod(env, looper_class, get_main);

    // GPS first. The fused provider is a Play Services dependency and this project does not take
    // one lightly (F1); the platform provider is in the OS and needs nothing.
    jstring provider = (*env)->NewStringUTF(env, "gps");

    // NOTE the double. In C varargs a float is promoted to double, and JNI's vararg call reads it
    // back as one -- passing a jfloat here is the classic way to hand the JVM a garbage distance.
    (*env)->CallVoidMethod(env, manager, request, provider, (jlong)min_ms, (jdouble)min_metres,
                           listener, main_looper);
    int ok = !cleared(env, "requestLocationUpdates");

    if (ok) {
        g_listener = (*env)->NewGlobalRef(env, listener);
        LOG("location updates requested: every %dms / %.0fm", min_ms, (double)min_metres);
    }

    (*env)->DeleteLocalRef(env, provider);
    (*env)->DeleteLocalRef(env, main_looper);
    (*env)->DeleteLocalRef(env, looper_class);
    (*env)->DeleteLocalRef(env, manager_class);
    (*env)->DeleteLocalRef(env, listener);
    (*env)->DeleteLocalRef(env, fix_class);
    (*env)->DeleteLocalRef(env, manager);
    (*env)->DeleteLocalRef(env, ctx);

    return ok;
}

/// Stop listening. The radio goes quiet, which is the whole battery budget in one function.
void jnishim_stop_location(JNIEnv *env, jobject activity) {
    if (g_listener == NULL) return;

    jclass ctx = (*env)->FindClass(env, "android/content/Context");
    jmethodID get_service = (*env)->GetMethodID(env, ctx, "getSystemService",
                                                "(Ljava/lang/String;)Ljava/lang/Object;");
    jstring name = (*env)->NewStringUTF(env, "location");
    jobject manager = (*env)->CallObjectMethod(env, activity, get_service, name);
    (*env)->DeleteLocalRef(env, name);

    if (!cleared(env, "getSystemService (stop)") && manager != NULL) {
        jclass manager_class = (*env)->GetObjectClass(env, manager);
        jmethodID remove = (*env)->GetMethodID(env, manager_class, "removeUpdates",
                                               "(Landroid/location/LocationListener;)V");
        if (remove != NULL) {
            (*env)->CallVoidMethod(env, manager, remove, g_listener);
            cleared(env, "removeUpdates");
        }
        (*env)->DeleteLocalRef(env, manager_class);
        (*env)->DeleteLocalRef(env, manager);
    }

    (*env)->DeleteGlobalRef(env, g_listener);
    g_listener = NULL;
    (*env)->DeleteLocalRef(env, ctx);
}
