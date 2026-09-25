package com.bobo.kotv.host;

import android.app.Activity;
import android.app.Application;
import android.content.Context;

import com.github.catvod.utils.Util;

import java.lang.ref.WeakReference;

/**
 * dex jar 弹窗需要 Activity window token；Application 单独用在 Flutter 壳上易 BadTokenException。
 * 由 {@code KotvApplication} 生命周期写入，{@code SpiderBridge} / jar Init 注入读取。
 */
public final class UiContext {

    private static volatile Application application;
    private static volatile WeakReference<Activity> activityRef = new WeakReference<>(null);

    private UiContext() {
    }

    public static void setApplication(Application app) {
        if (app != null) {
            application = app;
        }
    }

    public static void setActivity(Activity activity) {
        if (activity == null) {
            activityRef = new WeakReference<>(null);
            return;
        }
        activityRef = new WeakReference<>(activity);
    }

    public static Application application() {
        return application;
    }

    public static Activity activity() {
        Activity act = activityRef.get();
        if (act != null) {
            try {
                if (!act.isFinishing() && !act.isDestroyed()) {
                    return act;
                }
            } catch (Throwable ignored) {
                return act;
            }
        }
        return activityFromActivityThread();
    }

    /** jar 异步 post AlertDialog 时 WeakRef 可能已空，从 ActivityThread 取顶层非 finishing Activity。 */
    private static Activity activityFromActivityThread() {
        try {
            Class<?> atClz = Class.forName("android.app.ActivityThread");
            Object at = atClz.getMethod("currentActivityThread").invoke(null);
            if (at == null) {
                return null;
            }
            java.lang.reflect.Field field = atClz.getDeclaredField("mActivities");
            field.setAccessible(true);
            Object mapObj = field.get(at);
            if (!(mapObj instanceof java.util.Map)) {
                return null;
            }
            Activity fallback = null;
            for (Object record : ((java.util.Map<?, ?>) mapObj).values()) {
                if (record == null) {
                    continue;
                }
                Class<?> recClz = record.getClass();
                java.lang.reflect.Field pausedField = recClz.getDeclaredField("paused");
                pausedField.setAccessible(true);
                java.lang.reflect.Field activityField = recClz.getDeclaredField("activity");
                activityField.setAccessible(true);
                Object actObj = activityField.get(record);
                if (!(actObj instanceof Activity)) {
                    continue;
                }
                Activity a = (Activity) actObj;
                try {
                    if (a.isFinishing() || a.isDestroyed()) {
                        continue;
                    }
                } catch (Throwable ignored) {
                    continue;
                }
                boolean paused = pausedField.getBoolean(record);
                if (!paused) {
                    return a;
                }
                if (fallback == null) {
                    fallback = a;
                }
            }
            return fallback;
        } catch (Throwable ignored) {
            return null;
        }
    }

    /** AlertDialog / Toast 优先 Activity，否则 Application。 */
    public static Context forUi() {
        Activity act = activity();
        if (act != null) {
            return act;
        }
        Application app = application;
        if (app != null) {
            return app;
        }
        return null;
    }
}
