#include <dlfcn.h>
#include <jni.h>
#include <android/dlext.h>
#include <android/log.h>
#include <string.h>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "mpv", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "mpv", __VA_ARGS__)

/* Force-load app-local libvulkan.so even if system libvulkan.so (same soname)
 * is already in the process. Android 7 system Vulkan is 1.0-only and lacks
 * vkGetPhysicalDeviceQueueFamilyProperties2 that libmpv relocates against. */
JNIEXPORT jboolean JNICALL
Java_is_xyz_mpv_MPVLib_nativeLoadGlobal(JNIEnv* env, jclass clazz, jstring path) {
    if (path == NULL) return JNI_FALSE;
    const char* p = (*env)->GetStringUTFChars(env, path, NULL);
    if (p == NULL) return JNI_FALSE;

    android_dlextinfo ext;
    memset(&ext, 0, sizeof(ext));
    ext.flags = ANDROID_DLEXT_FORCE_LOAD;
    void* handle = android_dlopen_ext(p, RTLD_NOW | RTLD_GLOBAL, &ext);
    if (handle == NULL) {
        handle = dlopen(p, RTLD_NOW | RTLD_GLOBAL);
    }
    if (handle == NULL) {
        LOGE("nativeLoadGlobal failed for %s: %s", p, dlerror());
        (*env)->ReleaseStringUTFChars(env, path, p);
        return JNI_FALSE;
    }
    LOGI("nativeLoadGlobal ok: %s", p);
    (*env)->ReleaseStringUTFChars(env, path, p);
    return JNI_TRUE;
}
